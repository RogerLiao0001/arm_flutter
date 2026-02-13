#!/usr/bin/env python3
import os
import asyncio
import subprocess
import threading
import time
import cv2
import logging
import argparse
import numpy as np

from ultralytics import YOLO
from dotenv import load_dotenv

# 從 LiveKit API 模組中匯入 Ingress 相關類別
from livekit import api
from livekit.api.ingress_service import CreateIngressRequest, ListIngressRequest
from livekit.api.twirp_client import TwirpError

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s:%(message)s')
logger = logging.getLogger("rtmp-publisher")

# 預設參數
DEFAULT_ROOM = "my-room"
DEFAULT_PARTICIPANT_IDENTITY = "rtmp-participant"
DEFAULT_PARTICIPANT_NAME = "RTMP Ingress Participant"
DEFAULT_INGRESS_NAME = "my-rtmp-ingress"

# 加载环境变量
load_dotenv('development.env')

async def get_existing_ingress(room_name: str, participant_identity: str) -> dict:
    """查詢指定房間中是否有與該身份相符的 Ingress"""
    livekit_url = os.getenv("LIVEKIT_URL")
    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")
    lkapi = api.LiveKitAPI(livekit_url, api_key, api_secret)
    ingress_client = lkapi.ingress
    try:
        list_req = ListIngressRequest(room_name=room_name)
        ingress_list = await ingress_client.list_ingress(list_req)
        for item in ingress_list.ingresses:
            if item.room_name == room_name and item.participant_identity == participant_identity:
                logger.info("重複利用現有 Ingress: %s", item.ingress_id)
                await lkapi.aclose()
                return item
    except Exception as e:
        logger.error("列出 Ingress 時發生錯誤: %s", e)
    await lkapi.aclose()
    return None

async def get_or_create_rtmp_ingress(name: str, room_name: str,
                                     participant_identity: str, participant_name: str,
                                     enable_transcoding: bool = True) -> dict:
    """
    嘗試建立 RTMP Ingress，如果出現 concurrent ingress sessions limit exceeded，
    就重複利用現有的 Ingress（如果有符合條件的）。
    """
    livekit_url = os.getenv("LIVEKIT_URL")
    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")
    if not (livekit_url and api_key and api_secret):
        raise ValueError("請先設定 LIVEKIT_URL, LIVEKIT_API_KEY 與 LIVEKIT_API_SECRET")
    
    lkapi = api.LiveKitAPI(livekit_url, api_key, api_secret)
    ingress_client = lkapi.ingress

    create_req = CreateIngressRequest(
        input_type=0,  # RTMP 輸入
        name=name,
        room_name=room_name,
        participant_identity=participant_identity,
        participant_name=participant_name,
        enable_transcoding=True,  # 固定啟用轉碼以獲得較高畫質
        video={"name": "camera", "source": "CAMERA"},
        audio={"name": "microphone", "source": "MICROPHONE"}
    )
    try:
        ingress_info = await ingress_client.create_ingress(create_req)
        logger.info(f"Ingress 建立完成: {ingress_info}")
    except TwirpError as te:
        if te.args[0] == "resource_exhausted":
            logger.error("建立 Ingress 時資源不足：%s", te)
            logger.info("嘗試重複利用現有 Ingress ...")
            ingress_info = await get_existing_ingress(room_name, participant_identity)
            if not ingress_info:
                logger.error("沒有可重複利用的 Ingress，請先刪除現有 ingress")
                await lkapi.aclose()
                raise te
        else:
            await lkapi.aclose()
            raise te
    await lkapi.aclose()
    return ingress_info

