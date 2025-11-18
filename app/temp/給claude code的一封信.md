好的，這是一個非常好的想法。為專案建立清晰的架構總結和後續開發路徑，對於維護性和交接至關重要。

以下是對您目前專案的完整總結，以及為未來開發者提供的建議。

---

### 專案總結：即時 AI 影像疊圖串流系統

#### 1. 專案目標

本專案旨在建立一個基於 WebRTC 技術的低延遲、一對多視訊串流系統。系統允許發布端 (Publisher) 推送即時影像，並由一個雲端 AI 伺服器對影像進行即時 YOLO 物件偵測。最終，觀看端 (Viewer) 能接收到原始影像串流，並可選擇是否將 AI 偵測結果（邊界框）即時疊加在畫面上顯示。發布端同樣可以在本地預覽 AI 疊圖效果。

#### 2. 核心技術棧

*   **即時通訊 (RTC)**: **LiveKit Cloud** - 作為高效能的 WebRTC 媒體伺服器 (SFU)，負責所有視訊、音訊和資料通道的路由與分發。
*   **AI 推理**: **Python 3** 搭配 **Ultralytics YOLOv8** 函式庫，運行在配備 NVIDIA GPU 的雲端伺服器上。
*   **前端**: 純 **HTML, CSS, JavaScript**，使用 **LiveKit Client SDK** 與 LiveKit Cloud 互動。
*   **後端服務**: 使用 **aiohttp** 函式庫，讓 Python AI Bot 自身提供一個輕量級的 REST API 端點。
*   **雲端基礎設施**:
    *   **Web 伺服器**: 一台標準 Linux 伺服器 (2vCPU)，運行 **Nginx**，用於託管前端網頁和作為 API 反向代理。
    *   **AI 伺服器**: 一台 **AWS EC2 `g4dn.xlarge`** (或同等級的 GPU) 執行個體，專門用於執行 AI Bot。
*   **程序管理**: 在 AI 伺服器上使用 **systemd** 將 Python Bot 作為一個穩定、可自動重啟的系統服務來管理。

#### 3. 系統架構與資料流

本專案採用專業的微服務架構，將不同職責的元件分離部署，以確保性能和穩定性。

  *(此處應有一張架構圖，以下為文字描述)*

1.  **發布端 (Publisher - `ai_publisher.html`)**:
    *   使用者在瀏覽器中開啟此頁面。
    *   頁面透過 **Canvas API** 擷取攝影機影像，以實現即時影像翻轉。
    *   將處理後的影像串流透過 WebRTC 發布到 **LiveKit Cloud**。
    *   同時，透過資料通道 (Data Channel) 向房間發送指令（例如，更換 AI 模型）。
    *   監聽來自 AI Bot 的 YOLO 結果，並在本地 Canvas 上繪製疊圖供預覽。

2.  **Web 伺服器 (Nginx @ 178.128.54.195)**:
    *   **職責一 (網頁託管)**：向使用者提供 `ai_publisher.html` 和 `ai_viewer.html` 靜態檔案。
    *   **職責二 (反向代理)**：接收來自 Publisher 的 API 請求 (如 `https://roger01.site/api/models`)，並將其安全地轉發到 AI 伺服器的 `8080` 連接埠。這是為了繞過瀏覽器的混合內容安全策略 (Mixed-Content Policy) 和簡化外部網路存取。

3.  **AI Bot 伺服器 (Python @ AWS EC2 GPU)**:
    *   **職責一 (AI 推理)**：
        *   程式 (`ai_bot.py`) 以獨立參與者的身份加入同一個 LiveKit 房間。
        *   訂閱來自 Publisher 的影像串流。
        *   在 GPU 上對接收到的影像幀進行 YOLO 推理。
        *   將推理結果（物件標籤、座標、信心度）打包成輕量級的 JSON 資料。
        *   透過 LiveKit 資料通道將 JSON 廣播回房間。
    *   **職責二 (API 服務)**：
        *   內建一個 `aiohttp` 伺服器，監聽 `8080` 連接埠。
        *   提供 `/models` 端點，讀取本地 `models` 資料夾中的檔案列表並回傳。
    *   **職責三 (指令監聽)**：監聽來自 Publisher 的資料通道訊息，以動態切換 YOLO 模型。

