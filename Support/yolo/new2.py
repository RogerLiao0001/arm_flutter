#!/usr/bin/env python3
import cv2
import time
import subprocess
import logging
from ultralytics import YOLO

# 配置日志
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("YOLOStream")

# Stream RTMP配置 - 使用您Stream控制台提供的值
RTMP_URL = "rtmps://ingress.stream-io-video.com:443/rb53y4n75g3n.livestream.livestream_737285c5-f704-40f3-95e9-37164c259164"
STREAM_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VyX2lkIjoicm9nZXIwMDAxIiwiaWF0IjoxNzQyOTk3OTQ5fQ.Fx51gAgCJ3XyRMRh6cA-anBqT4RPlZsSS-B08g0P8mQ"

def main():
    # 配置参数
    width = 1280
    height = 720
    fps = 15
    
    # 加载YOLO模型
    logger.info("正在加载YOLO模型...")
    model = YOLO("models/best.pt")
    
    # 初始化摄像头
    logger.info("初始化摄像头...")
    cap = cv2.VideoCapture(0)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, fps)
    
    if not cap.isOpened():
        logger.error("无法打开摄像头")
        return
    
    # 启动FFmpeg进程
    command = [
        'ffmpeg',
        '-y',
        '-f', 'rawvideo',
        '-vcodec', 'rawvideo',
        '-pix_fmt', 'bgr24',
        '-s', f"{width}x{height}",
        '-r', str(fps),
        '-i', '-',
        '-c:v', 'libx264',
        '-pix_fmt', 'yuv420p',
        '-preset', 'ultrafast',
        '-f', 'flv', 
        f"{RTMP_URL}/{STREAM_KEY}"
    ]
    
    logger.info("启动FFmpeg进程...")
    ffmpeg = subprocess.Popen(command, stdin=subprocess.PIPE)
    
    # 开始主循环
    logger.info("开始YOLO检测并推流到Stream...")
    frame_count = 0
    start_time = time.time()
    
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                logger.warning("无法读取摄像头帧")
                break
            
            # YOLO处理
            results = model(frame)
            processed_frame = results[0].plot()
            
            # 显示本地预览
            cv2.imshow('YOLO Stream', processed_frame)
            
            # 发送到FFmpeg
            ffmpeg.stdin.write(processed_frame.tobytes())
            
            # 计算并显示FPS
            frame_count += 1
            if frame_count % 30 == 0:
                elapsed = time.time() - start_time
                fps_actual = frame_count / elapsed
                logger.info(f"已发送 {frame_count} 帧, 实际FPS: {fps_actual:.2f}")
            
            # 检测退出
            if cv2.waitKey(1) & 0xFF == ord('q'):
                break
                
    except KeyboardInterrupt:
        logger.info("用户中断")
    finally:
        # 清理资源
        cap.release()
        ffmpeg.stdin.close()
        ffmpeg.wait()
        cv2.destroyAllWindows()
        logger.info("推流已停止")

if __name__ == "__main__":
    main()