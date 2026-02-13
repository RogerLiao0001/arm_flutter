import cv2
import time
import threading
import subprocess
from ultralytics import YOLO

# 載入 YOLO 模型
model = YOLO("models/best.pt")

# 開啟攝影機
cap = cv2.VideoCapture(1)
if not cap.isOpened():
    print("無法開啟攝影機")
    exit()

cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
target_fps = 15
print(f"攝影機解析度：{width}x{height}, 目標 FPS: {target_fps}")

# Janus 伺服器 IP & Port
janus_server_ip = "178.128.54.195"  # 你的雲端伺服器 IP
mpegts_port = 6004                  # 單一 UDP port
output_url = f"udp://{janus_server_ip}:{mpegts_port}?pkt_size=1316"

# FFmpeg 命令
ffmpeg_cmd = [
    "ffmpeg",
    "-y",
    "-f", "avfoundation",
    "-i", ":0",  # macOS 音訊設備，若非 :0 請修改
    "-f", "rawvideo",
    "-pix_fmt", "bgr24",
    "-s", f"{width}x{height}",
    "-r", str(target_fps),
    "-i", "-",
    "-map", "0:a",
    "-map", "1:v",
    "-c:v", "libx264",
    "-preset", "ultrafast",
    "-tune", "zerolatency",
    "-pix_fmt", "yuv420p",
    "-g", str(target_fps),
    "-keyint_min", str(target_fps),
    "-b:v", "2000k",
    "-c:a", "aac",
    "-b:a", "128k",
    "-ac", "2",
    "-ar", "48000",
    "-f", "mpegts",
    output_url
]

process = subprocess.Popen(ffmpeg_cmd, stdin=subprocess.PIPE)
print(f"已啟動推流到 Janus: {output_url}")

# 全域變數與鎖
latest_raw_frame = None
latest_processed_frame = None
lock = threading.Lock()

# 捕獲線程
def capture_thread():
    global latest_raw_frame
    while True:
        ret, frame = cap.read()
        if ret:
            frame = cv2.flip(frame, 1)
            with lock:
                latest_raw_frame = frame.copy()
        time.sleep(0.005)

# YOLO 處理線程
def processing_thread():
    global latest_raw_frame, latest_processed_frame
    interval = 0.03
    while True:
        with lock:
            if latest_raw_frame is None:
                continue
            frame_for_infer = latest_raw_frame.copy()
        try:
            results = model(frame_for_infer)
            processed = results[0].plot()
        except Exception as e:
            print("YOLO 處理錯誤:", e)
            processed = frame_for_infer
        with lock:
            latest_processed_frame = processed.copy()
        time.sleep(interval)

t_cap = threading.Thread(target=capture_thread, daemon=True)
t_proc = threading.Thread(target=processing_thread, daemon=True)
t_cap.start()
t_proc.start()

# 主推流迴圈
try:
    while True:
        with lock:
            if latest_processed_frame is None:
                continue
            frame_to_send = latest_processed_frame.copy()

        cv2.imshow("YOLO Processed Frame", frame_to_send)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

        try:
            process.stdin.write(frame_to_send.tobytes())
            process.stdin.flush()
        except BrokenPipeError as e:
            print("FFmpeg 管道錯誤:", e)
            break

        time.sleep(1.0 / target_fps)
except KeyboardInterrupt:
    print("使用者中斷")
finally:
    cap.release()
    process.stdin.close()
    process.wait()
    cv2.destroyAllWindows()
    print("程序已結束")