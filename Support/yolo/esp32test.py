import cv2

# 請將 URL 替換成 ESP32-CAM 的實際 IP
url = "http://172.30.71.19/stream"
cap = cv2.VideoCapture(url)

if not cap.isOpened():
    print("無法開啟 ESP32-CAM 串流")
    exit()

while True:
    ret, frame = cap.read()
    if not ret:
        print("讀取串流失敗")
        break
    frame = cv2.flip(frame, 1)
    cv2.imshow("ESP32-CAM Stream", frame)
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

cap.release()
cv2.destroyAllWindows()