4.  **觀看端 (Viewer - `viewer.html`)**:
    *   使用者在瀏覽器中開啟此頁面。
    *   **同時訂閱**來自 LiveKit Cloud 的兩路資料：
        *   來自 Publisher 的**原始影像串流**。
        *   來自 AI Bot 的 **JSON 資料流**。
    *   將影像串流顯示在 `<video>` 標籤上。
    *   使用覆蓋的 `<canvas>` 標籤，根據接收到的 JSON 資料即時繪製 AI 邊界框。

#### 4. 專案部署與管理

*   **前端部署**: 將 `html` 檔案直接 `scp` 到 Web 伺服器的 Nginx 網站根目錄 (`/var/www/html/roger01.site/`)。
*   **後端部署**:
    1.  在 AWS EC2 GPU 伺服器上，將專案程式碼透過 `git clone` 下載到 `/home/ubuntu/livekit-ai-bot`。
    2.  在專案目錄下建立並啟動 Python 虛擬環境 (`venv`)。
    3.  使用 `pip install` 安裝所有必要的套件。
    4.  將所有 `.pt` 模型檔案上傳到 `/home/ubuntu/livekit-ai-bot/models`。
    5.  設定 `systemd` 服務檔案 (`/etc/systemd/system/livekit-ai-bot.service`)，將 API 金鑰等機密資訊儲存在 `Environment` 變數中，並設定服務開機自啟與自動重啟。
    6.  使用 `sudo systemctl start/stop/status/restart livekit-ai-bot.service` 來管理 Bot 服務。
    7.  使用 `sudo journalctl -u livekit-ai-bot.service -f` 來即時查看日誌。

---

### 後續步驟與開發建議

#### 1. 短期優化 (Low-hanging Fruit)

*   **使用者介面 (UI/UX) 改善**:
    *   為 Publisher 和 Viewer 增加更清晰的狀態指示燈（例如：連接中、已連接、AI 運算中）。
    *   增加錯誤處理提示，例如當攝影機權限被拒絕時，在頁面上給予友善的提示。
    *   將控制按鈕（如鏡像、顯示疊圖）設計得更美觀、更直覺。
*   **性能參數動態調整**:
    *   在 Publisher 端增加一個滑桿或下拉選單，允許使用者動態調整 AI Bot 的 `FRAME_INTERVAL`。這樣可以在需要高精度時降低間隔，在需要流暢度時增加間隔。 (這需要透過資料通道發送新指令給 Bot)。
*   **程式碼重構**:
    *   將前端 JavaScript 程式碼模組化，把 LiveKit 連接邏輯、UI 控制邏輯、Canvas 繪圖邏輯分離到不同的函式或檔案中，提高可讀性。

#### 2. 中期發展 (核心功能擴展)

*   **支援多個 Publisher**: 目前架構預設只處理一個名為 `webcam-publisher` 的發布者。可以修改 AI Bot 的邏輯，使其能夠同時訂閱和處理來自**多個不同發布者**的影像串流，並將 AI 結果與其來源對應。
*   **增加更多 AI 模型**: 整合其他類型的 AI 模型，例如：
    *   **人臉辨識 (Face Recognition)**: 辨識畫面中的特定人物。
    *   **姿態估計 (Pose Estimation)**: 偵測人體的骨架關節點。
    *   **影像風格轉換 (Style Transfer)**: 將即時影像轉換成梵谷風格或其他藝術風格。
    *   這需要在 Publisher 端提供一個選擇 AI 功能類型的介面。
*   **錄影功能**: 利用 LiveKit 的 Server-side Recording API，允許使用者將帶有（或不帶）AI 疊圖的串流錄製成影片檔案，存放在雲端儲存（如 AWS S3）中。

#### 3. 長期規劃 (架構演進)

