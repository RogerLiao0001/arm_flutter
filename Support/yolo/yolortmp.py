import cv2
import time
import threading
import subprocess
import torch
from ultralytics import YOLO

# (A) 選擇裝置 (GPU/CPU)
device = "mps" if torch.backends.mps.is_available() else "cpu"
# device = "cuda"  # 若你是 NVIDIA GPU + 正確安裝 PyTorch CUDA
# device = "cpu"   # 若無 GPU

# (B) 載入 YOLO 模型
model = YOLO("models/best.pt").to(device)
names = model.names  # 模型的類別名稱表 (list 或 dict)

# (C) 開啟攝影機
cap = cv2.VideoCapture(0)
if not cap.isOpened():
    print("無法開啟攝影機")
    exit()

width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
fps_cam = cap.get(cv2.CAP_PROP_FPS)
if fps_cam <= 0:
    fps_cam = 30

print(f"攝影機解析度：{width}x{height}, 攝影機FPS: {fps_cam}")

# (D) 設定推流幀率 (直播幀率)
#    如果希望順暢就設定 15~30 之間；越高負載越大，延遲也可能略增
stream_fps = 5

# (E) FFmpeg 低延遲參數：ultrafast、zerolatency、baseline、yuv420p、bf=0、g=15 ...
rtmp_url = "rtmp://178.128.54.195/live/stream"
ffmpeg_cmd = [
    "ffmpeg",
    "-y",
    "-f", "rawvideo",
    "-vcodec", "rawvideo",
    "-pix_fmt", "bgr24",
    "-s", f"{width}x{height}",
    "-r", str(stream_fps),  # 以 stream_fps 推送
    "-i", "-",
    "-c:v", "libx264",
    "-preset", "ultrafast",
    "-tune", "zerolatency",
    "-profile:v", "baseline",    # baseline 更常用於低延遲
    "-pix_fmt", "yuv420p",       # baseline profile 通常只支援 yuv420p
    "-bf", "0",                  # 關掉 B-frames
    "-g", "10",                  # 每 15 幀一個 I-frame (對應 ~1秒, 如果 stream_fps=15)
    "-f", "flv",
    rtmp_url
]

# 啟動 FFmpeg 子進程
process = subprocess.Popen(ffmpeg_cmd, stdin=subprocess.PIPE)
print("[INFO] FFmpeg 推流中 (超低延遲設定)...")

# (F) 全局共享變數
lock = threading.Lock()
latest_raw_frame = None          # 最新攝影機畫面
latest_detections = None         # 最新 YOLO 偵測資料 (boxes, confs, clses)
stop_flag = False

# (G) 攝影機捕獲線程（高速）
def capture_thread():
    global latest_raw_frame, stop_flag
    while not stop_flag:
        ret, frame = cap.read()
        if ret:
            with lock:
                latest_raw_frame = frame
        time.sleep(0.001)  # 小休息避免CPU100%，可視情況調整

# (H) YOLO 推論線程（低頻 2~3 FPS 即可）
def yolo_inference_thread():
    global latest_detections, stop_flag
    target_fps = 1
    interval = 1.0 / target_fps

    while not stop_flag:
        start_time = time.time()
        frame_for_infer = None

        with lock:
            if latest_raw_frame is not None:
                # 複製最新畫面給 YOLO 推論
                frame_for_infer = latest_raw_frame.copy()

        if frame_for_infer is not None:
            try:
                # 推論
                results = model(frame_for_infer, device=device)
                # 只取第一張結果
                boxes = results[0].boxes.xyxy.cpu().numpy()
                confs = results[0].boxes.conf.cpu().numpy()
                clses = results[0].boxes.cls.cpu().numpy()
                with lock:
                    latest_detections = (boxes, confs, clses)
            except Exception as e:
                print("[ERROR] 推論錯誤:", e)

        used_time = time.time() - start_time
        if used_time < interval:
            time.sleep(interval - used_time)

# (I) 啟動兩條後台線程
t_cap = threading.Thread(target=capture_thread, daemon=True)
t_yolo = threading.Thread(target=yolo_inference_thread, daemon=True)
t_cap.start()
t_yolo.start()

print("[INFO] 開始主推流迴圈... (按 'q' 離開)")

# (J) 主迴圈：以 stream_fps (15FPS) 發送影像給 FFmpeg
try:
    while True:
        start_loop = time.time()

        frame_to_send = None
        boxes = None
        confs = None
        clses = None

        # 取最新畫面 + 最新推論結果
        with lock:
            if latest_raw_frame is not None:
                frame_to_send = latest_raw_frame.copy()
            if latest_detections is not None:
                boxes, confs, clses = latest_detections

        if frame_to_send is None:
            time.sleep(0.01)
            continue

        # 將 YOLO 偵測框疊到畫面
        if boxes is not None:
            for (x1, y1, x2, y2), cf, clsid in zip(boxes, confs, clses):
                if cf > 0.5:  # 信心閾值可自行調整
                    clsid_int = int(clsid)
                    if 0 <= clsid_int < len(names):
                        label = names[clsid_int]
                    else:
                        label = str(clsid_int)

                    cv2.rectangle(frame_to_send, (int(x1), int(y1)), (int(x2), int(y2)),
                                  (0, 255, 0), 2)
                    cv2.putText(frame_to_send, f"{label}:{cf:.2f}",
                                (int(x1), int(y1)-5),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)

        # 本地顯示 (除錯用)
        cv2.imshow("YOLO Stream", frame_to_send)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

        # 推送到 FFmpeg
        try:
            process.stdin.write(frame_to_send.tobytes())
        except BrokenPipeError:
            print("[ERROR] FFmpeg 輸出管道已關閉，結束推流")
            break

        # 控制推流幀率為 stream_fps
        used = time.time() - start_loop
        delay = (1.0 / stream_fps) - used
        if delay > 0:
            time.sleep(delay)

except KeyboardInterrupt:
    pass

# (K) 收尾
stop_flag = True
t_cap.join()
t_yolo.join()
cap.release()
process.stdin.close()
process.wait()
cv2.destroyAllWindows()
