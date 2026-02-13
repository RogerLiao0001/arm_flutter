import cv2

def find_camera_index():
    for index in range(10):  # 測試 0 到 9 的攝影機索引
        cap = cv2.VideoCapture(index)
        if cap.isOpened():
            print(f"攝影機索引 {index} 可用")
            cap.release()
        else:
            print(f"攝影機索引 {index} 無法使用")

find_camera_index()