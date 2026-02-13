#!/usr/bin/env python3
import cv2
import time
import numpy as np
import subprocess
import logging
import threading
import os
import json
import requests
import uuid
import jwt
from datetime import datetime
from dotenv import load_dotenv
from ultralytics import YOLO

# 配置日志（别再瞎BB了，日志能帮你找问题）
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s:%(message)s')
logger = logging.getLogger("yolo-rtmp-publisher")

# 加载环境变量
load_dotenv('development.env')

class YOLORTMPPusher:
    def __init__(self):
        # 配置参数
        self.camera_index = 0
        self.width = 1280
        self.height = 720
        self.fps = 15
        self.bitrate = "3000k"
        self.model_path = "models/best.pt"
        self.room_name = os.getenv("ROOM_NAME", "my-room")
        
        self.rtpm_url = None  # 将从 LiveKit Ingress 创建后获得 RTMP 推流 URL
        self.running = False
        self.cap = None
        self.ffmpeg_process = None
        self.ingress_info = None
        
        # LiveKit API 配置
        self.livekit_url = os.getenv("LIVEKIT_URL")
        self.livekit_api_key = os.getenv("LIVEKIT_API_KEY")
        self.livekit_api_secret = os.getenv("LIVEKIT_API_SECRET")
        
        # 如果 LIVEKIT_URL 用的是 wss:// 转成 https://
        if self.livekit_url and self.livekit_url.startswith("wss://"):
            self.livekit_url = "https://" + self.livekit_url[len("wss://"):]
        
        if not all([self.livekit_url, self.livekit_api_key, self.livekit_api_secret]):
            logger.warning("LiveKit环境变量不完整！RTMP推流必须使用有效的LiveKit Ingress配置。")
            self.livekit_url = None
        
        logger.info("开始准备LiveKit RTMP推流...")
        try:
            logger.info(f"正在加载YOLO模型: {self.model_path}")
            self.model = YOLO(self.model_path)
            logger.info("YOLO模型加载成功")
        except Exception as e:
            logger.error(f"加载YOLO模型时出错: {e}")
            self.model = None

    def get_api_headers(self, additional_claims=None):
        now = int(time.time())
        payload = {
            "iss": self.livekit_api_key,
            "exp": now + 3600,
            "nbf": now
        }
        if additional_claims:
            payload.update(additional_claims)
        try:
            token = jwt.encode(payload, self.livekit_api_secret, algorithm="HS256")
        except Exception as e:
            logger.error(f"生成Token时出错: {e}")
            raise e
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        }
        return headers

    def create_ingress(self):
        """
        创建 RTMP Ingress
        按 RTMP/RTMPS 的要求，输入数据示例：
        {
          "input_type": 0,  // RTMP
          "name": "YOLO Detection RTMP Stream (YYYY-MM-DD HH:MM:SS)",
          "room_name": "my-room",
          "participant_identity": "yolo-bot-xxxx",
          "participant_name": "YOLO Detection Bot",
          "enable_transcoding": true
        }
        API 返回的 JSON 中应包含 RTMP 推流 URL（假设字段为 "url"）
        """
        if not self.livekit_url:
            logger.warning("没有LiveKit配置，无法创建RTMP Ingress")
            return None
        
        participant_identity = f"yolo-bot-{uuid.uuid4().hex[:8]}"
        participant_name = "YOLO Detection Bot"
        ingress_data = {
            "input_type": 0,  # RTMP
            "name": f"YOLO Detection RTMP Stream ({datetime.now().strftime('%Y-%m-%d %H:%M:%S')})",
            "room_name": self.room_name,
            "participant_identity": participant_identity,
            "participant_name": participant_name,
            "enable_transcoding": True
        }
        try:
            headers = self.get_api_headers({"room": self.room_name, "sub": participant_identity})
            response = requests.post(
                f"{self.livekit_url}/ingresses",
                headers=headers,
                json=ingress_data
            )
            if response.status_code != 200:
                logger.error(f"创建RTMP Ingress失败: {response.status_code} {response.text}")
                return None
            if not response.text.strip():
                logger.error("创建RTMP Ingress响应为空")
                return None
            self.ingress_info = response.json()
            self.rtpm_url = self.ingress_info.get("url")
            if not self.rtpm_url:
                logger.error("API响应中未包含 RTMP 推流 URL")
                return None
            logger.info(f"已创建RTMP Ingress，推流地址：{self.rtpm_url}")
            return self.ingress_info
        except Exception as e:
            logger.error(f"创建RTMP Ingress时发生错误: {e}")
            return None

    def start_camera(self):
        logger.info(f"初始化摄像头 #{self.camera_index}")
        self.cap = cv2.VideoCapture(self.camera_index)
        if not self.cap.isOpened():
            logger.error(f"无法打开摄像头 #{self.camera_index}")
            return False
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)
        self.cap.set(cv2.CAP_PROP_FPS, self.fps)
        actual_width = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        actual_height = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        actual_fps = int(self.cap.get(cv2.CAP_PROP_FPS))
        logger.info(f"摄像头初始化: 请求={self.width}x{self.height}@{self.fps}fps, 实际={actual_width}x{actual_height}@{actual_fps}fps")
        return True

    def start_ffmpeg(self):
        """
        启动FFmpeg进程，把原始帧推送到 RTMP 推流地址（FLV 格式）。
        这里的命令非常关键，RTMP 只接受 FLV 容器！
        """
        if not self.rtpm_url:
            logger.error("没有 RTMP 推流地址，无法启动 FFmpeg 推流")
            return False
        
        logger.info(f"启动FFmpeg推流到 {self.rtpm_url}")
        bufsize = str(int(self.bitrate.replace('k', '')) * 2) + "k"
        cmd = [
            "ffmpeg",
            "-hide_banner",
            "-f", "rawvideo",
            "-pix_fmt", "bgr24",
            "-s", f"{self.width}x{self.height}",
            "-r", str(self.fps),
            "-i", "pipe:0",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-tune", "zerolatency",
            "-b:v", self.bitrate,
            "-maxrate", self.bitrate,
            "-bufsize", bufsize,
            "-pix_fmt", "yuv420p",
            "-g", str(self.fps * 2),
            "-profile:v", "high",
            "-f", "flv",
            self.rtpm_url
        ]
        try:
            self.ffmpeg_process = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                bufsize=10**8
            )
            logger.info("FFmpeg进程启动成功")
            return True
        except Exception as e:
            logger.error(f"启动FFmpeg失败: {e}")
            return False

    def restart_ffmpeg(self):
        logger.error("FFmpeg进程挂了，重启它！")
        if self.ffmpeg_process:
            try:
                self.ffmpeg_process.stdin.close()
            except Exception as e:
                logger.error(f"关闭旧FFmpeg stdin出错: {e}")
            try:
                self.ffmpeg_process.terminate()
                self.ffmpeg_process.wait(timeout=5)
            except Exception as e:
                logger.error(f"关闭旧FFmpeg进程出错: {e}")
        if not self.start_ffmpeg():
            logger.error("重启FFmpeg失败，推流彻底GG了！")
            self.running = False

    def process_frame(self, frame):
        if self.model:
            try:
                results = self.model(frame)
                processed = results[0].plot()
                processed = cv2.resize(processed, (self.width, self.height))
                return processed
            except Exception as e:
                logger.error(f"YOLO处理错误: {e}")
                return frame
        else:
            return frame

    def camera_loop(self):
        frame_count = 0
        start_time = time.time()
        last_log_time = start_time
        
        while self.running:
            ret, frame = self.cap.read()
            if not ret:
                logger.error("无法从摄像头读取帧")
                time.sleep(0.1)
                continue
            processed = self.process_frame(frame)
            cv2.imshow("YOLO RTMP Publisher", processed)
            if cv2.waitKey(1) & 0xFF == ord('q'):
                logger.info("用户按下q键，停止推流")
                self.running = False
                break

            # 检查FFmpeg是否挂了，挂了就重启它
            if self.ffmpeg_process.poll() is not None:
                logger.error("检测到FFmpeg进程异常退出，重启推流进程...")
                self.restart_ffmpeg()
                continue

            try:
                self.ffmpeg_process.stdin.write(processed.tobytes())
            except BrokenPipeError:
                logger.error("发送帧时遇到BrokenPipeError，重启FFmpeg进程")
                self.restart_ffmpeg()
                continue
            except Exception as e:
                logger.error(f"发送帧到FFmpeg时出错: {e}")
                continue
            
            frame_count += 1
            current_time = time.time()
            if current_time - last_log_time >= 1.0:
                elapsed = current_time - start_time
                actual_fps = frame_count / elapsed
                logger.info(f"已发送 {frame_count} 帧, 实际FPS: {actual_fps:.2f}")
                last_log_time = current_time

    def start(self):
        if self.running:
            logger.warning("推流已经在运行")
            return False
        
        # 如果有LiveKit配置，则创建RTMP Ingress
        if self.livekit_url:
            ingress = self.create_ingress()
            if not ingress:
                logger.error("RTMP Ingress创建失败，无法继续推流")
                return False
        else:
            logger.warning("跳过LiveKit Ingress创建，无法推送到LiveKit")
            return False
        
        if not self.start_camera():
            logger.error("摄像头初始化失败，退出")
            return False
        
        if not self.start_ffmpeg():
            logger.error("FFmpeg启动失败，退出")
            self.cap.release()
            return False
        
        self.running = True
        logger.info("所有组件已启动，开始推流")
        
        try:
            self.camera_loop()
        finally:
            self.stop()
        
        return True

    def stop(self):
        logger.info("停止RTMP推流")
        self.running = False
        
        if self.cap and self.cap.isOpened():
            self.cap.release()
            
        if self.ffmpeg_process:
            try:
                self.ffmpeg_process.stdin.close()
                self.ffmpeg_process.terminate()
                self.ffmpeg_process.wait(timeout=5)
            except Exception as e:
                logger.error(f"关闭FFmpeg时出错: {e}")
                
        cv2.destroyAllWindows()
        logger.info("所有资源已释放")

if __name__ == "__main__":
    pusher = YOLORTMPPusher()
    try:
        pusher.start()
    except KeyboardInterrupt:
        logger.info("接收到用户中断，正在停止")
    finally:
        pusher.stop()
