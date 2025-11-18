# yolo_bot.py
import asyncio
import json
import logging
import os
import numpy as np
import cv2
from livekit import rtc, api
from ultralytics import YOLO
from dotenv import load_dotenv

# --- 基本日誌設定 ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - [YOLO Bot] - %(message)s')

# --- 載入環境變數 ---
load_dotenv()
LIVEKIT_URL = os.getenv('LIVEKIT_URL', 'wss://test-wfkuoo8g.livekit.cloud')
LIVEKIT_API_KEY = os.getenv('LIVEKIT_API_KEY')
LIVEKIT_API_SECRET = os.getenv('LIVEKIT_API_SECRET')
ROOM_NAME = os.getenv('LIVEKIT_ROOM_NAME', 'my-room')
MODEL_PATH = os.getenv('YOLO_MODEL_PATH', 'models/best.pt')

# --- Bot 的身份設定 ---
YOLO_BOT_IDENTITY = 'yolo-bot'
# Bot 需要訂閱的影像來源身份
PUBLISHER_IDENTITY = 'webcam-publisher'

class YoloProcessor:
    def __init__(self, model_path: str):
        self.model = YOLO(model_path)
        logging.info(f"YOLO model loaded from {model_path}")
        self.room: rtc.Room = None
        self.processing_task = None

    async def _process_track(self, track: rtc.VideoTrack):
        logging.info(f"Starting processing for track: {track.sid}")
        try:
            # 異步地從視訊軌道讀取每一幀
            async for frame in rtc.VideoSource.from_track(track):
                # 將 LiveKit Frame 轉為 OpenCV 格式 (ndarray)
                buffer = frame.frame
                # to_ndarray 是一個方便的輔助函數
                arr = buffer.to_ndarray(format="bgr24")

                # --- 執行 YOLO 偵測 ---
                results = self.model.predict(arr, verbose=False, device='cpu') # device='cpu' or '0' for GPU

                # 準備要發送的座標資料
                detections = []
                for r in results:
                    for box in r.boxes:
                        # 獲取正規化的座標 [x_center, y_center, width, height]
                        x_center, y_center, width, height = box.xyn[0].tolist()
                        # 轉換為左上角座標 [x, y, width, height]
                        x = x_center - (width / 2)
                        y = y_center - (height / 2)
                        
                        detections.append({
                            'label': self.model.names[int(box.cls)],
                            'confidence': float(box.conf),
                            'box': [x, y, width, height]
                        })
                
                # --- 透過 Data Channel 發送結果 ---
                if detections:
                    payload = json.dumps(detections).encode('utf-8')
                    try:
                        # 使用 RELIABLE 確保資料送達
                        await self.room.local_participant.publish_data(payload, kind=api.DataPacketKind.RELIABLE)
                    except Exception as e:
                        logging.warning(f"Failed to publish data: {e}")
                
                # 讓出控制權給 asyncio 事件迴圈，避免阻塞
                await asyncio.sleep(0.01)

        except Exception as e:
            logging.error(f"Error while processing track {track.sid}: {e}", exc_info=True)
        finally:
            logging.info(f"Finished processing for track: {track.sid}")


    async def run(self):
        # 產生一個有訂閱和發布資料權限的 Token
        token = (api.AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
                 .with_identity(YOLO_BOT_IDENTITY)
                 .with_grants(api.VideoGrants(
                    room_join=True,
                    room=ROOM_NAME,
                    can_publish=False,       # Bot 不需要發布影像
                    can_publish_data=True,   # Bot 需要發布資料
                    can_subscribe=True       # Bot 需要訂閱影像
                 )).to_jwt())
        
        self.room = rtc.Room()

        @self.room.on("track_subscribed")
        async def on_track_subscribed(track: rtc.Track, publication: rtc.RemoteTrackPublication, participant: rtc.RemoteParticipant):
            # 只處理來自指定發布者的視訊軌道
            if track.kind == rtc.TrackKind.VIDEO and participant.identity == PUBLISHER_IDENTITY:
                logging.info(f"Subscribed to video track from {participant.identity}, starting processing task.")
                # 如果已有處理任務，先取消
                if self.processing_task:
                    self.processing_task.cancel()
                # 建立一個新的異步任務來處理這個軌道
                self.processing_task = asyncio.create_task(self._process_track(track))
        
        @self.room.on("disconnected")
        async def on_disconnected():
            logging.info("Disconnected from the room.")
            if self.processing_task:
                self.processing_task.cancel()

        try:
            logging.info(f"Connecting to room '{ROOM_NAME}' as '{YOLO_BOT_IDENTITY}'...")
            await self.room.connect(LIVEKIT_URL, token)
            logging.info("Connection successful. Bot is running and waiting for publisher.")
            # 保持運行，直到被外部中斷
            await self.room.run()

        except Exception as e:
            logging.error(f"Failed to connect or run the bot: {e}", exc_info=True)
        finally:
            logging.info("Shutting down bot.")
            if self.processing_task:
                self.processing_task.cancel()
            if self.room and self.room.connection_state == rtc.ConnectionState.CONNECTED:
                await self.room.disconnect()


if __name__ == "__main__":
    if not LIVEKIT_API_KEY or not LIVEKIT_API_SECRET:
        logging.error("FATAL: LIVEKIT_API_KEY and LIVEKIT_API_SECRET must be set.")
    else:
        processor = YoloProcessor(model_path=MODEL_PATH)
        try:
            asyncio.run(processor.run())
        except KeyboardInterrupt:
            logging.info("Bot stopped by user.")