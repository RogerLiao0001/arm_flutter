import cv2
import time
import threading
import subprocess
from ultralytics import YOLO

# --------------------
# 1. 載入 YOLO 模型
# --------------------
model = YOLO("models/best.pt")

# --------------------
# 2. 開啟攝影機
# --------------------
cap = cv2.VideoCapture(0)
if not cap.isOpened():
    print("無法開啟攝影機")
    exit()

width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
fps = cap.get(cv2.CAP_PROP_FPS)
if fps <= 0:
    fps = 30

print(f"攝影機解析度：{width}x{height}, FPS: {fps}")

# --------------------
# 3. 設定 RTMP 推流參數 (低延遲優化)
# --------------------
rtmp_url = "rtmp://178.128.54.195/live/stream"

# 建議嘗試更低解析度 (640x360 or 960x540) & 更低碼率 以減少卡頓
# 可嘗試修改 -s, -maxrate, -bufsize, -g (GOP), -preset ultrafast ...
# 這裡示範關閉 B-frame, GOP=15, maxrate=1500k, bufsize=800k
ffmpeg_cmd = [
    "ffmpeg",
    "-y",
    "-f", "rawvideo",
    "-vcodec", "rawvideo",
    "-pix_fmt", "bgr24",
    "-s", f"{width}x{height}",
    "-r", str(fps),
    "-i", "-",
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-tune", "zerolatency",
    "-g", "15",               # 每 15 幀一個 I-frame
    "-bf", "0",               # 關閉 B-frames
    "-maxrate", "1500k",      # 最大碼率 (自行調整)
    "-bufsize", "800k",       # buffer 大小 (越小越即時)
    "-f", "flv",
    rtmp_url
]

process = subprocess.Popen(ffmpeg_cmd, stdin=subprocess.PIPE)
print("開始推流到 RTMP 伺服器...")

# --------------------
# 4. 全局變數與鎖
# --------------------
latest_raw_frame = None
latest_processed_frame = None
lock = threading.Lock()

# --------------------
# 5. 捕獲線程
# --------------------
def capture_thread():
    global latest_raw_frame
    while True:
        ret, frame = cap.read()
        if ret:
            with lock:
                latest_raw_frame = frame.copy()
        # 保持較高頻讀取
        time.sleep(0.005)

# --------------------
# 6. YOLO 推論線程
# --------------------
def processing_thread():
    global latest_raw_frame, latest_processed_frame
    # 一次 YOLO 推論時間若很快，可提升頻率；若CPU較大負載，可放慢一點
    # 例如 0.05 (約20FPS) or 0.1 (10FPS)
    yolo_interval = 0.06

    while True:
        frame_for_infer = None
        with lock:
            if latest_raw_frame is not None:
                frame_for_infer = latest_raw_frame.copy()

        if frame_for_infer is not None:
            try:
                results = model(frame_for_infer)
                processed = results[0].plot()
            except Exception as e:
                print("推論錯誤:", e)
                processed = frame_for_infer
            with lock:
                latest_processed_frame = processed.copy()

        time.sleep(yolo_interval)

# --------------------
# 7. 啟動線程
# --------------------
t_cap = threading.Thread(target=capture_thread, daemon=True)
t_proc = threading.Thread(target=processing_thread, daemon=True)
t_cap.start()
t_proc.start()

# --------------------
# 8. 主推流迴圈
# --------------------
try:
    while True:
        with lock:
            if latest_processed_frame is None:
                continue
            frame_to_send = latest_processed_frame.copy()

        # 本地顯示
        cv2.imshow("Processed Frame", frame_to_send)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

        # 將影像送進 FFmpeg
        try:
            process.stdin.write(frame_to_send.tobytes())
        except BrokenPipeError as e:
            print("FFmpeg 輸出錯誤:", e)
            break

        # 推流帧率與攝影機 fps 同步
        time.sleep(1.0 / fps)

except KeyboardInterrupt:
    pass

# --------------------
# 9. 收尾
# --------------------
cap.release()
process.stdin.close()
process.wait()
cv2.destroyAllWindows()