*   **AI Bot 橫向擴展 (Scaling)**: 當使用者數量劇增時，單一的 AI Bot 伺服器可能會成為瓶頸。可以設計一個負載平衡機制，自動啟動多個 AI Bot 實例，並將不同的 LiveKit 房間分配給不同的 Bot 處理。
*   **結果資料庫化**: 將 AI 偵測到的結果（例如：在某個時間點，畫面中出現了 "person"）連同時間戳儲存到一個資料庫（如 PostgreSQL 或 InfluxDB）中。這將為後續的數據分析、事件搜尋等高階應用打下基礎。
*   **遷移至 Kubernetes**: 為了實現自動化擴展和高可用性，可以將 Web 伺服器和 AI Bot 全部容器化 (Docker)，並使用 Kubernetes (例如 AWS EKS 或 Google GKE) 進行統一的部署和管理。

這份文件為任何後續接手的開發者提供了清晰的專案現狀藍圖和未來的發展方向。

好的，您說得完全正確。一份真正有價值的交接文件，不應該只是零散的程式碼和指令，而必須是經過深思熟慮、重新梳理整個專案來龍去脈的完整藍圖。

我已經將我們整個對話的過程——從最初的構想到中間遇到的所有錯誤、性能瓶頸，再到最終的架構決策——全部重新思考並吸收。以下，我將為您呈現一份基於這些經驗的、真正達到「說明書等級」的完整專案文件。

這份文件旨在讓任何接手的開發者，都能夠清晰地理解**「這是什麼」、「它如何運作」，以及最重要的，「我們當初為什麼要這麼做」**。

---

### **專案交接手冊：即時 AI 影像疊圖串流系統**

#### **第一章：專案概覽**

##### **1.1 專案目標**

本專案旨在建立一個基於 WebRTC 的低延遲、一對多視訊串流系統。系統允許發布端 (Publisher) 推送即時影像，由一個雲端 AI 伺服器對影像進行即時 YOLO 物件偵測。最終，觀看端 (Viewer) 能接收到原始影像串流，並可選擇是否將 AI 偵測結果（邊界框）即時疊加在畫面上顯示。發布端同樣可以在本地預覽 AI 疊圖效果。

##### **1.2 核心技術棧**

*   **即時通訊 (RTC)**: **LiveKit Cloud** (SaaS) - 作為高效能的 WebRTC 媒體伺服器 (SFU)，負責所有視訊、音訊和資料通道的路由與分發。
*   **AI 推理**: **Python 3** 搭配 **Ultralytics YOLOv8** 函式庫，運行在配備 NVIDIA GPU 的雲端伺服器上。
*   **前端**: 純 **HTML, CSS, JavaScript**，使用 **LiveKit Client SDK** 與 LiveKit Cloud 互動。
*   **後端服務**: 使用 **aiohttp** 函式庫，讓 Python AI Bot 自身提供一個輕量級的 REST API 端點。
*   **雲端基礎設施**:
    *   **Web 伺服器**: 一台標準 Linux 伺服器 (2vCPU)，運行 **Nginx**，用於託管前端網頁和作為 API 反向代理。
    *   **AI 伺服器**: 一台 **AWS EC2 `g4dn.xlarge`** (或同等級的 GPU) 執行個體，專門用於執行 AI Bot。
*   **作業系統**: Ubuntu 22.04 LTS
*   **程序管理**: systemd

#### **第二章：系統架構**

##### **2.1 架構圖**
*(文字描述版本)*

```
+----------------+      +------------------------+      +-------------------+
|                |----->|                        |----->|                   |
|  Publisher     |  1.  |      LiveKit Cloud     |  3.  |      Viewer       |
| (Web Browser)  | Video|       (SFU Media)      | Video|   (Web Browser)   |
|                |<-----|                        |<-----|                   |
+----------------+  6.  +------------------------+  4.  +-------------------+
       ^           JSON          ^      ^           JSON           ^
       | 2a.                     | 2b.  | 5.                       |
       | HTTPS                   | WSS  | WSS                      |
       | (API Req)               |      |                          |
       v                         |      |                          |
+----------------+      +--------+------+--------------------------+
|  Web Server    |      |         AI Bot Server (AWS EC2 GPU)       |
| (Nginx Proxy)  |----->| (Python/YOLO/LiveKit SDK/aiohttp API)     |
| @178.128.54.195| 2c.  |                                           |
+----------------+ HTTP |                                           |
                        +-------------------------------------------+
```

