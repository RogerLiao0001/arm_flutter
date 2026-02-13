import argparse
import asyncio
import cv2
import json
import logging
import sys
import time
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from aiortc.contrib.media import MediaPlayer, MediaRelay
from av import VideoFrame
import numpy as np
import websockets
from ultralytics import YOLO

# 配置日誌
logging.basicConfig(level=logging.INFO, format='%(levelname)s:%(name)s:%(message)s')
logger = logging.getLogger('yolo-publisher')

class YOLOVideoStreamTrack(VideoStreamTrack):
    """
    使用 YOLO 進行物件檢測的視頻源
    """
    def __init__(self, camera_index, width, height, fps, model_path):
        super().__init__()
        self.camera = cv2.VideoCapture(camera_index)
        self.camera.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.camera.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.camera.set(cv2.CAP_PROP_FPS, fps)
        self.fps = fps
        self.frame_interval = 1 / fps
        self.last_frame_time = time.time()
        
        # 檢查攝像頭是否成功開啟
        if not self.camera.isOpened():
            raise ValueError(f"無法打開攝像頭 {camera_index}")
        
        logger.info(f"攝像頭初始化成功: {int(self.camera.get(cv2.CAP_PROP_FRAME_WIDTH))}x{int(self.camera.get(cv2.CAP_PROP_FRAME_HEIGHT))}")
        
        # 載入 YOLO 模型
        self.model = YOLO(model_path)
        logger.info(f"YOLO模型已加載: {model_path}")
        
        # 初始化 VideoFrame 計數器
        self.counter = 0
    
    async def recv(self):
        # 調整幀率
        now = time.time()
        wait_time = max(0, self.frame_interval - (now - self.last_frame_time))
        if wait_time > 0:
            await asyncio.sleep(wait_time)
            
        # 捕獲幀
        ret, frame = self.camera.read()
        if not ret:
            # 如果讀取失敗，嘗試重新開啟攝像頭
            logger.warning("攝像頭讀取失敗，嘗試重新開啟")
            self.camera.release()
            self.camera = cv2.VideoCapture(self.camera_index)
            ret, frame = self.camera.read()
            if not ret:
                logger.error("無法讀取攝像頭")
                # 返回黑色幀
                frame = np.zeros((480, 640, 3), dtype=np.uint8)
        
        # 使用 YOLO 進行物件檢測
        results = self.model(frame)
        
        # 在幀上繪製檢測結果
        annotated_frame = results[0].plot()
        
        # 將 OpenCV 格式 (BGR) 轉換為 PyAV 格式 (RGB)
        annotated_frame = cv2.cvtColor(annotated_frame, cv2.COLOR_BGR2RGB)
        
        # 創建 VideoFrame
        video_frame = VideoFrame.from_ndarray(annotated_frame, format="rgb24")
        video_frame.pts = self.counter
        video_frame.time_base = "1/" + str(self.fps)
        self.counter += 1
        self.last_frame_time = time.time()
        
        return video_frame
        
    def stop(self):
        """釋放攝像頭資源"""
        if self.camera.isOpened():
            self.camera.release()
            logger.info("攝像頭已釋放")

async def run_yolo_publisher(args):
    # 創建 VideoStreamTrack
    try:
        video_track = YOLOVideoStreamTrack(
            camera_index=args.camera,
            width=args.width,
            height=args.height,
            fps=args.fps,
            model_path=args.model
        )
    except Exception as e:
        logger.error(f"初始化視頻流失敗: {e}")
        return

    # 創建 PeerConnection
    pc = RTCPeerConnection()
    pc_initialized = False
    
    # 添加視頻軌道
    pc.addTrack(video_track)
    
    # 監控連接狀態
    @pc.on("iceconnectionstatechange")
    async def on_iceconnectionstatechange():
        logger.info(f"ICE連接狀態: {pc.iceConnectionState}")
        if pc.iceConnectionState == "failed" or pc.iceConnectionState == "closed":
            logger.info("清理資源...")

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        logger.info(f"連接狀態: {pc.connectionState}")
        if pc.connectionState == "failed" or pc.connectionState == "closed":
            logger.info("清理資源...")
    
    try:
        # 連接到 SFU
        logger.info(f"連接到 SFU: {args.sfu}")
        async with websockets.connect(args.sfu) as ws:
            # 創建 offer
            offer = await pc.createOffer()
            await pc.setLocalDescription(offer)
            
            # 發送加入請求
            join_message = {
                "method": "join",
                "params": {
                    "sid": args.stream_id,
                    "offer": {
                        "type": pc.localDescription.type,
                        "sdp": pc.localDescription.sdp
                    }
                },
                "id": "publisher-" + str(time.time_ns())
            }
            
            await ws.send(json.dumps(join_message))
            logger.info(f"已發送加入請求，流ID: {args.stream_id}")
            
            # 接收應答
            response = await ws.recv()
            try:
                data = json.loads(response)
                if "result" in data and "answer" in data["result"]:
                    answer = data["result"]["answer"]
                    
                    # 修復 DTLS 設置
                    sdp = answer["sdp"]
                    if "a=setup:actpass" in sdp:
                        sdp = sdp.replace("a=setup:actpass", "a=setup:active")
                    
                    # 設定遠端描述
                    await pc.setRemoteDescription(
                        RTCSessionDescription(type=answer["type"], sdp=sdp)
                    )
                    pc_initialized = True
                    logger.info("連接已建立")
                    
                    # 保持連接活躍
                    while True:
                        try:
                            # 等待消息，但不阻塞主循環
                            response = await asyncio.wait_for(ws.recv(), timeout=1.0)
                            # 可以處理接收到的消息，如果需要的話
                        except asyncio.TimeoutError:
                            # 超時，檢查連接狀態
                            if pc.connectionState != "connected":
                                logger.warning(f"連接狀態: {pc.connectionState}")
                                if pc.connectionState in ["failed", "closed"]:
                                    break
                        except websockets.exceptions.ConnectionClosed:
                            logger.warning("WebSocket 連接已關閉")
                            break
                                
                else:
                    logger.error(f"未收到預期的回應: {data}")
            except Exception as e:
                logger.error(f"處理回應時出錯: {e}")
    except Exception as e:
        logger.error(f"連接錯誤: {e}")
    finally:
        # 清理資源
        if pc_initialized:
            await pc.close()
        video_track.stop()
        logger.info("已關閉連接")

def main():
    parser = argparse.ArgumentParser(description='YOLO WebRTC 推流器')
    parser.add_argument('--sfu', type=str, default="ws://localhost:7000", help='SFU WebSocket URL')
    parser.add_argument('--model', type=str, required=True, help='YOLO 模型路徑')
    parser.add_argument('--camera', type=int, default=0, help='攝像頭索引')
    parser.add_argument('--width', type=int, default=640, help='視頻寬度')
    parser.add_argument('--height', type=int, default=480, help='視頻高度')
    parser.add_argument('--fps', type=int, default=15, help='幀率')
    parser.add_argument('--stream-id', type=str, default="yolo-main-stream", help='流 ID')
    parser.add_argument('--log', type=str, default="INFO", help='日誌級別 (DEBUG, INFO, WARNING, ERROR)')
    
    args = parser.parse_args()
    
    # 設置日誌級別
    numeric_level = getattr(logging, args.log.upper(), None)
    if not isinstance(numeric_level, int):
        raise ValueError(f'無效的日誌級別: {args.log}')
    logger.setLevel(numeric_level)
    
    logger.info("等待初始化...")
    
    # 運行推流器
    asyncio.run(run_yolo_publisher(args))

if __name__ == "__main__":
    main()