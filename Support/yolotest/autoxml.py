import cv2
import os
import xml.etree.ElementTree as ET
from xml.dom import minidom
import sys # 用於錯誤時退出

# --- 使用者配置區 ---
# 這些值會在產生所有 XML 時被固定使用

# 1. 影像尺寸 (請根據您的固定攝影機畫面填寫)
IMG_WIDTH = 1920
IMG_HEIGHT = 1080
IMG_DEPTH = 3 # 通常彩色影像是 3 (RGB)

# 2. 物件資訊 (請根據您的固定物件填寫)
OBJECT_NAME = 'your_object_name' # 例如 'bottle', 'tool', 'person' 等

# 3. 固定邊界框 (Bounding Box) 座標 (請根據您的固定物件在畫面中的位置填寫)
#    (xmin, ymin) 是左上角座標
#    (xmax, ymax) 是右下角座標
BBOX_XMIN = 500
BBOX_YMIN = 200
BBOX_XMAX = 1500
BBOX_YMAX = 800

# 4. 每秒抽取的幀數
FRAMES_PER_SECOND_TO_EXTRACT = 5 # 您希望每秒抽 5-6 幀

# 5. 輸出圖片格式 ('png' 或 'jpg')
OUTPUT_IMAGE_FORMAT = 'png'

# --- 固定欄位值 (通常不需要修改) ---
XML_DATABASE = 'Unknown'
XML_POSE = 'Unspecified'
XML_TRUNCATED = 0
XML_DIFFICULT = 0
XML_SEGMENTED = 0
# --- 使用者配置區結束 ---


def create_xml_annotation(folder_name, filename, img_path, img_width, img_height, img_depth,
                          object_name, xmin, ymin, xmax, ymax):
    """建立單一 XML 標註檔的內容 (ElementTree 物件)"""

    annotation = ET.Element('annotation')

    folder = ET.SubElement(annotation, 'folder')
    folder.text = folder_name

    fname = ET.SubElement(annotation, 'filename')
    fname.text = filename

    # --- 路徑處理 ---
    # 使用相對路徑 (只有檔案名稱)，這樣移動資料夾時才不會出錯
    path = ET.SubElement(annotation, 'path')
    path.text = filename # 只填入檔名

    source = ET.SubElement(annotation, 'source')
    database = ET.SubElement(source, 'database')
    database.text = XML_DATABASE

    size = ET.SubElement(annotation, 'size')
    width_el = ET.SubElement(size, 'width')
    width_el.text = str(img_width)
    height_el = ET.SubElement(size, 'height')
    height_el.text = str(img_height)
    depth_el = ET.SubElement(size, 'depth')
    depth_el.text = str(img_depth)

    segmented = ET.SubElement(annotation, 'segmented')
    segmented.text = str(XML_SEGMENTED)

    obj = ET.SubElement(annotation, 'object')
    name = ET.SubElement(obj, 'name')
    name.text = object_name
    pose = ET.SubElement(obj, 'pose')
    pose.text = XML_POSE
    truncated = ET.SubElement(obj, 'truncated')
    truncated.text = str(XML_TRUNCATED)
    difficult = ET.SubElement(obj, 'difficult')
    difficult.text = str(XML_DIFFICULT)

    bndbox = ET.SubElement(obj, 'bndbox')
    xmin_el = ET.SubElement(bndbox, 'xmin')
    xmin_el.text = str(xmin)
    ymin_el = ET.SubElement(bndbox, 'ymin')
    ymin_el.text = str(ymin)
    xmax_el = ET.SubElement(bndbox, 'xmax')
    xmax_el.text = str(xmax)
    ymax_el = ET.SubElement(bndbox, 'ymax')
    ymax_el.text = str(ymax)

    return annotation

def prettify_xml(elem):
    """將 ElementTree 物件轉換為格式化 (美化) 的 XML 字串，使用 Tab 縮排"""
    rough_string = ET.tostring(elem, 'utf-8')
    reparsed = minidom.parseString(rough_string)
    # 修改為使用 Tab ('\t') 進行縮排以匹配範例
    # 同時移除 minidom 自動添加的 XML 宣告行 (<?xml version="1.0" ?>)
    # 因為範例中沒有這一行
    xml_declaration = reparsed.toprettyxml(indent="\t").splitlines()[0] # 獲取第一行宣告
    return reparsed.toprettyxml(indent="\t").replace(xml_declaration + '\n', '', 1) # 移除宣告行和其後換行


