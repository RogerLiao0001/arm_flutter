# 🤖 機械手臂控制系統 (Robotic Arm Controller System)

本專案為一套全方位的機械手臂控制解決方案，具備即時視訊串流、AI 物件偵測、逆運動學 (IK) 控制以及多種感測介面。系統支援單一手臂基礎控制與多達四支手臂的協同控制架構。

---

## 📋 目錄 Table of Contents

- [系統架構 System Overview](#-系統架構-system-overview)
- [專案結構 Project Structure](#-專案結構-project-structure)
- [核心功能 Core Features](#-核心功能-core-features)
- [控制方式 Control Methods](#-控制方式-control-methods)
- [AI 視覺系統 YOLO Detection](#-ai-視覺系統-yolo-detection)
- [自動化標註工具 Auto-Labeling](#-自動化標註工具-auto-labeling)
- [雲端伺服器部署指南 Deployment Guide](#-雲端伺服器部署指南-deployment-guide)
- [硬體與韌體設定 Hardware & Firmware](#-硬體與韌體設定-hardware--firmware)

---

## 🎯 系統架構 System Overview

本系統支援 6 軸機械手臂，提供即時 AI 視覺回饋與多樣化的遠端操作介面。

**主要組件 Key Components:**
1. **Flutter App** - 行動裝置控制介面（支援 IK 模式與直接馬達角度控制）。
2. **LiveKit** - 基於 WebRTC 的低延遲即時視訊串流技術。
3. **YOLO AI** - GPU 加速物件偵測，提供即時視覺辨識能力。
4. **Leap Motion** - 紅外線手勢追蹤控制，實現無接觸式操作。
5. **Web Publisher/Viewer** - 網頁版攝影機發送端與多功能觀看端。
6. **自動化標註工具** - 針對特定場景開發的 YOLO 資料集批次標註工具。

---

## 📁 專案結構 Project Structure

本儲存庫採雙版本並行架構，確保開發靈活性與系統穩定性：

```
app/
├── lib/ & web/                         # 單一手臂控制系統 (Legacy)
│   └── ui/motor_control_page.dart      # 🎮 主控制頁面原始碼
├── four_arm_support/                   # 🚀 四手臂協同架構 (2026 更新)
│   ├── flutter_app/                    # 支援多臂切換與適配流優化版 App
│   ├── firmware/                       # Arm 1 ~ Arm 4 獨立 ESP8266 轉發程式
│   ├── server/                         # Token Server 與自動化部署腳本
│   └── web_client/                     # 網頁版攝影機端 (camera.html)
├── Support/                            # 🛠️ 輔助工具集
│   ├── Leap motion/                    # Python 手勢控制腳本
│   ├── 自動框圖/                       # 批次自動標註工具
│   ├── ai_bot.py                       # GPU YOLO 偵測 Bot 程式
│   ├── models3/                        # 預訓練 YOLO 模型檔
│   └── Arduino/                        # 各類硬體通訊測試腳本
├── ai_publisher.html                   # 📹 攝影機發送端 (支援外接鏡頭)
├── ai_viewer.html                      # 📺 視訊接收端 (具備 YOLO 框疊加)
└── README.md
```

---

## 🚀 核心功能 Core Features

- **逆運動學控制 (IK)** - 精確控制 6 軸末端位置（x, y, z, rx, ry, rz），即時透過 MQTT 發布指令。
- **低延遲視訊串流** - 整合 LiveKit WebRTC，支援多鏡頭（FaceTime / Azure Kinect / iPhone）切換。
- **即時 AI 偵測** - 支援伺服器端 GPU 加速辨識，邊界框即時回傳並疊加於 App/Web 介面。
- **多樣化控制模式** - 支援虛擬搖桿 (Gamepad)、滑桿直接控制 (Slider) 以及 Leap Motion 手勢感應。

---

## 🎮 控制方式 Control Methods

### 1. Flutter App
**功能描述**:
- **Gamepad 模式**：虛擬搖桿控制，適合精細的 IK 位置調整。
- **Slider 模式**：直接控制 A-F 六個馬達的角度（0-180度）。
- **視訊監視器**：接收來自伺服器的 WebRTC 影像與 AI 座標。

**啟動方式**:
```bash
# 執行舊版單臂控制
flutter run

# 執行新版多臂控制
cd four_arm_support/flutter_app
flutter run
```

### 2. Leap Motion (紅外線手勢控制)
**檔案位置**: `Support/Leap motion/roll_IK.py`
**操作說明**: 獨立於手機 App 的控制方案，直接透過手勢位置進行 IK 指令發布。
- **快捷鍵**: `a` 歸零 | `r` 重置 | `s` 暫停/恢復 | `q` 退出。
- **MQTT 遠端控制**: Topic `servo/arm2/cmd`，Payload 可為 `zero`, `reset`, `pause` 等。

---

## 🧠 AI 視覺系統 YOLO Detection

**技術流程**:
`攝影機端 (Publisher) → LiveKit 伺服器 → AI Bot (GPU 運算) → Data Channel 回傳 → 接收端 (App/Web)`

- **效能指標**: 在 g4dn 系列主機上可達到即時處理，建議每 10 幀處理一次以優化資源。
- **偵測格式**: 使用 JSON 陣列傳輸，包含 `label`, `confidence`, 以及正規化後的 `box` 座標 (0-1)。
- **自動清除**: 接收端具備 3 秒無訊號自動清除邊界框機制，避免殘影干擾。

---

## 🏷️ 自動化標註工具 Auto-Labeling

**檔案位置**: `Support/自動框圖/autoyolomany.py`
**用途**: 針對物體固定但環境/角度變化的場景，自動從影片提取影格並根據已知座標生成標註檔。
- **使用步驟**:
    1. 將物體運動影片放置於腳本目錄。
    2. 為每個影片建立初始的 `.txt` 標註檔。
    3. 執行腳本，系統將依設定的抽幀數 (預設 30fps) 自動產生數千張已標註圖片。

---

## ☁️ 雲端伺服器部署指南 Deployment Guide

本系統可部署於任何具備公共 IP 的雲端主機環境。

### 1. 伺服器環境安裝
建議作業系統：Ubuntu 22.04 LTS 或 Amazon Linux 2023。

```bash
# 安裝 Nginx 與 Mosquitto
sudo apt update && sudo apt install nginx mosquitto -y
```

### 2. Nginx 反向代理設定
Nginx 負責 HTTPS、靜態網頁託管與 MQTT WebSocket 轉發。
**設定檔範例 (`/etc/nginx/conf.d/arm.conf`)**:
```nginx
server {
    listen 80;
    server_name YOUR_DOMAIN.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name YOUR_DOMAIN.com;

    # SSL 憑證路徑
    ssl_certificate /etc/ssl/certs/cert.pem;
    ssl_certificate_key /etc/ssl/private/key.pem;

    # 1. 前端網頁部署位置
    location / {
        root /var/www/robotic-arm/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    # 2. Token Server API 轉發
    location /get-livekit-token {
        proxy_pass http://127.0.0.1:5000;
        add_header 'Access-Control-Allow-Origin' '*' always;
    }

    # 3. MQTT over WebSocket
    location /mqtt {
        proxy_pass http://127.0.0.1:9001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
    }
}
```

### 3. Mosquitto 設定
**設定檔範例 (`/etc/mosquitto/conf.d/default.conf`)**:
```conf
# 監聽標準 MQTT Port (給硬體 ESP8266)
listener 1883
allow_anonymous true

# 監聽 WebSocket Port (給 Web/App)
listener 9001
protocol websockets
```

### 4. LiveKit Token Server
用於安全核發視訊連線 Token 的 Python 後端。
- **路徑**: `four_arm_support/server/token_server.py`
- **執行**: `nohup python3 token_server.py > server.log 2>&1 &`

---

## ⚙️ 硬體與韌體設定 Hardware & Firmware

### 1. 通訊 Topic 規範
- `servo/armX/ik` - IK 座標指令 (格式: `"IK x y z rx ry rz"`)。
- `servo/armX/a-f` - 直接角度指令 (格式: `{"angle": 90}`)。
- `servo/armX/cmd` - 系統指令 (如 `zero`, `reset`, `stop`)。

### 2. ESP8266 燒錄
1. 進入 `four_arm_support/firmware/ArmX/` 目錄。
2. 開啟 `.ino` 檔案並修正 `mqtt_server` 為您的伺服器 IP。
3. 使用 Arduino IDE 將程式碼上傳至對應的手臂硬體。

---

## 🛠️ 維護筆記 Maintenance Notes

- **服務狀態檢查**: `sudo systemctl status nginx mosquitto`
- **查看 API 日誌**: `tail -f token_server.log`
- **更新前端**: 將 `flutter build web` 產生的檔案上傳至伺服器 `/var/www/robotic-arm/html` 目錄。

**最後更新日期**: 2026-02-13
**授權**: MIT License
