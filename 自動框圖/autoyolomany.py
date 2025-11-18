import cv2
import os
import sys
import glob # 用於查找檔案

# --- 使用者配置區 ---

# 1. 每秒抽取的幀數
FRAMES_PER_SECOND_TO_EXTRACT = 30 # <-- 修改這裡以設定抽幀率

# 2. 輸出圖片格式 ('png' 或 'jpg')
OUTPUT_IMAGE_FORMAT = 'png'

# --- 使用者配置區結束 ---

def read_annotation_line(txt_path):
    """從指定的 txt 檔案讀取第一行標註。"""
    try:
        with open(txt_path, 'r', encoding='utf-8') as f:
            line = f.readline().strip() # 讀取第一行並移除頭尾空白
            if line:
                # 基本驗證：確保至少有幾個空格分隔的數值
                parts = line.split()
                if len(parts) >= 5: # YOLO 格式至少有 5 個部分
                    try:
                        # 嘗試將數值部分轉換為浮點數，確保格式基本正確
                        [float(p) for p in parts[1:]]
                        int(parts[0]) # 檢查 class index 是否為整數
                        return line
                    except ValueError:
                        print(f"警告：標註檔 '{os.path.basename(txt_path)}' 的第一行格式似乎不正確 (無法轉換為數值): '{line}'")
                        return None
                else:
                    print(f"警告：標註檔 '{os.path.basename(txt_path)}' 的第一行似乎不是有效的 YOLO 格式 (部分不足): '{line}'")
                    return None
            else:
                print(f"警告：標註檔 '{os.path.basename(txt_path)}' 為空或第一行為空。")
                return None
    except FileNotFoundError:
        # 這個情況會在 main 函數中處理，這裡返回 None 即可
        return None
    except Exception as e:
        print(f"錯誤：讀取標註檔 '{os.path.basename(txt_path)}' 時發生錯誤: {e}")
        return None

def process_video(video_path, annotation_line, video_output_subdir):
    """處理單一影片：抽幀並將結果存入指定的子目錄。"""
    video_base_name = os.path.splitext(os.path.basename(video_path))[0]
    print(f"\n--- 開始處理影片: {os.path.basename(video_path)} -> 輸出至 '{os.path.basename(video_output_subdir)}' ---")
    print(f"使用標註: '{annotation_line}'")

    # --- 建立該影片專屬的輸出子目錄 ---
    try:
        # exist_ok=True 避免目錄已存在時報錯
        os.makedirs(video_output_subdir, exist_ok=True)
    except OSError as e:
        print(f"錯誤：無法為影片 '{video_base_name}' 建立輸出子目錄 '{video_output_subdir}': {e}")
        print("跳過此影片。")
        return 0 # 返回處理的幀數 0


    # --- 開啟影片 ---
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"錯誤：無法開啟影片檔案 '{video_path}'。跳過此影片。")
        return 0

    # --- 獲取影片資訊 ---
    fps = cap.get(cv2.CAP_PROP_FPS)
    actual_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    if fps <= 0:
        print("警告：無法讀取影片的 FPS，將假設為 30 FPS。抽幀可能不準確。")
        fps = 30

    frame_interval = int(fps / FRAMES_PER_SECOND_TO_EXTRACT)
    if frame_interval < 1:
        frame_interval = 1

    print(f"偵測尺寸: {actual_width}x{actual_height}, FPS: {fps:.2f}, 抽幀間隔: {frame_interval}")

    frame_count = 0
    saved_count = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if frame_count % frame_interval == 0:
            saved_count += 1

            # --- 產生檔案名稱 (在子目錄內，可以只用編號) ---
            # 也可以保留 video_base_name 前綴，例如 f"{video_base_name}_{saved_count}.ext"
            image_filename = f"{saved_count}.{OUTPUT_IMAGE_FORMAT}"
            txt_filename = f"{saved_count}.txt"

            # --- 產生完整路徑 (儲存在 video_output_subdir 中) ---
            image_save_path = os.path.join(video_output_subdir, image_filename)
            txt_save_path = os.path.join(video_output_subdir, txt_filename)

            # --- 儲存圖片 ---
            try:
                if frame is None or frame.size == 0:
                    print(f"\n警告: 在影片 {video_base_name} 幀 {frame_count} 讀取到空畫面，跳過此幀。")
                    continue
                cv2.imwrite(image_save_path, frame)
            except Exception as e:
                print(f"\n錯誤：無法儲存圖片 '{image_save_path}': {e}")
                print("跳過此幀...")
                continue

            # --- 產生並儲存 TXT 標註檔 ---
            try:
                with open(txt_save_path, "w", encoding='utf-8') as f:
                    f.write(annotation_line + '\n')
            except Exception as e:
                 print(f"\n錯誤：無法產生或儲存 TXT 檔案 '{txt_save_path}': {e}")
                 print("將嘗試刪除對應的圖片檔...")
                 if os.path.exists(image_save_path):
                     try:
                         os.remove(image_save_path)
                         print(f"已刪除圖片: {image_save_path}")
                     except OSError as remove_err:
                         print(f"錯誤：無法刪除圖片 '{image_save_path}': {remove_err}")
                 continue

            print(f"\r已處理 {os.path.basename(video_path)}: {saved_count} 幀...", end='')

        frame_count += 1

    cap.release()
    print()
    print(f"--- 完成處理影片: {os.path.basename(video_path)}, 共儲存 {saved_count} 個圖像/TXT 對於 '{os.path.basename(video_output_subdir)}' ---")
    return saved_count

