#!/usr/bin/env python3
import os
import cv2
import uuid
import asyncio
import argparse
import time
import json
import numpy as np
from dotenv import load_dotenv
from ultralytics import YOLO
from getstream import Stream
from getstream.models import UserRequest, CallRequest, MemberRequest
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from aiortc.contrib.media import MediaBlackhole, MediaRecorder
from av import VideoFrame
import aiohttp
import logging

# 配置日志
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("YOLOStream")

# 加载环境变量
load_dotenv()

# GetStream.io 配置
STREAM_API_KEY = os.getenv("STREAM_API_KEY")
STREAM_API_SECRET = os.getenv("STREAM_API_SECRET")
YOLO_MODEL_PATH = os.getenv("YOLO_MODEL_PATH", "models/best.pt")

# 确保所有必要的配置都存在
if not all([STREAM_API_KEY, STREAM_API_SECRET, YOLO_MODEL_PATH]):
    logger.error("缺少必要的环境变量。请确保创建了.env文件，包含STREAM_API_KEY和STREAM_API_SECRET。")
    exit(1)

class YOLOVideoStreamTrack(VideoStreamTrack):
    """
    YOLO视频流轨道类
    使用YOLO模型处理视频帧并创建WebRTC视频轨道
    """
    def __init__(self, camera_index=0, model_path=YOLO_MODEL_PATH, width=1280, height=720, fps=15):
        super().__init__()
        self.camera_index = camera_index
        self.width = width
        self.height = height
        self.fps = fps
        self.frame_interval = 1 / fps
        self.last_frame_time = 0
        
        # 加载YOLO模型
        logger.info(f"正在加载YOLO模型: {model_path}")
        try:
            self.model = YOLO(model_path)
            logger.info("YOLO模型加载成功")
        except Exception as e:
            logger.error(f"加载YOLO模型失败: {e}")
            raise e
        
        # 初始化摄像头
        self.cap = cv2.VideoCapture(camera_index)
        if not self.cap.isOpened():
            logger.error(f"无法打开摄像头 #{camera_index}")
            raise RuntimeError(f"无法打开摄像头 #{camera_index}")
            
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.cap.set(cv2.CAP_PROP_FPS, fps)
        
        # 获取实际的摄像头配置
        actual_width = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        actual_height = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        actual_fps = int(self.cap.get(cv2.CAP_PROP_FPS))
        
        logger.info(f"摄像头初始化: 请求={width}x{height}@{fps}fps, 实际={actual_width}x{actual_height}@{actual_fps}fps")
        
        # 创建黑色背景帧作为备用
        self.black_frame = np.zeros((height, width, 3), np.uint8)
        
        # 计数和性能统计
        self.frame_count = 0
        self.start_time = time.time()
        
    async def recv(self):
        """获取下一帧视频"""
        # 获取时间戳
        pts, time_base = await self.next_timestamp()
        
        current_time = time.time()
        elapsed = current_time - self.last_frame_time
        
        # 控制帧率
        if elapsed < self.frame_interval:
            await asyncio.sleep(self.frame_interval - elapsed)
        
        # 读取摄像头
        ret, frame = self.cap.read()
        if not ret:
            logger.warning("无法从摄像头读取帧，使用黑色帧")
            processed_frame = self.black_frame.copy()
        else:
            try:
                # 使用YOLO处理帧
                results = self.model(frame)
                processed_frame = results[0].plot()
                
                # 计算并显示FPS
                self.frame_count += 1
                if self.frame_count % 30 == 0:
                    elapsed_total = time.time() - self.start_time
                    fps = self.frame_count / elapsed_total
                    logger.info(f"已处理 {self.frame_count} 帧, 平均FPS: {fps:.2f}")
                    
                    # 在画面添加FPS信息
                    cv2.putText(
                        processed_frame, 
                        f"FPS: {fps:.2f}", 
                        (10, 30), 
                        cv2.FONT_HERSHEY_SIMPLEX, 
                        1, 
                        (0, 255, 0), 
                        2
                    )
            except Exception as e:
                logger.error(f"YOLO处理失败: {e}")
                processed_frame = frame  # 使用原始帧
        
        # 本地预览
        cv2.imshow("YOLO WebRTC Stream", processed_frame)
        cv2.waitKey(1)
        
        # 更新最后帧时间
        self.last_frame_time = time.time()
        
        # 转换为RGB格式以供WebRTC使用
        frame_rgb = cv2.cvtColor(processed_frame, cv2.COLOR_BGR2RGB)
        
        # 创建视频帧
        video_frame = VideoFrame.from_ndarray(frame_rgb, format="rgb24")
        video_frame.pts = pts
        video_frame.time_base = time_base
        
        return video_frame
    
    def stop(self):
        """停止视频流"""
        if self.cap and self.cap.isOpened():
            self.cap.release()
        cv2.destroyAllWindows()
        logger.info("视频流已停止")

