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
    """Query if an ingress for the specified room & identity already exists."""
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
                logger.info("Reusing existing Ingress: %s", item.ingress_id)
                await lkapi.aclose()
                return item
    except Exception as e:
        logger.error("Error listing ingress: %s", e)
    await lkapi.aclose()
    return None

async def get_or_create_rtmp_ingress(name: str, room_name: str,
                                     participant_identity: str, participant_name: str,
                                     enable_transcoding: bool = True) -> dict:
    """
    Attempt to create a new RTMP Ingress; if resource limits are exceeded, try to reuse an existing ingress.
    """
    livekit_url = os.getenv("LIVEKIT_URL")
    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")
    if not (livekit_url and api_key and api_secret):
        raise ValueError("Please set LIVEKIT_URL, LIVEKIT_API_KEY, and LIVEKIT_API_SECRET")
    
    lkapi = api.LiveKitAPI(livekit_url, api_key, api_secret)
    ingress_client = lkapi.ingress

    create_req = CreateIngressRequest(
        input_type=0,  # RTMP input
        name=name,
        room_name=room_name,
        participant_identity=participant_identity,
        participant_name=participant_name,
        enable_transcoding=True,  # Force transcoding for high-quality stream
        video={"name": "camera", "source": "CAMERA"},
        audio={"name": "microphone", "source": "MICROPHONE"}
    )
    try:
        ingress_info = await ingress_client.create_ingress(create_req)
        logger.info(f"Ingress created: {ingress_info}")
    except TwirpError as te:
        if te.args[0] == "resource_exhausted":
            logger.error("Resource exhausted when creating ingress: %s", te)
            logger.info("Trying to reuse an existing ingress ...")
            ingress_info = await get_existing_ingress(room_name, participant_identity)
            if not ingress_info:
                logger.error("No reusable ingress available. Please delete existing ingress first.")
                await lkapi.aclose()
                raise te
        else:
            await lkapi.aclose()
            raise te
    await lkapi.aclose()
    return ingress_info

def run_yolo_ffmpeg_loop(rtmp_url: str, camera_index: int, width: int, height: int, fps: int, model_path: str):
    """
    Process camera frames with YOLO and stream them via FFmpeg over RTMP.
    Every frame is resized to the desired resolution (e.g. 1920x1080) for high-quality output.
    """
    logger.info(f"Starting RTMP stream to: {rtmp_url}")
    model = YOLO(model_path)
    logger.info(f"YOLO model loaded: {model_path}")

    cap = cv2.VideoCapture(camera_index)
    # Force the camera frame to the desired resolution (even if it means upscaling)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, fps)

    if not cap.isOpened():
        logger.error(f"Failed to open camera index={camera_index}")
        return

    # Use desired resolution for FFmpeg output
    logger.info(f"Camera set to: {width}x{height}, target FPS: {fps}")

    ffmpeg_cmd = [
        "ffmpeg",
        "-y",
        "-f", "rawvideo",
        "-pix_fmt", "bgr24",
        "-s", f"{width}x{height}",
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
    logger.info("FFmpeg command: " + " ".join(ffmpeg_cmd))

    process = subprocess.Popen(ffmpeg_cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    lock = threading.Lock()
    latest_frame = None
    stop_flag = False
    display_enabled = True  # Enable local display by default

    def yolo_thread():
        nonlocal latest_frame, stop_flag, display_enabled
        while not stop_flag:
            ret, frame = cap.read()
            if not ret:
                logger.warning("Failed to read from camera")
                time.sleep(0.01)
                continue

            # Flip the frame horizontally
            frame = cv2.flip(frame, 1)
            # Resize to desired resolution (e.g. 1920x1080)
            frame_resized = cv2.resize(frame, (width, height))
            try:
                # YOLO inference using the resized frame with imgsz set to the desired resolution.
                result = model(frame_resized, imgsz=(width, height))
                annotated = result[0].plot()  # Annotated frame (BGR)
                annotated = np.clip(annotated, 0, 255).astype(np.uint8)
                # Do NOT resize back; keep the inference resolution.
            except Exception as e:
                logger.error(f"YOLO processing error: {e}")
                annotated = frame_resized

            if display_enabled:
                try:
                    cv2.imshow("YOLO Processed", annotated)
                    if cv2.waitKey(1) & 0xFF == ord('q'):
                        stop_flag = True
                        break
                except cv2.error as e:
                    logger.error(f"cv2.imshow/waitKey error: {e}")
                    display_enabled = False

            with lock:
                latest_frame = annotated.copy()
        logger.info("YOLO thread finished")

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
                logger.error("FFmpeg pipe broken, stopping stream")
                break
            time.sleep(1.0 / fps)
    except KeyboardInterrupt:
        logger.info("User interrupted")
    finally:
        stop_flag = True
        t.join()
        cap.release()
        cv2.destroyAllWindows()
        if process.stdin:
            process.stdin.close()
        process.wait()
        logger.info("Process finished, FFmpeg closed")

async def main():
    parser = argparse.ArgumentParser(description="RTMP streaming to LiveKit Ingress (YOLO + FFmpeg)")
    parser.add_argument("--camera", type=int, default=0, help="Camera index")
    parser.add_argument("--width", type=int, default=1920, help="Desired streaming width (e.g. 1920 for 1080p)")
    parser.add_argument("--height", type=int, default=1080, help="Desired streaming height (e.g. 1080 for 1080p)")
    parser.add_argument("--fps", type=int, default=15, help="Target FPS")
    parser.add_argument("--model", type=str, default="models/best.pt", help="YOLO model path")
    parser.add_argument("--room", type=str, default=DEFAULT_ROOM, help="LiveKit room name")
    parser.add_argument("--participant-identity", type=str, default=DEFAULT_PARTICIPANT_IDENTITY, help="Ingress connection identity")
    parser.add_argument("--participant-name", type=str, default=DEFAULT_PARTICIPANT_NAME, help="Ingress display name")
    parser.add_argument("--ingress-name", type=str, default=DEFAULT_INGRESS_NAME, help="Ingress name")
    args = parser.parse_args()

    logger.info("Starting to create RTMP Ingress ...")
    try:
        ingress_info = await get_or_create_rtmp_ingress(
            name=args.ingress_name,
            room_name=args.room,
            participant_identity=args.participant_identity,
            participant_name=args.participant_name,
            enable_transcoding=True
        )
    except Exception as e:
        logger.error(f"Error creating ingress: {e}")
        return

    logger.info(f"Ingress created: {ingress_info}")

    try:
        stream_key = ingress_info.stream_key
        url_base = ingress_info.url  # e.g. "rtmps://test-wfkuoo8g.rtmp.livekit.cloud/x"
    except AttributeError:
        logger.error("IngressInfo missing expected fields: %s", ingress_info)
        return

    rtmp_url = f"{url_base}/{stream_key}"
    logger.info(f"RTMP streaming URL: {rtmp_url}")

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
