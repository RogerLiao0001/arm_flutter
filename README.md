# 🤖 Robotic Arm Controller System / 機械手臂控制系統

A comprehensive robotic arm control system with real-time video streaming, AI object detection, and multiple control interfaces.

完整的機械手臂控制系統，具備即時視訊串流、AI 物件偵測與多種控制介面。

---

## 📋 目錄 Table of Contents

- [系統架構](#-系統架構-system-overview)
- [專案結構](#-專案結構-project-structure)
- [控制方式](#-控制方式-control-methods)
- [快速開始](#-快速開始-quick-start)

---

## 🎯 系統架構 System Overview

6 軸機械手臂控制系統，支援多種控制方式與即時 AI 視覺回饋。

**主要組件 Key Components:**
1. **Flutter App** - 手機控制介面（IK 模式 + 直接馬達控制）
2. **LiveKit** - WebRTC 即時視訊串流
3. **YOLO AI** - GPU 加速物件偵測（AWS Tesla T4）
4. **Leap Motion** - 紅外線手勢控制（需搭配 Arduino 硬體）
5. **Web Publisher/Viewer** - 網頁版攝影機與觀看介面
6. **自動框圖工具** - 批次 YOLO 資料集標註

---

## 📁 專案結構 Project Structure

```
arm_flutter/
├── app/                                # Flutter 應用程式
│   ├── lib/ui/motor_control_page.dart  # 🎮 主控制頁面
│   ├── ai_publisher.html               # 📹 攝影機發送端（支援外接鏡頭）
│   ├── ai_viewer.html                  # 📺 視訊接收端（YOLO 疊加）
│   ├── ai_bot.py                       # 🤖 GPU YOLO Bot
│   ├── models3/                        # YOLO 模型（11n-1/2/3, yolo11n）
│   └── temp/                           # 部署暫存檔案與文檔
│
├── Leap motion/roll_IK.py          # 🖐️ 手勢控制（紅外線 → MQTT IK）
├── 自動框圖/autoyolomany.py          # 🏷️ 批次標註工具（影片 → YOLO dataset）
└── README.md
```

---

## 🚀 核心功能 Core Features

- **逆運動學控制 (IK)** - 6 軸位置控制（x, y, z, rx, ry, rz），即時 MQTT 發布
- **視訊串流** - LiveKit WebRTC，支援多鏡頭（FaceTime / Azure Kinect / iPhone）
- **YOLO 物件偵測** - AWS Tesla T4 GPU 加速，即時邊界框疊加，3 秒自動清除
- **多控制模式** - Gamepad 模式 / Slider 直接控制 / Leap Motion 手勢控制

---

## 🎮 控制方式 Control Methods

### 1️⃣ Flutter App（主要控制介面）

**檔案位置:** `app/lib/ui/motor_control_page.dart`

**功能:**
- Gamepad 模式：遊戲手把式 IK 控制
- Slider 模式：6 個馬達直接控制（a-f）
- LiveKit 視訊接收器
- MQTT 連線狀態顯示

**啟動:**
```bash
cd app && flutter pub get && flutter run
```

---

### 2️⃣ Leap Motion（紅外線手勢控制）

**檔案位置:** `Leap motion/roll_IK.py`

**說明:** 使用紅外線手勢追蹤控制手臂，**不依賴手機 App 的獨立控制方式**。

**需求:** Leap Motion 硬體 + Arduino/ESP8266（IK 韌體）+ MQTT Broker

**啟動:**
```bash
cd "Leap motion" && pip install paho-mqtt leap-sdk && python roll_IK.py
```

**鍵盤控制:** `a` 歸零 | `r` 重置 | `s` 暫停/恢復 | `q` 退出

**MQTT 遠端控制:** Topic `servo/arm2/cmd`，Payload: `zero` / `reset` / `pause`

---

### 3️⃣ AI Publisher（網頁攝影機）

ai_publisher.html

**功能:** 攝影機選擇（前/後/外接）、畫質控制、AI 模型選擇、本地 YOLO 預覽

---

### 4️⃣ AI Viewer（網頁觀看端）

ai_viewer.html

**功能:** 全螢幕顯示、YOLO 疊加開關、滑鼠自動隱藏控制、3 秒自動清除框圖

---

## 🧠 AI 視覺系統 YOLO Detection

**架構流程:**
```
攝影機 → Publisher → LiveKit → YOLO Bot (AWS GPU) → Data Channel → Viewer/App
```

**YOLO Bot 部署:**
- AWS Instance: `i-0e73733fd74049f05` (大阪 ap-northeast-3)
- GPU: g4dn.xlarge (NVIDIA Tesla T4)
- 成本: ~$0.32/小時（Spot），停機僅付儲存費 ~$0.10/天
- 模型: 11n-1/2/3, yolo11n（支援切換）
- 跳幀處理：每 10 幀處理一次
- 開機自動啟動（systemd）

**偵測格式:** JSON 陣列，包含 label、confidence、box (normalized 0-1)

---

## 🏷️ 自動框圖工具 Auto-Labeling

**檔案位置:** `自動框圖/autoyolomany.py`

**用途:** 從**物體位置固定**的影片批次提取影格並自動套用 YOLO 標註，數秒內產生數千張標註圖片。

**適用情境:**
- 固定攝影機 + 移動輸送帶
- 靜態物體 + 旋轉攝影機
- 品質檢測資料集製作

**使用方式:**
1. 將影片放在腳本目錄
2. 為每個影片建立一個 `.txt` 標註檔（YOLO 格式第一行）
3. 執行 `python autoyolomany.py`
4. 輸出：每個影片產生數百張已標註圖片

**設定:** `FRAMES_PER_SECOND_TO_EXTRACT = 30` (每秒抽幀數)

---

## 🚀 快速開始 Quick Start

### 前置需求
- Flutter SDK 3.0+
- Python 3.8+
- MQTT Broker (Mosquitto)
- LiveKit Account（視訊串流）
- AWS Account（GPU 部署，選用）

### 啟動流程

```bash
# 1. 啟動 MQTT Broker
mosquitto -c /usr/local/etc/mosquitto/mosquitto.conf

# 2. 啟動 Flutter App
cd app && flutter pub get && flutter run

# 3. (選用) 啟動 Leap Motion 控制
cd "Leap motion" && python roll_IK.py

# 4. (選用) 啟動 AWS YOLO Bot - 見下方 AWS 部署說明
```

### 控制流程
```
Flutter/Leap Motion → MQTT → ESP8266 (IK 計算) → 機械手臂
```

---

## ☁️ AWS GPU 部署（選用）

### 開關機指令

```bash
# 進入 AWS CLI 環境
cd /Users/roger/CWorks/other/1030 && source venv/bin/activate

# 開機
aws ec2 start-instances --instance-ids i-0e73733fd74049f05 --region ap-northeast-3
aws ec2 wait instance-status-ok --instance-ids i-0e73733fd74049f05 --region ap-northeast-3

# 取得 IP
aws ec2 describe-instances --instance-ids i-0e73733fd74049f05 --region ap-northeast-3 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

# 關機
aws ec2 stop-instances --instance-ids i-0e73733fd74049f05 --region ap-northeast-3
```

### 部署更新

```bash
# SSH 連線
ssh -i app/temp/yolo-spot-key.pem ubuntu@<IP>

# 上傳 Bot
scp -i app/temp/yolo-spot-key.pem app/temp/ai_bot.py ubuntu@<IP>:/home/ubuntu/

# 上傳模型
scp -i app/temp/yolo-spot-key.pem app/models3/*.pt ubuntu@<IP>:/home/ubuntu/models2/

# 重啟服務
ssh -i app/temp/yolo-spot-key.pem ubuntu@<IP> "sudo systemctl restart yolo-bot.service"

# 查看日誌
ssh -i app/temp/yolo-spot-key.pem ubuntu@<IP> "sudo journalctl -u yolo-bot.service -f"
```

---

## ⚙️ 設定參考

### MQTT Topics
- `servo/arm2/ik` - IK 控制（格式: "IK x y z rx ry rz"）
- `servo/arm2/clm` - 夾爪控制（格式: "clm <0-180>"）
- `servo/arm2/a-f` - 直接馬達控制（格式: {"angle": 90}）
- `servo/arm2/cmd` - 遠端指令（zero/reset/pause/resume/stop）

### LiveKit
- URL: `wss://test-wfkuoo8g.livekit.cloud`
- Room: `my-room`
- Token API: `https://roger01.site/get-livekit-token`

---

## 📚 文檔參考

- `app/temp/PATCH_NOTE.md` - Bug 修正說明
- `app/temp/HANDOVER_COMPLETE.md` - 系統交接文檔
- `app/lib/ui/motor_control_page *.dart` - 多個備份版本

---

**Last Updated:** 2025-11-19
**License:** MIT
**Status:** Active Development
