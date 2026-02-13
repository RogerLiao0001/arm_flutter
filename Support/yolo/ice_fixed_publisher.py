import argparse
import asyncio
import cv2
import json
import logging
import time
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack, RTCConfiguration, RTCIceServer
from av import VideoFrame
import numpy as np
import websockets

logging.basicConfig(level=logging.INFO, format='%(levelname)s:%(name)s:%(message)s')
logger = logging.getLogger('ice-fixed-publisher')

class SimpleVideoStreamTrack(VideoStreamTrack):
    """
    簡單的攝像頭視頻源
    """
    def __init__(self, camera_index, width, height, fps):
        super().__init__()
        self.camera = cv2.VideoCapture(camera_index)
        self.camera.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.camera.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.camera.set(cv2.CAP_PROP_FPS, fps)
        self.fps = fps
        self.frame_interval = 1 / fps
        self.last_frame_time = time.time()

        if not self.camera.isOpened():
            raise ValueError(f"無法打開攝像頭 {camera_index}")

        logger.info(f"攝像頭初始化成功: {int(self.camera.get(cv2.CAP_PROP_FRAME_WIDTH))}x{int(self.camera.get(cv2.CAP_PROP_FRAME_HEIGHT))}")
        
        self.counter = 0

    async def recv(self):
        now = time.time()
        wait_time = max(0, self.frame_interval - (now - self.last_frame_time))
        if wait_time > 0:
            await asyncio.sleep(wait_time)

        ret, frame = self.camera.read()
        if not ret:
            logger.warning("攝像頭讀取失敗")
            frame = np.zeros((480, 640, 3), dtype=np.uint8)

        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        cv2.putText(frame, timestamp, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        video_frame = VideoFrame.from_ndarray(frame_rgb, format="rgb24")
        video_frame.pts = self.counter
        video_frame.time_base = "1/" + str(self.fps)
        self.counter += 1
        self.last_frame_time = time.time()
        return video_frame

    def stop(self):
        if self.camera.isOpened():
            self.camera.release()
            logger.info("攝像頭已釋放")

def fix_sdp(sdp, is_offer=True):
    lines = sdp.split("\r\n")
    fixed_lines = []
    for line in lines:
        if line.startswith("a=setup:"):
            if is_offer:
                fixed_lines.append("a=setup:actpass")
            else:
                fixed_lines.append("a=setup:passive")
        else:
            fixed_lines.append(line)
    return "\r\n".join(fixed_lines)

async def run_publisher(args):
    try:
        video_track = SimpleVideoStreamTrack(
            camera_index=args.camera,
            width=args.width,
            height=args.height,
            fps=args.fps
        )
    except Exception as e:
        logger.error(f"初始化視頻流失敗: {e}")
        return

    configuration = RTCConfiguration(iceServers=[
        RTCIceServer(urls=["stun:stun.l.google.com:19302"]),
        RTCIceServer(
            urls=["turn:178.128.54.195:3478"],
            username="webrtc",
            credential="turnpassword"
        )
    ])

    pc = RTCPeerConnection(configuration=configuration)

    pc.addTrack(video_track)

    @pc.on("iceconnectionstatechange")
    async def on_iceconnectionstatechange():
        logger.info(f"ICE連接狀態: {pc.iceConnectionState}")
        if pc.iceConnectionState == "connected":
            logger.info("🔥 ICE 連接成功!")
        elif pc.iceConnectionState in ["failed", "disconnected", "closed"]:
            logger.warning("ICE 連接可能出現問題，狀態: " + pc.iceConnectionState)

    try:
        logger.info(f"連接到 SFU: {args.sfu}")
        async with websockets.connect(args.sfu) as ws:
            offer = await pc.createOffer()
            fixed_sdp_offer = fix_sdp(offer.sdp, is_offer=True)
            offer.sdp = fixed_sdp_offer
            await pc.setLocalDescription(offer)
            logger.info("已設置本地描述")

            join_message = {
                "method": "join",
                "params": {
                    "sid": args.stream_id,
                    "offer": {
                        "type": pc.localDescription.type,
                        "sdp": pc.localDescription.sdp
                    }
                },
                "id": "ice-fixed-" + str(int(time.time()))
            }

            await ws.send(json.dumps(join_message))
            logger.info(f"已發送加入請求，流ID: {args.stream_id}")

            response = await ws.recv()
            try:
                data = json.loads(response)
                if "result" in data and "answer" in data["result"]:
                    answer = data["result"]["answer"]
                    fixed_answer_sdp = fix_sdp(answer["sdp"], is_offer=False)
                    await pc.setRemoteDescription(
                        RTCSessionDescription(type="answer", sdp=fixed_answer_sdp)
                    )
                    logger.info("✅ 連接已建立")
                    while True:
                        await asyncio.sleep(1)
                else:
                    logger.error(f"未收到預期的回應: {data}")
            except Exception as e:
                logger.error(f"處理回應時出錯: {e}")

    except Exception as e:
        logger.error(f"連接錯誤: {e}")
    finally:
        await pc.close()
        video_track.stop()
        logger.info("已關閉連接")

def main():
    parser = argparse.ArgumentParser(description='ICE修正版 WebRTC 推流器')
    parser.add_argument('--sfu', type=str, default="ws://localhost:7000", help='SFU WebSocket URL')
    parser.add_argument('--camera', type=int, default=0, help='攝像頭索引')
    parser.add_argument('--width', type=int, default=640, help='視頻寬度')
    parser.add_argument('--height', type=int, default=480, help='視頻高度')
    parser.add_argument('--fps', type=int, default=15, help='幀率')
    parser.add_argument('--stream-id', type=str, default="yolo-main-stream", help='流 ID')
    parser.add_argument('--log', type=str, default="INFO", help='日誌級別 (DEBUG, INFO, WARNING, ERROR)')

    args = parser.parse_args()

    numeric_level = getattr(logging, args.log.upper(), None)
    if not isinstance(numeric_level, int):
        raise ValueError(f'無效的日誌級別: {args.log}')
    logger.setLevel(numeric_level)

    logger.info("⚡ ICE 修正版推流器啟動")
    asyncio.run(run_publisher(args))

if __name__ == "__main__":
    main()