import cv2
import os
import sys # 用於錯誤時退出

# --- 使用者配置區 ---

# 1. 影像尺寸 (用於您計算 YOLO_ANNOTATION_LINE 的參考，程式本身不再直接使用它來計算)
IMG_WIDTH = 1678 # 範例值，請改成您實際的圖片寬度
IMG_HEIGHT = 1100 # 範例值，請改成您實際的圖片高度

# 2. !!! 固定的 YOLO 標註行 !!!
#    請預先計算好您的固定物件對應的 YOLO 格式字串，並填寫在這裡。
#    格式: <class_index> <x_center_norm> <y_center_norm> <width_norm> <height_norm>
#    數值之間用空格分隔。
#    (下面是根據您範例提供的數據，但 class_index 改為 0，請確認是否正確)
YOLO_ANNOTATION_LINE = "3 0.482122 0.631364 0.346841 0.451818" #<-- 請修改這裡!

# 3. 每秒抽取的幀數
FRAMES_PER_SECOND_TO_EXTRACT = 30 # 您希望每秒抽 5-6 幀

# 4. 輸出圖片格式 ('png' 或 'jpg')
OUTPUT_IMAGE_FORMAT = 'png'

# --- 使用者配置區結束 ---


def main():
    print("--- 開始執行影片抽幀與 YOLO (.txt) 標註生成程式 ---")

    # --- 1. 獲取影片路徑 ---
    while True:
        video_path = input("請輸入影片檔案路徑 (例如: /Users/user/Movies/video.mov 或 video.mp4): ").strip()
        if not video_path:
            print("錯誤：影片路徑不能為空，請重新輸入。")
            continue
        if not os.path.exists(video_path):
            print(f"錯誤：找不到影片檔案 '{video_path}'，請檢查路徑是否正確並重新輸入。")
        else:
            break # 找到檔案，跳出迴圈

    # --- 2. 獲取輸出基礎名稱 ---
    while True:
        output_base_name = input("請輸入輸出檔案的基礎名稱 (例如 'a', 'frame_set_1'): ").strip()
        if not output_base_name:
            print("錯誤：輸出基礎名稱不能為空，請重新輸入。")
        else:
            break

    # --- 3. 決定輸出資料夾名稱 ---
    default_folder_name = output_base_name
    folder_input = input(f"請輸入輸出資料夾的名稱 (直接按 Enter 將使用預設值 '{default_folder_name}'): ").strip()
    output_folder_name = folder_input if folder_input else default_folder_name
    print(f"檔案將儲存至資料夾: '{output_folder_name}'")


    # --- 建立輸出資料夾 ---
    if not os.path.exists(output_folder_name):
        try:
            os.makedirs(output_folder_name)
            print(f"已建立資料夾: '{output_folder_name}'")
        except OSError as e:
            print(f"錯誤：無法建立資料夾 '{output_folder_name}': {e}")
            sys.exit(1) # 嚴重錯誤，退出程式
    else:
        print(f"提示：輸出資料夾 '{output_folder_name}' 已存在，將在其中添加檔案。")

    # --- 開啟影片 ---
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"錯誤：無法開啟影片檔案 '{video_path}'。請檢查檔案是否損毀或格式是否支援。")
        sys.exit(1) # 嚴重錯誤，退出程式

    # --- 獲取影片資訊 ---
    fps = cap.get(cv2.CAP_PROP_FPS)
    # 獲取影片的實際寬高 (雖然不用於計算，但可以顯示給使用者參考)
    actual_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    if fps <= 0:
        print("警告：無法讀取影片的 FPS，將假設為 30 FPS。抽幀可能不準確。")
        fps = 30 # 提供一個預設值

    # 計算抽幀間隔
    frame_interval = int(fps / FRAMES_PER_SECOND_TO_EXTRACT)
    if frame_interval < 1:
        frame_interval = 1 # 確保至少是 1

    print("-" * 30)
    print(f"影片路徑: {video_path}")
    print(f"偵測到的影片尺寸: {actual_width}x{actual_height} (請確保這與您計算 YOLO 標註時使用的尺寸一致)")
    print(f"影片 FPS: {fps:.2f}")
    print(f"設定抽幀率: {FRAMES_PER_SECOND_TO_EXTRACT} 幀/秒")
    print(f"實際抽幀間隔: 每 {frame_interval} 幀抽取 1 幀")
    print(f"輸出檔案基礎名稱: {output_base_name}")
    print(f"輸出資料夾: {output_folder_name}")
    print(f"輸出圖片格式: .{OUTPUT_IMAGE_FORMAT}")
    print(f"將為每張圖片生成的固定標註行: '{YOLO_ANNOTATION_LINE}'")
    print("-" * 30)
    input("確認以上資訊無誤後，請按 Enter 鍵開始處理...") # 給使用者一個確認的機會
    print("開始處理...")

    frame_count = 0
    saved_count = 0

    while True:
        ret, frame = cap.read()

        # 如果讀不到幀 (影片結束或錯誤)
        if not ret:
            break

        # 檢查是否到達抽幀的時間點
        if frame_count % frame_interval == 0:
            saved_count += 1

            # --- 產生檔案名稱 ---
            image_filename = f"{output_base_name}{saved_count}.{OUTPUT_IMAGE_FORMAT}"
            txt_filename = f"{output_base_name}{saved_count}.txt" # TXT 檔名

            # --- 產生完整路徑 ---
            image_save_path = os.path.join(output_folder_name, image_filename)
            txt_save_path = os.path.join(output_folder_name, txt_filename) # TXT 路徑

            # --- 儲存圖片 ---
            try:
                 # 在儲存前檢查 Frame 是否有效
                 if frame is None or frame.size == 0:
                     print(f"\n警告: 在影片幀 {frame_count} 讀取到空畫面，跳過此幀。")
                     continue
                 cv2.imwrite(image_save_path, frame)
            except Exception as e:
                print(f"\n錯誤：無法儲存圖片 '{image_save_path}': {e}")
                print("可能是磁碟空間不足或權限問題，跳過此幀...")
                continue # 跳過這一幀的處理

            # --- 產生並儲存 TXT 標註檔 ---
            try:
                with open(txt_save_path, "w", encoding='utf-8') as f:
                    # 直接寫入預先設定好的固定標註行
                    f.write(YOLO_ANNOTATION_LINE + '\n') # 加上換行符

            except Exception as e:
                 print(f"\n錯誤：無法產生或儲存 TXT 檔案 '{txt_save_path}': {e}")
                 print("將嘗試刪除對應的圖片檔，以保持資料一致性...")
                 if os.path.exists(image_save_path):
                     try:
                         os.remove(image_save_path)
                         print(f"已刪除圖片: {image_save_path}")
                     except OSError as remove_err:
                         print(f"錯誤：無法刪除圖片 '{image_save_path}': {remove_err}")
                 continue # 跳過這一幀的處理


            # 使用 '\r' 和 end='' 實現原地更新進度，避免洗版
            print(f"\r已處理並儲存 {saved_count} 個圖像/TXT 對...", end='')


        frame_count += 1

    # --- 清理 ---
    cap.release()
    print() # 換行，結束原地更新的進度顯示
    print("-" * 30)
    print(f"處理完成！")
    if saved_count > 0:
        print(f"總共從影片 '{os.path.basename(video_path)}' 抽取並儲存了 {saved_count} 張圖片及對應的 YOLO (.txt) 標註檔案。")
        # 顯示絕對路徑方便使用者找到
        abs_output_path = os.path.abspath(output_folder_name)
        print(f"檔案儲存在資料夾: '{abs_output_path}'")
        print(f"重要提示：請確保您在程式碼中填寫的 'YOLO_ANNOTATION_LINE' 對應的圖片尺寸 ({IMG_WIDTH}x{IMG_HEIGHT}) 與影片實際尺寸 ({actual_width}x{actual_height}) 相符，否則標註會不準確！")
    else:
        print("沒有從影片中抽取任何幀。請檢查影片長度、FPS 或抽幀間隔設定。")
    print("-" * 30)


if __name__ == "__main__":
    main()