def main():
    print("--- 開始執行影片抽幀與固定標註生成程式 ---")

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
    if fps <= 0:
        print("警告：無法讀取影片的 FPS，將假設為 30 FPS。抽幀可能不準確。")
        fps = 30 # 提供一個預設值

    # 計算抽幀間隔
    frame_interval = int(fps / FRAMES_PER_SECOND_TO_EXTRACT)
    if frame_interval < 1:
        frame_interval = 1 # 確保至少是 1

    print("-" * 30)
    print(f"影片路徑: {video_path}")
    print(f"影片 FPS: {fps:.2f}")
    print(f"設定抽幀率: {FRAMES_PER_SECOND_TO_EXTRACT} 幀/秒")
    print(f"實際抽幀間隔: 每 {frame_interval} 幀抽取 1 幀")
    print(f"輸出檔案基礎名稱: {output_base_name}")
    print(f"輸出資料夾: {output_folder_name}")
    print(f"輸出圖片格式: .{OUTPUT_IMAGE_FORMAT}")
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
            xml_filename = f"{output_base_name}{saved_count}.xml"

            # --- 產生完整路徑 ---
            image_save_path = os.path.join(output_folder_name, image_filename)
            xml_save_path = os.path.join(output_folder_name, xml_filename)

            # --- 儲存圖片 ---
            try:
                 # 在儲存前檢查 Frame 是否有效 (有時影片結尾會讀到空的 Frame)
                 if frame is None or frame.size == 0:
                     print(f"\n警告: 在影片幀 {frame_count} 讀取到空畫面，跳過此幀。")
                     continue
                 cv2.imwrite(image_save_path, frame)
            except Exception as e:
                print(f"\n錯誤：無法儲存圖片 '{image_save_path}': {e}")
                print("可能是磁碟空間不足或權限問題，跳過此幀...")
                continue # 跳過這一幀的處理

            # --- 產生並儲存 XML ---
            try:
                xml_tree = create_xml_annotation(
                    folder_name=output_folder_name,
                    filename=image_filename,
                    img_path=image_save_path, # 傳遞路徑供參考，但 XML 中只用檔名
                    img_width=IMG_WIDTH,
                    img_height=IMG_HEIGHT,
                    img_depth=IMG_DEPTH,
                    object_name=OBJECT_NAME,
                    xmin=BBOX_XMIN,
                    ymin=BBOX_YMIN,
                    xmax=BBOX_XMAX,
                    ymax=BBOX_YMAX
                )

                # 將 XML 寫入檔案 (使用美化格式)
                pretty_xml_string = prettify_xml(xml_tree)
                with open(xml_save_path, "w", encoding='utf-8') as f:
                    f.write(pretty_xml_string)

            except Exception as e:
                 print(f"\n錯誤：無法產生或儲存 XML 檔案 '{xml_save_path}': {e}")
                 print("將嘗試刪除對應的圖片檔，以保持資料一致性...")
                 if os.path.exists(image_save_path):
                     try:
                         os.remove(image_save_path)
                         print(f"已刪除圖片: {image_save_path}")
                     except OSError as remove_err:
                         print(f"錯誤：無法刪除圖片 '{image_save_path}': {remove_err}")
                 continue # 跳過這一幀的處理


            # 使用 '\r' 和 end='' 實現原地更新進度，避免洗版
            print(f"\r已處理並儲存 {saved_count} 個圖像/XML 對...", end='')


        frame_count += 1

    # --- 清理 ---
    cap.release()
    print() # 換行，結束原地更新的進度顯示
    print("-" * 30)
    print(f"處理完成！")
    if saved_count > 0:
        print(f"總共從影片 '{os.path.basename(video_path)}' 抽取並儲存了 {saved_count} 張圖片及對應的 XML 檔案。")
        # 顯示絕對路徑方便使用者找到
        abs_output_path = os.path.abspath(output_folder_name)
        print(f"檔案儲存在資料夾: '{abs_output_path}'")
    else:
        print("沒有從影片中抽取任何幀。請檢查影片長度、FPS 或抽幀間隔設定。")
    print("-" * 30)


if __name__ == "__main__":
    main()