def main():
    print("--- 開始執行批量影片抽幀與 YOLO (.txt) 標註生成程式 (分資料夾儲存) ---")

    # --- 獲取輸入目錄 ---
    while True:
        input_dir = input("請輸入包含影片和對應 .txt 標註檔的目錄路徑: ").strip()
        if not input_dir:
            print("錯誤：輸入目錄不能為空。")
            continue
        if not os.path.isdir(input_dir):
            print(f"錯誤：找不到目錄 '{input_dir}' 或它不是一個有效的目錄。")
        else:
            input_dir = os.path.abspath(input_dir) # 轉換為絕對路徑
            break

    # --- 獲取主輸出目錄 (可以指向隨身碟) ---
    while True:
        main_output_dir = input("請輸入主輸出目錄路徑 (所有影片子資料夾將建立於此，可指定隨身碟路徑): ").strip()
        if not main_output_dir:
            print("錯誤：主輸出目錄不能為空。")
            continue
        # 嘗試解析路徑，但不立即創建主目錄，讓用戶確認
        main_output_dir = os.path.abspath(main_output_dir)
        print(f"  (解析後的主輸出目錄路徑: {main_output_dir})")

        # 檢查是否與輸入目錄相同
        if input_dir == main_output_dir:
            confirm = input("警告：主輸出目錄與輸入目錄相同，不建議這樣做。確定要繼續嗎？ (y/n): ").lower()
            if confirm != 'y':
                continue
        break

    # --- 獲取輸出子資料夾的基礎名稱 (例如 'a') ---
    output_base_prefix = input("請輸入輸出子資料夾的基礎名稱 (例如輸入 'a'，則 1.mov 的輸出會存入 'a1' 資料夾。直接按 Enter 則使用影片原名作為資料夾名): ").strip()


    # --- 確保主輸出目錄存在 ---
    # 在這裡才創建主目錄，避免用戶輸錯路徑時提前創建了錯誤的目錄
    try:
        os.makedirs(main_output_dir, exist_ok=True)
        print(f"主輸出目錄 '{main_output_dir}' 已確認或建立。")
    except OSError as e:
        print(f"錯誤：無法建立或訪問主輸出目錄 '{main_output_dir}': {e}")
        print("請檢查路徑是否正確以及是否有寫入權限。")
        sys.exit(1)


    print("-" * 30)
    print(f"輸入目錄: {input_dir}")
    print(f"主輸出目錄: {main_output_dir}")
    print(f"輸出子資料夾前綴: '{output_base_prefix}'" if output_base_prefix else "輸出子資料夾前綴: 無 (使用影片原名)")
    print(f"抽幀率: {FRAMES_PER_SECOND_TO_EXTRACT} 幀/秒")
    print(f"圖片格式: .{OUTPUT_IMAGE_FORMAT}")
    print("-" * 30)
    input("確認以上資訊無誤後，請按 Enter 鍵開始處理所有影片...")
    print("開始批量處理...")

    total_saved_frames = 0
    processed_videos = 0
    skipped_videos = 0

    # --- 查找輸入目錄中的影片檔案 ---
    video_extensions = ('*.mov', '*.mp4', '*.avi', '*.mkv')
    video_files = []
    for ext in video_extensions:
        # 使用 os.path.join 確保跨平台路徑正確
        video_files.extend(glob.glob(os.path.join(input_dir, ext)))
        video_files.extend(glob.glob(os.path.join(input_dir, ext.upper())))

    if not video_files:
        print(f"錯誤：在輸入目錄 '{input_dir}' 中未找到任何支援的影片檔案 ({', '.join(video_extensions)})。")
        sys.exit(1)

    # 對影片進行排序 (例如按數字順序 1, 2, ..., 10, 11...)
    # 這需要更智能的排序，處理像 '1.mov', '10.mov', '2.mov' 的情況
    def sort_key(filepath):
        """
        生成用於自然排序的鍵。
        將數字檔名和字串檔名分開，並確保數字按數值排序。
        返回一個元組 (type_indicator, value)。
        """
        name = os.path.splitext(os.path.basename(filepath))[0]
        try:
            # 如果檔名是數字，返回 (0, 數字值)
            return (0, int(name))
        except ValueError:
            # 如果檔名是字串，返回 (1, 字串值)
            return (1, name)


    print(f"找到 {len(video_files)} 個影片檔案，將按順序處理...")

    # --- 遍歷找到的影片檔案 ---
    for video_path in video_files:
        video_base_name = os.path.splitext(os.path.basename(video_path))[0]
        expected_txt_path = os.path.join(input_dir, f"{video_base_name}.txt")

        # 讀取對應的標註行
        annotation_line = read_annotation_line(expected_txt_path)

        if annotation_line:
            # --- 確定此影片的輸出子目錄名稱 ---
            if output_base_prefix:
                # 使用前綴 + 影片基礎名
                subfolder_name = f"{output_base_prefix}{video_base_name}"
            else:
                # 直接使用影片基礎名
                subfolder_name = video_base_name

            # 組合完整的子目錄路徑
            video_output_subdir = os.path.join(main_output_dir, subfolder_name)

            # 處理影片，將結果存入 video_output_subdir
            saved_frames_for_video = process_video(video_path, annotation_line, video_output_subdir)
            total_saved_frames += saved_frames_for_video
            if saved_frames_for_video >= 0:
                 processed_videos += 1
        else:
            print(f"\n--- 跳過影片: {os.path.basename(video_path)} (原因：找不到或無法讀取有效的標註檔 '{os.path.basename(expected_txt_path)}') ---")
            skipped_videos += 1

    # --- 最終總結 ---
    print("\n" + "=" * 40)
    print("      批量處理完成！")
    print(f"      成功處理影片數: {processed_videos}")
    print(f"      因標註檔問題跳過影片數: {skipped_videos}")
    print(f"      總共儲存的圖像/TXT 對數量: {total_saved_frames}")
    print(f"      所有輸出檔案已儲存至主目錄下的各子資料夾中:")
    print(f"      主輸出目錄: '{main_output_dir}'")
    print("=" * 40)


if __name__ == "__main__":
    main()