##### **2.2 資料流詳解**

1.  **發布 (Publish)**: Publisher 使用 Canvas API 處理影像後，透過 WebRTC 將 **影像串流** 發布到 LiveKit Cloud。
2.  **API 請求**:
    *   `2a`: Publisher 頁面向 `https://roger01.site/api/models` 發起 **HTTPS 請求**。
    *   `2b`: Nginx 伺服器作為**反向代理**，將此請求轉發到 AI Bot 伺服器的 8080 連接埠。
    *   `2c`: AI Bot 的 aiohttp 服務回應模型列表 (JSON)。
3.  **訂閱 (Subscribe)**: Viewer 和 AI Bot 都作為訂閱者，從 LiveKit Cloud 訂閱 Publisher 的**影像串流**。
4.  **AI 推理與廣播**:
    *   AI Bot 接收影像幀，在 GPU 上執行 YOLO 推理。
    *   將偵測結果 (物件標籤、座標、信心度) 打包成輕量級的 **JSON 資料**。
    *   透過 LiveKit 的資料通道 (Data Channel) 將 JSON **廣播**回房間。
5.  **結果接收**: Viewer 和 Publisher 同時接收到 AI Bot 廣播的 **JSON 資料**。
6.  **畫面渲染**:
    *   Viewer 在本地的 Canvas 上，將接收到的 JSON 資料繪製成邊界框，疊加在影像上。
    *   Publisher 同樣可以在本地預覽疊圖效果。

#### **第三章：檔案與伺服器結構**

##### **3.1 本地開發檔案結構 (建議)**
所有程式碼應存放在一個 Git 倉庫中，結構如下：

```
livekit-ai-project/
├── ai_bot/                      # 後端 AI Bot 相關檔案
│   ├── models/                  # 存放所有 .pt 模型檔案
│   │   ├── 11n-1.pt
│   │   └── ...
│   ├── venv/                    # Python 虛擬環境 (此目錄應加入 .gitignore)
│   ├── ai_bot.py                # AI Bot 主程式
│   └── requirements.txt         # Python 依賴列表
│
├── frontend/                    # 前端網頁相關檔案
│   ├── ai_publisher.html        # 發布端頁面
│   └── viewer.html              # 觀看端頁面
│
└── README.md                    # 專案說明文件
```

##### **3.2 雲端伺服器檔案結構**

**A. Web 伺服器 (ID: `web-server`, IP: `178.128.54.195`)**

*   **SSH 登入方式**:
    ```bash
    ssh root@178.128.54.195
    ```
    (需要輸入密碼)

*   **關鍵檔案路徑**:
    *   `/var/www/html/roger01.site/`: **網站根目錄**。
        *   `ai_publisher.html`: 部署於此。
        *   `viewer.html`: 部署於此。
    *   `/etc/nginx/sites-available/roger01.site`: **Nginx 設定檔**。包含反向代理到 AI 伺服器的設定。
    *   `/etc/letsencrypt/`: Certbot/Let's Encrypt SSL 憑證存放目錄。

**B. AI Bot 伺服器 (ID: `ai-server`, AWS EC2 `g4dn.xlarge`)**

*   **SSH 登入方式**:
    1.  找到當初建立實例時下載的 `.pem` 金鑰檔案 (例如 `aws-ai-bot-key.pem`)。
    2.  取得 EC2 實例的**公有 IPv4 位址** (例如 `34.228.19.123`)。
    3.  執行指令 (請替換為您的實際路徑和 IP)：
        ```bash
        # 先設定金鑰權限 (只需一次)
        chmod 400 /path/to/your/aws-ai-bot-key.pem

        # 使用金鑰登入
        ssh -i /path/to/your/aws-ai-bot-key.pem ubuntu@[EC2公有IP位址]
        ```

*   **關鍵檔案路徑**:
    *   `/home/ubuntu/livekit-ai-bot/`: **專案根目錄**。
        *   `ai_bot.py`: 主程式檔案。
        *   `models/`: 所有 `.pt` 模型檔案存放於此。
        *   `venv/`: 專用的 Python 虛擬環境。
    *   `/etc/systemd/system/livekit-ai-bot.service`: **`systemd` 服務設定檔**。定義了如何啟動、管理 Bot 程式，並儲存了 API 金鑰。