def run_yolo_ffmpeg_loop(rtmp_url: str, camera_index: int, width: int, height: int, fps: int, model_path: str):
    """
    使用 YOLO 處理攝影機畫面，然後用 FFmpeg 將每一幀以 RTMP 推流到指定 URL。
    就像現場搖滾，每一幀都是主唱的狂熱獨奏！
    """
    logger.info(f"即將推流到 RTMP: {rtmp_url}")
    model = YOLO(model_path)
    logger.info(f"YOLO 模型已載入: {model_path}")

    cap = cv2.VideoCapture(camera_index)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, fps)

    if not cap.isOpened():
        logger.error(f"無法打開攝影機 index={camera_index}")
        return

    actual_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    logger.info(f"攝影機初始化成功：{actual_width}x{actual_height}, 目標 FPS: {fps}")

    ffmpeg_cmd = [
        "ffmpeg",
        "-y",
        "-f", "rawvideo",
        "-pix_fmt", "bgr24",
        "-s", f"{actual_width}x{actual_height}",
        "-r", str(fps),
        "-i", "-",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-tune", "zerolatency",
        "-pix_fmt", "yuv420p",
        "-g", str(fps),
        "-keyint_min", str(fps),
        "-b:v", "5000k",
        "-f", "flv",
        rtmp_url
    ]
    logger.info("FFmpeg 命令: " + " ".join(ffmpeg_cmd))

    process = subprocess.Popen(ffmpeg_cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    lock = threading.Lock()
    latest_frame = None
    stop_flag = False
    display_enabled = True  # 初始狀態允許顯示

    def yolo_thread():
        nonlocal latest_frame, stop_flag, display_enabled
        while not stop_flag:
            ret, frame = cap.read()
            if not ret:
                logger.warning("攝影機讀取失敗")
                time.sleep(0.01)
                continue

            frame = cv2.flip(frame, 1)

            try:
                result = model(frame)  # 每幀 YOLO 推論
                annotated = result[0].plot()  # 得到 YOLO 標記後的畫面 (BGR)
                annotated = np.clip(annotated, 0, 255).astype(np.uint8)
                # 如果輸出尺寸不對，強制調整
                if annotated.shape[1] != actual_width or annotated.shape[0] != actual_height:
                    annotated = cv2.resize(annotated, (actual_width, actual_height))
            except Exception as e:
                logger.error(f"YOLO 處理錯誤: {e}")
                annotated = frame

            if display_enabled:
                try:
                    cv2.imshow("YOLO Processed", annotated)
                    if cv2.waitKey(1) & 0xFF == ord('q'):
                        stop_flag = True
                        break
                except cv2.error as e:
                    logger.error(f"cv2.imshow/waitKey error: {e}")
                    display_enabled = False  # 一旦發生錯誤就停用顯示

            with lock:
                latest_frame = annotated.copy()
        logger.info("YOLO 線程結束")

    t = threading.Thread(target=yolo_thread, daemon=True)
    t.start()

    try:
        while True:
            with lock:
                if latest_frame is None:
                    continue
                frame_to_send = latest_frame
            try:
                process.stdin.write(frame_to_send.tobytes())
                process.stdin.flush()
            except BrokenPipeError:
                logger.error("FFmpeg 管道中斷，結束推流")
                break
            time.sleep(1.0 / fps)
    except KeyboardInterrupt:
        logger.info("使用者中斷")
    finally:
        stop_flag = True
        t.join()
        cap.release()
        cv2.destroyAllWindows()
        if process.stdin:
            process.stdin.close()
        process.wait()
        logger.info("程序已結束，FFmpeg 已關閉")

async def main():
    parser = argparse.ArgumentParser(description="RTMP 推流至 LiveKit Ingress (YOLO + FFmpeg)")
    parser.add_argument("--camera", type=int, default=0, help="攝影機索引")
    parser.add_argument("--width", type=int, default=1920, help="攝影機寬度")
    parser.add_argument("--height", type=int, default=1080, help="攝影機高度")
    parser.add_argument("--fps", type=int, default=15, help="目標 FPS")
    parser.add_argument("--model", type=str, default="models/11-1.pt", help="YOLO 模型路徑")
    parser.add_argument("--room", type=str, default=DEFAULT_ROOM, help="LiveKit 房間名稱")
    parser.add_argument("--participant-identity", type=str, default=DEFAULT_PARTICIPANT_IDENTITY, help="Ingress 連線身份")
    parser.add_argument("--participant-name", type=str, default=DEFAULT_PARTICIPANT_NAME, help="Ingress 顯示名稱")
    parser.add_argument("--ingress-name", type=str, default=DEFAULT_INGRESS_NAME, help="Ingress 名稱")
    args = parser.parse_args()

    logger.info("開始建立 RTMP Ingress ...")
    try:
        ingress_info = await get_or_create_rtmp_ingress(
            name=args.ingress_name,
            room_name=args.room,
            participant_identity=args.participant_identity,
            participant_name=args.participant_name,
            enable_transcoding=True
        )
    except Exception as e:
        logger.error(f"建立 Ingress 發生錯誤：{e}")
        return

    logger.info(f"Ingress 建立完成: {ingress_info}")

    try:
        stream_key = ingress_info.stream_key
        url_base = ingress_info.url  # 例如 "rtmps://test-wfkuoo8g.rtmp.livekit.cloud/x"
    except AttributeError:
        logger.error("IngressInfo 中缺少預期欄位，請檢查輸出: %s", ingress_info)
        return

    rtmp_url = f"{url_base}/{stream_key}"
    logger.info(f"RTMP 推流 URL: {rtmp_url}")

    run_yolo_ffmpeg_loop(
        rtmp_url=rtmp_url,
        camera_index=args.camera,
        width=args.width,
        height=args.height,
        fps=args.fps,
        model_path=args.model
    )

if __name__ == "__main__":
    asyncio.run(main())
