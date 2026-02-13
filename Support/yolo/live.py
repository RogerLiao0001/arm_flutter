#!/usr/bin/env python3
import cv2
import asyncio
import time
import numpy as np
import logging
from ultralytics import YOLO
from livekit import rtc, api
from dotenv import load_dotenv
import os

# 載入環境變數
load_dotenv('development.env')

# 設定日誌
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s:%(message)s')
logger = logging.getLogger("livekit-publisher")

# 生成存取 Token
def generate_token():
    token = api.AccessToken() \
        .with_identity("python-bot") \
        .with_name("Python Bot") \
        .with_grants(api.VideoGrants(room_join=True, room="my-room")) \
        .to_jwt()
    return token

# 定義異步生成器，持續輸出經 YOLO 處理的視頻幀
async def video_generator(cap, model, target_fps):
    while True:
        ret, frame = await asyncio.to_thread(cap.read)
        if not ret:
            logger.error("無法從攝影機讀取幀")
            continue
        # 翻轉畫面（可根據需求調整）
        frame = cv2.flip(frame, 1)
        try:
            # 使用 YOLO 模型處理並疊加檢測結果
            results = await asyncio.to_thread(model, frame)
            processed = results[0].plot()
            # 確保處理後的幀尺寸與原始幀一致
            processed = cv2.resize(processed, (frame.shape[1], frame.shape[0]))
            # 將 BGR 轉換為 RGB
            processed = cv2.cvtColor(processed, cv2.COLOR_BGR2RGB)
        except Exception as e:
            logger.error("YOLO 處理錯誤: %s", e)
            processed = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        # 顯示處理後的畫面供本地調試
        cv2.imshow("Processed Frame", cv2.cvtColor(processed, cv2.COLOR_RGB2BGR))
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break
        yield processed  # 傳出處理後的幀 (numpy array)
        await asyncio.sleep(1 / target_fps)
    cap.release()
    cv2.destroyAllWindows()

# 自訂視頻來源
class CustomVideoSource(rtc.VideoSource):
    def __init__(self, generator, width, height):
        super().__init__(width, height)
        self._generator = generator
        self._running = True

    async def capture_frames(self):
        frame_count = 0
        async for frame in self._generator:
            if not self._running:
                break
            # 每 10 幀保存一次以供調試
            if frame_count % 10 == 0:
                cv2.imwrite(f"frame_{frame_count}.jpg", cv2.cvtColor(frame, cv2.COLOR_RGB2BGR))
            # 將 numpy array 轉換為 LiveKit 的 VideoFrame
            from livekit.rtc.video_frame import VideoFrame, VideoBufferType
            video_frame = VideoFrame(width=self.width, height=self.height,
                                     type=VideoBufferType.RGB24,
                                     data=frame.tobytes())
            # 使用 monotonic 時間生成時間戳
            timestamp_us = int(time.monotonic() * 1e6)
            self.capture_frame(video_frame, timestamp_us=timestamp_us, rotation=0)
            frame_count += 1
            await asyncio.sleep(0)  # 讓出控制權

    def stop(self):
        self._running = False

async def main():
    # 初始化 YOLO 模型
    model = YOLO("models/best.pt")
    
    # 開啟攝影機
    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        logger.error("無法開啟攝影機")
        return
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    target_fps = 15
    logger.info("攝影機初始化成功：640x480，目標 FPS: %d", target_fps)
    
    # 生成 token 與設定連線資訊
    token = generate_token()
    ws_url = "wss://test-wfkuoo8g.livekit.cloud"  # 請替換為您的 LiveKit 服務 WebSocket URL
    # 建立 LiveKit 房間連線
    room = rtc.Room()
    await room.connect(ws_url, token)
    logger.info("已連線至 LiveKit 房間: %s", room.name)
    
    # 建立自訂視頻來源
    gen_instance = video_generator(cap, model, target_fps)
    source = CustomVideoSource(gen_instance, width=640, height=480)
    
    # 使用 LiveKit 的 create_video_track 靜態方法建立本地視頻軌道
    video_track = rtc.LocalVideoTrack.create_video_track("YOLO Track", source)
    
    # 發布視頻軌道到房間
    await room.local_participant.publish_track(video_track)
    logger.info("視頻軌道已發布: %s", video_track.sid)
    
    # 啟動捕獲幀的任務
    capture_task = asyncio.create_task(source.capture_frames())
    
    # 保持連線（按 Ctrl+C 結束）
    try:
        while True:
            await asyncio.sleep(1)
    except KeyboardInterrupt:
        logger.info("中斷推流")
        source.stop()
        await capture_task
    finally:
        await room.disconnect()
        logger.info("已斷開連線")

if __name__ == "__main__":
    asyncio.run(main())