#### **第四章：各檔案用途詳解**

##### **4.1 `ai_publisher.html`**
*   **用途**: 供內容創作者使用的發布頁面。
*   **核心功能**:
    1.  **初始化**: 頁面載入時，向 `/api/models` (經 Nginx 轉發) 請求可用的 AI 模型列表，並動態填充下拉選單。
    2.  **串流處理**: 使用 `<canvas>` 從隱藏的 `<video>` 標籤中讀取攝影機畫面。`renderLoop` 函式負責將影像（根據是否鏡像的設定）繪製到主 Canvas 上。**我們實際傳輸的是這個 Canvas 的影像串流 (`canvas.captureStream()`)**，從而實現了「傳輸翻轉」的功能。
    3.  **LiveKit 連接**: 獲取 Token，連接到 LiveKit 房間，並發布 Canvas 影像串流。
    4.  **指令與回饋**:
        *   當使用者切換模型時，透過資料通道向房間發送 `setModel` 指令。
        *   訂閱房間的資料通道，接收 AI Bot 傳回的 YOLO JSON 結果。
        *   在覆蓋的 `overlay-canvas` 上繪製本地的 AI 疊圖，供發布者預覽。

##### **4.2 `viewer.html`**
*   **用途**: 供一般觀眾使用的觀看頁面。
*   **核心功能**:
    1.  **LiveKit 連接**: 獲取 Token，加入同一個房間。
    2.  **雙路訂閱**: 同時訂閱來自 Publisher 的**影像串流**和來自 AI Bot 的**資料串流**。
    3.  **渲染**: 將影像串流附加到 `<video>` 元素上播放。在覆蓋的 `<canvas>` 上，根據收到的 YOLO JSON 資料繪製邊界框。
    4.  **互動**: 提供開關，讓使用者可以自由選擇是否顯示 AI 疊圖。

##### **4.3 `ai_bot.py` (v9)**
*   **用途**: 整個系統的「大腦」，在 GPU 伺服器上 24/7 運行。
*   **核心功能**:
    1.  **aiohttp API 服務**: 在 `8080` 連接埠啟動一個 HTTP 伺服器，提供 `/models` API 端點，用於回傳 `models` 資料夾中的檔案列表。
    2.  **LiveKit Bot**:
        *   作為一個獨立客戶端 (`yolo-bot`) 加入 LiveKit 房間。
        *   **事件驅動**: 透過 `.on("event_name", callback)` 的方式監聽事件。
        *   `on_track_subscribed`: 當 Publisher 加入時觸發，開始監聽其影像軌道的 `'frame_received'` 事件。
        *   `on_frame_received`: **這是效能核心**。每當收到一幀影像，此函式會被呼叫。它內部包含「幀抽樣 (Frame Skipping)」邏輯，並將耗時的 `model.predict` 操作放到獨立的執行緒中執行，避免阻塞主事件迴圈。
        *   `on_data_received`: 監聽 Publisher 發來的 `setModel` 指令，並呼叫 `load_model` 函式動態切換模型。
    3.  **YOLO 推理**: 使用 `ultralytics` 函式庫，在 GPU (`cuda`) 上執行物件偵測，並將結果正規化為 0-1 之間的相對座標後，打包成 JSON 廣播出去。

#### **第五章：維護與後續開發**

##### **5.1 日常維護**

*   **查看 AI Bot 狀態/日誌**:
    ```bash
    # (SSH to AI Server)
    sudo systemctl status livekit-ai-bot.service
    sudo journalctl -u livekit-ai-bot.service -f --no-pager
    ```
*   **啟動/停止/重啟 AI Bot**:
    ```bash
    # (SSH to AI Server)
    sudo systemctl start/stop/restart livekit-ai-bot.service
    ```
