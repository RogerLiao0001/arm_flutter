# ai_bot.py - AWS GPU 優化版本
import asyncio
import json
import logging
import os
from pathlib import Path
from livekit import rtc, api
from ultralytics import YOLO
from dotenv import load_dotenv
import torch

# --- 日誌設定 ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - [AI Bot] - %(message)s')

# --- 載入環境變數 ---
load_dotenv()
LIVEKIT_URL = os.getenv('LIVEKIT_URL', 'wss://test-wfkuoo8g.livekit.cloud')
LIVEKIT_API_KEY = os.getenv('LIVEKIT_API_KEY')
LIVEKIT_API_SECRET = os.getenv('LIVEKIT_API_SECRET')
ROOM_NAME = os.getenv('LIVEKIT_ROOM_NAME', 'my-room')
MODELS_DIR = os.getenv('MODELS_DIR', 'models2')

# --- Bot 設定 ---
YOLO_BOT_IDENTITY = 'yolo-bot'
PUBLISHER_IDENTITY = 'webcam-publisher'
FRAME_INTERVAL = 2  # 每 2 幀處理一次（降低 GPU 負載）

class AIBot:
    def __init__(self, models_dir: str):
        self.models_dir = Path(models_dir)
        self.current_model = None
        self.current_model_name = None
        self.room = None
        self.frame_count = 0
        self.device = 'cuda' if torch.cuda.is_available() else 'cpu'

        logging.info(f"Device: {self.device}")
        if self.device == 'cuda':
            logging.info(f"GPU: {torch.cuda.get_device_name(0)}")

        # 掃描可用模型
        self.available_models = self._scan_models()
        logging.info(f"Available models: {self.available_models}")

        # 載入預設模型
        if self.available_models:
            self.load_model(self.available_models[0])

    def _scan_models(self):
        """掃描 models2 資料夾中的所有 .pt 檔案"""
        if not self.models_dir.exists():
            logging.warning(f"Models directory not found: {self.models_dir}")
            return []

        models = [f.name for f in self.models_dir.glob('*.pt')]
        return sorted(models)

    def load_model(self, model_name: str):
        """載入 YOLO 模型"""
        model_path = self.models_dir / model_name

        if not model_path.exists():
            logging.error(f"Model not found: {model_path}")
            return False

        try:
            logging.info(f"Loading model: {model_name}")
            self.current_model = YOLO(str(model_path))
            self.current_model.to(self.device)
            self.current_model_name = model_name
            logging.info(f"Model loaded successfully: {model_name}")
            return True
        except Exception as e:
            logging.error(f"Failed to load model {model_name}: {e}")
            return False

    async def broadcast_model_list(self):
        """廣播模型列表給所有參與者"""
        if not self.room:
            return

        payload = {
            'type': 'modelList',
            'models': self.available_models,
            'current': self.current_model_name
        }

        data = json.dumps(payload).encode('utf-8')
        await self.room.local_participant.publish_data(data, kind=api.DataPacketKind.RELIABLE)
        logging.info(f"Broadcasted model list: {self.available_models}")

    def on_frame_received(self, event: rtc.VideoFrameEvent):
        """處理接收到的影像幀（事件驅動）"""
        self.frame_count += 1

        # 幀抽樣：每 N 幀處理一次
        if self.frame_count % FRAME_INTERVAL != 0:
            return

        if not self.current_model:
            return

        # 轉換影像格式
        frame = event.frame
        arr = frame.to_ndarray(format="bgr24")

        # YOLO 推理（GPU）
        try:
            results = self.current_model.predict(
                arr,
                verbose=False,
                device=self.device,
                conf=0.5,  # 信心度閾值
                half=True if self.device == 'cuda' else False  # FP16 加速
            )

            # 準備偵測結果
            detections = []
            for r in results:
                for box in r.boxes:
                    x_center, y_center, width, height = box.xyn[0].tolist()
                    x = x_center - (width / 2)
                    y = y_center - (height / 2)

                    detections.append({
                        'label': self.current_model.names[int(box.cls)],
                        'confidence': float(box.conf),
                        'box': [x, y, width, height]
                    })

            # 廣播結果
            if detections:
                asyncio.create_task(self._send_detections(detections))

        except Exception as e:
            logging.error(f"YOLO prediction error: {e}")

    async def _send_detections(self, detections):
        """發送偵測結果"""
        if not self.room:
            return

        payload = json.dumps(detections).encode('utf-8')
        try:
            await self.room.local_participant.publish_data(
                payload,
                kind=api.DataPacketKind.RELIABLE
            )
        except Exception as e:
            logging.warning(f"Failed to send detections: {e}")

    async def on_data_received(self, data_packet: rtc.DataPacket, participant):
        """處理接收到的指令"""
        if participant.identity != PUBLISHER_IDENTITY:
            return

        try:
            message = json.loads(data_packet.data.decode('utf-8'))
            msg_type = message.get('type')

            if msg_type == 'setModel':
                model_name = message.get('model')
                if model_name in self.available_models:
                    if self.load_model(model_name):
                        await self.broadcast_model_list()
                        logging.info(f"Model switched to: {model_name}")
                else:
                    logging.warning(f"Invalid model requested: {model_name}")

            elif msg_type == 'requestModels':
                await self.broadcast_model_list()

        except Exception as e:
            logging.error(f"Error processing data: {e}")

    async def run(self):
        """主執行函式"""
        # 生成 Token
        token = (api.AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
                 .with_identity(YOLO_BOT_IDENTITY)
                 .with_grants(api.VideoGrants(
                    room_join=True,
                    room=ROOM_NAME,
                    can_publish=False,
                    can_publish_data=True,
                    can_subscribe=True
                 )).to_jwt())

        self.room = rtc.Room()

        # 註冊事件處理器
        @self.room.on("track_subscribed")
        def on_track_subscribed(
            track: rtc.Track,
            publication: rtc.RemoteTrackPublication,
            participant: rtc.RemoteParticipant
        ):
            if track.kind == rtc.TrackKind.KIND_VIDEO and participant.identity == PUBLISHER_IDENTITY:
                logging.info(f"Subscribed to video from {participant.identity}")
                # 註冊幀接收事件
                track.on("frame_received", self.on_frame_received)

        @self.room.on("data_received")
        def on_data_received(data_packet: rtc.DataPacket, participant):
            asyncio.create_task(self.on_data_received(data_packet, participant))

        @self.room.on("participant_connected")
        async def on_participant_connected(participant: rtc.RemoteParticipant):
            logging.info(f"Participant connected: {participant.identity}")
            # 新參與者加入時廣播模型列表
            if participant.identity == PUBLISHER_IDENTITY:
                await asyncio.sleep(1)  # 等待連接穩定
                await self.broadcast_model_list()

        @self.room.on("disconnected")
        def on_disconnected():
            logging.info("Disconnected from room")

        try:
            logging.info(f"Connecting to room '{ROOM_NAME}' as '{YOLO_BOT_IDENTITY}'...")
            await self.room.connect(LIVEKIT_URL, token)
            logging.info("Connected! Waiting for publisher...")

            # 保持運行
            await asyncio.Event().wait()

        except Exception as e:
            logging.error(f"Error: {e}", exc_info=True)
        finally:
            if self.room:
                await self.room.disconnect()
            logging.info("Bot shutdown complete")


if __name__ == "__main__":
    if not LIVEKIT_API_KEY or not LIVEKIT_API_SECRET:
        logging.error("FATAL: LIVEKIT_API_KEY and LIVEKIT_API_SECRET must be set")
        exit(1)

    bot = AIBot(models_dir=MODELS_DIR)

    try:
        asyncio.run(bot.run())
    except KeyboardInterrupt:
        logging.info("Bot stopped by user")
