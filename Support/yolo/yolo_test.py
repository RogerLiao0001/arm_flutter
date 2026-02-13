import cv2
from ultralytics import YOLO
import time
import sys
import torch # 用於檢查 MPS

# --- 1. 設定 ---
MODEL_NAME = '11n-3.pt' 
                          # 可換成 'yolov8s.pt' 但會更慢, 或您自己的模型 'models/best.pt'
CONFIDENCE_THRESHOLD = 0.2 # 顯示結果所需的最低信心度
CAMERA_INDEX = 0          # Mac 內建攝影機索引

# --- 檢查是否有可用的 GPU (Metal Performance Shaders on Mac) ---
if torch.backends.mps.is_available():
    device = 'mps'
    print("偵測到 MPS (Apple Silicon GPU)，將使用 GPU 加速。")
elif torch.cuda.is_available():
    device = 'cuda'
    print("偵測到 CUDA (NVIDIA GPU)，將使用 GPU 加速。")
else:
    device = 'cpu'
    print("未偵測到相容的 GPU，將使用 CPU 進行推論 (速度可能較慢)。")

# --- 2. 載入 YOLO 模型 ---
print(f"正在載入模型: {MODEL_NAME}...")
try:
    model = YOLO(MODEL_NAME)
    # 注意：在推論時指定 device 比載入時移動模型更常用且推薦
    # model.to(device) # 通常在 model() 呼叫中指定 device
    print("模型載入成功！")
except Exception as e:
    print(f"錯誤：無法載入模型 '{MODEL_NAME}'. 請確認檔案路徑或名稱。")
    print(f"詳細錯誤: {e}")
    sys.exit(1)

# --- 3. 開啟攝影機 ---
print(f"正在嘗試開啟攝影機索引: {CAMERA_INDEX}...")
cap = cv2.VideoCapture(CAMERA_INDEX)

if not cap.isOpened():
    print(f"錯誤：無法開啟攝影機索引 {CAMERA_INDEX}。請檢查權限或攝影機是否被佔用。")
    sys.exit(1)

# --- 重要：不主動設定解析度，使用攝影機預設值 ---
# cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280) # 不設定，保留原始解析度
# cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720) # 不設定，保留原始解析度

width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
fps_cam = cap.get(cv2.CAP_PROP_FPS)
# 有些攝影機可能回報 0 fps 或不穩定，這裡只是讀取供參考
if fps_cam <= 0: fps_cam = 30 # 給個預設參考值
print(f"攝影機成功開啟！ 原始解析度: {width}x{height}, 攝影機回報 FPS: {fps_cam:.2f} (僅供參考)")
print(f"推論將在設備 '{device}' 上運行。")
print("程式將處理每一幀，實際顯示幀率取決於推論速度。按 'q' 鍵結束。")

# --- 4. 主迴圈：讀取 -> 推論 -> 顯示 (順序執行) ---
frame_count = 0
start_time = time.time()
processing_time = 0
display_fps = 0

while True:
    # 讀取一幀
    success, frame = cap.read()
    if not success:
        print("錯誤：無法從攝影機讀取影像，或影像流結束。")
        break

    # 記錄開始推論時間
    inference_start_time = time.time()

    # *** 執行 YOLO 推論 (關鍵耗時步驟) ***
    # 將 frame 交給模型，設定信心度，並指定運行設備
    # verbose=False 避免在終端印出大量 YOLO log
    results = model(frame, conf=CONFIDENCE_THRESHOLD, device=device, verbose=False, imgsz=800,)

    # 記錄結束推論時間
    inference_end_time = time.time()
    processing_time = inference_end_time - inference_start_time

    # 繪製結果 (YOLOv8 results物件自帶繪圖功能)
    # results[0] 代表對第一張 (也是唯一一張) 圖片的結果
    annotated_frame = results[0].plot()

    # 計算並顯示實際的處理+顯示 FPS
    frame_count += 1
    elapsed_time = time.time() - start_time
    if elapsed_time >= 1.0:
        display_fps = 2 * frame_count / elapsed_time
        frame_count = 0
        start_time = time.time()

    # 在畫面上顯示 FPS 和單幀處理時間
    fps_text = f"Actual FPS: {display_fps:.2f}"
    proc_text = f"Proc. Time: {processing_time*1000:.1f} ms" # 轉換為毫秒
    cv2.putText(annotated_frame, fps_text, (20, 40),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
    cv2.putText(annotated_frame, proc_text, (20, 60),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)


    # *** 顯示疊加結果後的影像 ***
    # 這裡的顯示速度取決於上面推論完成的速度
    cv2.imshow("YOLOv8 Live Detection (Processing Every Frame)", annotated_frame)

    # 按下 q 鍵離開 (等待 1ms 讓視窗刷新)
    if cv2.waitKey(1) & 0xFF == ord('q'):
        print("收到結束指令 'q'，正在關閉程式...")
        break

# --- 5. 釋放資源 ---
print("釋放攝影機資源...")
cap.release()
print("關閉所有 OpenCV 視窗...")
cv2.destroyAllWindows()
print("程式已結束。")