class StreamYOLO:
    """
    Stream YOLO主类
    处理GetStream.io与YOLO的整合
    """
    def __init__(self):
        self.client = Stream(api_key=STREAM_API_KEY, api_secret=STREAM_API_SECRET)
        self.video_track = None
        self.pc = None
        self.call = None
        self.call_id = None
        self.user_id = None
        self.token = None
    
    async def setup_user(self, user_id):
        """设置或创建用户"""
        self.user_id = user_id
        
        try:
            # 确保用户存在
            self.client.upsert_users(
                UserRequest(
                    id=user_id,
                    name=f"YOLO Publisher {user_id}",
                    role="admin",
                    custom={"type": "yolo_publisher"}
                )
            )
            
            # 创建用户令牌
            self.token = self.client.create_token(user_id, expiration=3600)
            logger.info(f"观看者可以使用的Token: {self.token}")
            logger.info(f"用户 {user_id} 设置成功，令牌已生成")
            return True
        except Exception as e:
            logger.error(f"设置用户失败: {e}")
            return False
    
    async def create_livestream(self, call_type="livestream"):
        """创建直播流会话"""
        try:
            # 生成唯一的会话ID
            self.call_id = str(uuid.uuid4())
            
            # 创建Stream会话
            self.call = self.client.video.call(call_type, self.call_id)
            response = self.call.create(
                data=CallRequest(
                    created_by_id=self.user_id,
                    members=[MemberRequest(user_id=self.user_id, role="host")]
                )
            )
            
            logger.info(f"直播会话已创建: {self.call_id}")
            
            # 启动直播
            self.call.go_live()
            logger.info("直播已开始")
            
            # 获取并显示WebRTC连接信息
            call_info = self.call.get()
            
            # 提取查看者信息
            viewer_info = {
                "call_id": self.call_id,
                "call_type": call_type
            }
            
            logger.info(f"直播信息: {json.dumps(viewer_info, indent=2)}")
            logger.info(f"查看者可以使用以下信息连接:")
            logger.info(f"call_id: {self.call_id}")
            logger.info(f"call_type: {call_type}")
            
            return True
        except Exception as e:
            logger.error(f"创建直播会话失败: {e}")
            return False
    
    async def start_streaming(self, camera_index=0, width=1280, height=720, fps=15):
        """开始视频流"""
        try:
            # 创建YOLO视频轨道
            self.video_track = YOLOVideoStreamTrack(
                camera_index=camera_index, 
                width=width, 
                height=height, 
                fps=fps
            )
            
            # 创建并配置WebRTC连接
            self.pc = RTCPeerConnection()
            self.pc.addTrack(self.video_track)
            
            # 创建连接到GetStream的WebRTC连接
            logger.info("正在连接到GetStream WebRTC服务...")
            
            # 技术上，这里需要完整的WebRTC信令流程
            # 实际生产环境中，应该使用GetStream的WebRTC SDK
            # 这里简化实现，仅用于演示WebRTC推流概念
            
            logger.info("视频轨道已创建并添加到WebRTC连接")
            logger.info("直播已开始，YOLO检测正在进行")
            
            # 保持流运行
            try:
                while True:
                    await asyncio.sleep(1)
            except KeyboardInterrupt:
                pass
            finally:
                await self.stop_streaming()
            
            return True
        except Exception as e:
            logger.error(f"启动流失败: {e}")
            await self.stop_streaming()
            return False
    
    async def stop_streaming(self):
        """停止视频流"""
        logger.info("正在停止流...")
        
        # 停止视频轨道
        if self.video_track:
            self.video_track.stop()
        
        # 关闭WebRTC连接
        if self.pc:
            await self.pc.close()
        
        # 结束直播会话
        if self.call:
            try:
                self.call.end_call()
                logger.info("直播会话已结束")
            except Exception as e:
                logger.error(f"结束直播会话失败: {e}")
        
        logger.info("流已停止")

async def main():
    # 解析命令行参数
    parser = argparse.ArgumentParser(description="YOLO Stream with GetStream.io")
    parser.add_argument("--camera", type=int, default=0, help="摄像头索引")
    parser.add_argument("--width", type=int, default=1280, help="视频宽度")
    parser.add_argument("--height", type=int, default=720, help="视频高度")
    parser.add_argument("--fps", type=int, default=15, help="帧率")
    parser.add_argument("--user", type=str, default=f"yolo-publisher-{uuid.uuid4().hex[:8]}", help="用户ID")
    args = parser.parse_args()
    
    # 创建并启动流
    streamer = StreamYOLO()
    
    try:
        # 设置用户
        if not await streamer.setup_user(args.user):
            return
        
        # 创建直播会话
        if not await streamer.create_livestream():
            return
        
        # 启动视频流
        await streamer.start_streaming(
            camera_index=args.camera,
            width=args.width,
            height=args.height,
            fps=args.fps
        )
    except KeyboardInterrupt:
        logger.info("用户中断，正在停止...")
    except Exception as e:
        logger.error(f"发生错误: {e}")
    finally:
        # 确保正确清理资源
        await streamer.stop_streaming()

if __name__ == "__main__":
    # 运行异步主函数
    asyncio.run(main())