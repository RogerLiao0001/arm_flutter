# ai_bot.py - AWS GPU 優化版本（最終修正）
import asyncio
import json
import logging
import os
from pathlib import Path
from livekit import rtc, api
from ultralytics import YOLO
from dotenv import load_dotenv
import torch

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - [AI Bot] - %(message)s')

if os.path.exists('development.env'):
    load_dotenv('development.env')
else:
    load_dotenv()
LIVEKIT_URL = os.getenv('LIVEKIT_URL', 'wss://test-wfkuoo8g.livekit.cloud')
LIVEKIT_API_KEY = os.getenv('LIVEKIT_API_KEY')
LIVEKIT_API_SECRET = os.getenv('LIVEKIT_API_SECRET')
ROOM_NAME = os.getenv('LIVEKIT_ROOM_NAME', 'my-room')
MODELS_DIR = os.getenv('MODELS_DIR', 'models2')

YOLO_BOT_IDENTITY = 'yolo-bot'
PUBLISHER_IDENTITY = 'webcam-publisher'
FRAME_INTERVAL = 2

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

        self.available_models = self._scan_models()
        logging.info(f"Available models: {self.available_models}")

        if self.available_models:
            self.load_model(self.available_models[0])

    def _scan_models(self):
        if not self.models_dir.exists():
            logging.warning(f"Models directory not found: {self.models_dir}")
            return []
        models = [f.name for f in self.models_dir.glob('*.pt') if not f.name.startswith('._')]
        return sorted(models)

    def load_model(self, model_name: str):
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
        if not self.room:
            return
        payload = {
            'type': 'modelList',
            'models': self.available_models,
            'current': self.current_model_name
        }
        data = json.dumps(payload).encode('utf-8')
        await self.room.local_participant.publish_data(data, reliable=True)
        logging.info(f"Broadcasted model list: {self.available_models}")

    async def _handle_participant_connected(self):
        await asyncio.sleep(1)
        await self.broadcast_model_list()

    async def process_video_frames(self, track: rtc.VideoTrack):
        """處理影像幀的任務"""
        video_stream = rtc.VideoStream(track)
        logging.info("Started processing video frames")

        async for event in video_stream:
            self.frame_count += 1

            if self.frame_count % FRAME_INTERVAL != 0:
                continue

            if not self.current_model:
                continue

            frame = event.frame
            arr = frame.to_ndarray(format="bgr24")

            try:
                results = self.current_model.predict(
                    arr,
                    verbose=False,
                    device=self.device,
                    conf=0.5,
                    half=True if self.device == 'cuda' else False
                )

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

                if detections:
                    await self._send_detections(detections)

            except Exception as e:
                logging.error(f"YOLO prediction error: {e}")

    async def _send_detections(self, detections):
        if not self.room:
            return
        payload = json.dumps(detections).encode('utf-8')
        try:
            await self.room.local_participant.publish_data(payload, reliable=True)
        except Exception as e:
            logging.warning(f"Failed to send detections: {e}")

    async def on_data_received(self, data: bytes, participant):
        if participant.identity != PUBLISHER_IDENTITY:
            return
        try:
            message = json.loads(data.decode('utf-8'))
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

        @self.room.on("track_subscribed")
        def on_track_subscribed(
            track: rtc.Track,
            publication: rtc.RemoteTrackPublication,
            participant: rtc.RemoteParticipant
        ):
            if track.kind == rtc.TrackKind.KIND_VIDEO and participant.identity == PUBLISHER_IDENTITY:
                logging.info(f"Subscribed to video from {participant.identity}")
                # 啟動影像處理任務
                asyncio.create_task(self.process_video_frames(track))

        @self.room.on("data_received")
        def on_data_received(data_event):
            asyncio.create_task(self.on_data_received(data_event.data, data_event.participant))

        @self.room.on("participant_connected")
        def on_participant_connected(participant: rtc.RemoteParticipant):
            logging.info(f"Participant connected: {participant.identity}")
            if participant.identity == PUBLISHER_IDENTITY:
                asyncio.create_task(self._handle_participant_connected())

        @self.room.on("disconnected")
        def on_disconnected():
            logging.info("Disconnected from room")

        try:
            logging.info(f"Connecting to room '{ROOM_NAME}' as '{YOLO_BOT_IDENTITY}'...")
            await self.room.connect(LIVEKIT_URL, token)
            logging.info("Connected! Waiting for publisher...")
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