*   **更新模型**: 只需將新的 `.pt` 檔案上傳到 AI 伺服器的 `/home/ubuntu/livekit-ai-bot/models/` 目錄下，然後重啟 AI Bot 服務即可。前端會自動讀取到新模型。
*   **更新程式碼**:
    1.  在本地修改程式碼後，推送到 Git 倉庫。
    2.  SSH 登入對應的伺服器 (Web 或 AI)。
    3.  進入專案目錄，執行 `git pull` 拉取最新程式碼。
    4.  如果是 AI Bot 的變更，執行 `sudo systemctl restart livekit-ai-bot.service`。
    5.  如果是前端的變更，清除瀏覽器快取即可看到效果。

##### **5.2 演示前的準備 (Spot -> On-Demand)**
為確保 100% 的穩定性，在正式演示前，建議將 AI 伺服器從 Spot 執行個體切換為 On-Demand 執行個體。

1.  在 AWS EC2 控制台，**終止 (Terminate)** Spot 執行個體。
2.  **啟動一個新的 On-Demand 執行個體**，使用完全相同的設定（AMI, 類型, 安全群組），但**不要**勾選 "請求 Spot 執行個體"。
3.  在新實例上**重複第二、三階段的部署步驟** (或者，更進階的作法是預先製作一個包含您程式碼的自訂 AMI)。
4.  取得新實例的公有 IP，更新 Web 伺服器上的 Nginx 設定檔，並重啟 Nginx。

##### **5.3 後續開發建議**
*   **短期**: 優化前端 UI/UX，增加動態性能參數調整功能。
*   **中期**: 支援多個發布者，整合更多種類的 AI 模型（如姿態估計）。
*   **長期**: 引入 Kubernetes 進行自動化擴展，並將 AI 結果資料庫化以供分析。

#### **第六章：關鍵架構決策 (The "Why")**

這部分旨在解釋專案演進過程中所做的關鍵決策，幫助後續開發者理解其背後的考量。

*   **決策一：為何採用獨立的 GPU 伺服器？**
    *   **問題**: 最初嘗試在通用的 2vCPU 伺服器上運行 AI Bot，導致接收端畫面嚴重凍結。
    *   **分析**: 即時影像串流的**解碼**過程本身已是 CPU 密集型任務，在其之上再疊加 **YOLO 推理**（尤其是高解析度影像）會徹底癱瘓通用 CPU。本地 MacBook 測試成功是因為其高效能 SoC 包含了專用的 AI/GPU 加速硬體，這與雲端 vCPU 的設計目標完全不同。
    *   **結論**: 為了從根本上解決性能瓶頸，實現流暢的 AI 推理，將運算任務分離到專用的 GPU 伺服器是唯一可行且專業的方案。

*   **決策二：為何使用 Nginx 反向代理？**
    *   **問題**: 前端頁面 (`https://...`) 直接請求 AI Bot 的 API (`http://...:8080`) 會失敗。
    *   **分析**: 這是由兩個因素導致的：1) 瀏覽器出於安全考量，會阻止安全的 HTTPS 頁面請求不安全的 HTTP 資源（混合內容）。2) 雲端平台的防火牆通常只開放標準連接埠，`8080` 等自訂連接埠需要額外設定。
    *   **結論**: 透過在 Web 伺服器上設定 Nginx 反向代理，將外部安全的 `/api/...` 路徑請求，在伺服器內部轉發到 AI Bot 的 `8080` 連接埠。這完美地解決了安全策略和網路存取問題，是業界的標準作法。

*   **決策三：為何 AI Bot 程式碼演進至 v9 事件驅動模型？**
    *   **問題**: 專案早期，AI Bot 程式碼因對 LiveKit Python SDK 的 API 誤用而頻繁崩潰。
    *   **分析**: 錯誤主要集中在如何處理傳入的影像幀。最初嘗試的 `async for` 迭代 `Track` 物件的方法是錯誤的。
    *   **結論**: 經過查證官方文件，確認了正確的模式是**事件驅動**。即為 `Track` 物件註冊一個 `'frame_received'` 事件的監聽器 (Callback)。每當一幀到達，此監聽器被觸發。`v9` 版本的程式碼全面採用了這種穩定可靠的事件模型，並將耗時的 AI 推理操作放在獨立執行緒中，避免阻塞主事件迴圈，確保了服務的穩定性。

---
這份文件為任何後續接手的開發者提供了清晰的專案現狀藍圖和未來的發展方向。