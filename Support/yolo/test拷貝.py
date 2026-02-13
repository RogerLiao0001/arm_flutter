import cv2
from ultralytics import YOLO
import sys

# --- 1. 設定 ---
MODEL_NAME = 'models/11-1.pt'  # 在這裡設定您要使用的 YOLO 模型檔案名稱
                          # 例如 'yolov8n.pt', 'yolov8s.pt', 或您自己訓練的模型路徑 'models/best.pt'
                          # 如果使用標準模型 (如 yolov8n.pt) 且本地沒有，Ultralytics 會嘗試自動下載
CONFIDENCE_THRESHOLD = 0.7 # 在這裡設定顯示結果所需的最低信心度 (0.0 到 1.0 之間)
CAMERA_INDEX = 0           # Mac 內建攝影機通常是 0，若有多個攝影機可嘗試 1, 2...

# --- 2. 載入 YOLO 模型 ---
try:
    print(f"正在載入模型: {MODEL_NAME}...")
    model = YOLO(MODEL_NAME)
    print("模型載入成功！")
except Exception as e:
    print(f"錯誤：無法載入模型 '{MODEL_NAME}'. 請確認檔案路徑是否正確，或者模型名稱是否有效。")
    print(f"詳細錯誤: {e}")
    sys.exit(1) # 載入失敗則退出程式

# --- 3. 開啟攝影機 ---
print(f"正在嘗試開啟攝影機索引: {CAMERA_INDEX}...")
cap = cv2.VideoCapture(CAMERA_INDEX)

# 檢查攝影機是否成功開啟
if not cap.isOpened():
    print(f"錯誤：無法開啟攝影機索引 {CAMERA_INDEX}。")
    print("請檢查：")
    print("1. 攝影機是否被其他應用程式佔用？")
    print("2. 攝影機是否正確連接並被系統辨識？")
    print("3. 您是否有給予終端機或執行環境取用攝影機的權限？(在 macOS 的 '系統設定' -> '隱私權與安全性' -> '攝影機' 中檢查)")
    sys.exit(1) # 開啟失敗則退出程式

# (可選) 取得攝影機的基本資訊
width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
fps = cap.get(cv2.CAP_PROP_FPS)
# 有些攝影機可能回報 0 fps，給個預設值
if fps <= 0:
    fps = 30
print(f"攝影機成功開啟！ 解析度: {width}x{height}, FPS: {fps:.2f} (回報值)")
print("按下 'q' 鍵結束程式。")

# --- 4. 主迴圈：讀取影像、執行推論、顯示結果 ---
while True: # 使用 True 配合後續的 break 更簡潔
    # 從攝影機讀取一幀影像
    success, frame = cap.read()

    # 如果讀取失敗 (例如攝影機被拔除或出錯)
    if not success:
        print("錯誤：無法從攝影機讀取影像。")
        break # 跳出迴圈

    # 使用 YOLO 模型進行物件偵測
    # 將 frame 交給模型，並設定信心度閾值
    # stream=False (預設) 適用於單張圖片或獨立影格
    results = model(frame, conf=CONFIDENCE_THRESHOLD, verbose=False) # verbose=False 避免在終端印出過多 log

    # `results` 是一個包含偵測結果的列表 (通常只有一個元素對應單張圖片)
    # `results[0].plot()` 會將偵測框、標籤和信心度繪製在原始 frame 的複本上
    annotated_frame = results[0].plot()

    # 建立一個視窗並顯示疊加結果後的影像
    cv2.imshow("YOLOv8 Live Detection (Press 'q' to quit)", annotated_frame)

    # 等待按鍵事件 (等待 1 毫秒)
    # `& 0xFF` 是為了確保跨平台的相容性
    if cv2.waitKey(1) & 0xFF == ord('q'):
        print("收到結束指令 'q'，正在關閉程式...")
        break # 按下 'q' 鍵則跳出迴圈

# --- 5. 釋放資源 ---
print("釋放攝影機資源...")
cap.release() # 釋放攝影機物件
print("關閉所有 OpenCV 視窗...")
cv2.destroyAllWindows() # 關閉所有由 OpenCV 建立的視窗
print("程式已結束。")