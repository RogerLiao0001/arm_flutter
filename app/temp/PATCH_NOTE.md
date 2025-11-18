# Bug Fix Patch - 框圖自動清除

**日期：** 2025-11-13
**狀態：** 已修正，待部署

---

## 🐛 最大 Bug：框圖不會自動清除

### 問題描述：
1. 偵測到物件後，如果下一幀沒有偵測到，框框會永遠留在畫面上
2. 翻轉或滾動螢幕後，框圖位置可能跑到畫面外
3. 框框會一直顯示，即使物件已經消失很久

### 解決方案：

**自動清除機制：**
- 每 500ms 檢查一次最後收到偵測資料的時間
- 如果超過 3 秒沒有收到新的偵測資料，自動清除框圖
- 可調整的超時時間：`DETECTION_TIMEOUT = 3000` (毫秒)

**修改的檔案：**
1. `ai_viewer_patch.html` - Viewer 端修正版
2. `ai_publisher_patch.html` - Publisher 端修正版

### 修改內容：

**新增變數：**
```javascript
let lastDetectionTime = 0;  // 最後收到偵測的時間
const DETECTION_TIMEOUT = 3000;  // 3秒沒偵測就清除 (可調整)
```

**更新時間戳記（收到資料時）：**
```javascript
if (Array.isArray(data)) {
    yoloData = data;
    lastDetectionTime = Date.now();  // 記錄時間
    drawBoxes(yoloData);
}
```

**定期檢查並清除：**
```javascript
setInterval(() => {
    if (yoloData && lastDetectionTime > 0) {
        const elapsed = Date.now() - lastDetectionTime;
        if (elapsed > DETECTION_TIMEOUT) {
            console.log('⏱️ 超過3秒沒偵測，清除框圖');
            yoloData = null;
            ctx.clearRect(0, 0, overlayCanvas.width, overlayCanvas.height);
        }
    }
}, 500);  // 每 500ms 檢查一次
```

---

## 📋 部署步驟（下次開機時）

1. **上傳修正檔案：**
```bash
scp temp/ai_viewer_patch.html root@178.128.54.195:/var/www/html/roger01.site/ai_viewer.html
scp temp/ai_publisher_patch.html root@178.128.54.195:/var/www/html/roger01.site/ai_publisher.html
```

2. **測試：**
- 開啟 Publisher 和 Viewer
- 讓物件進入畫面（出現框圖）
- 移開物件
- 確認 3 秒後框圖自動消失

---

## 🔮 其他功能構想（未實作）

### 1. 信心門檻值網頁端設定

**需求：**
- 在網頁上調整 confidence threshold (目前固定 0.15)
- 需要修改 Bot API 接收門檻值參數

**實作構想：**
```javascript
// Publisher 端添加滑桿
<input type="range" id="confidence-slider" min="0.05" max="0.95" step="0.05" value="0.15">

// 發送到 Bot
room.localParticipant.publishData(JSON.stringify({
    type: 'setConfidence',
    value: 0.15
}));
```

**Bot 端修改：**
```python
# ai_bot.py
async def on_data_received(self, data: bytes, participant):
    message = json.loads(data.decode('utf-8'))
    if msg_type == 'setConfidence':
        self.confidence_threshold = message.get('value', 0.15)

# 使用
results = self.current_model.predict(arr, conf=self.confidence_threshold)
```

### 2. 接收端更大控制

**可能功能：**
- 暫停/恢復串流
- 切換全螢幕
- 截圖功能
- FPS 顯示

### 3. Video Quality 網頁端可更改

**問題：** 目前 `setVideoQuality` 函數不適用

**可能解決方案：**
- 使用 LiveKit 的 `setVideoDimensions()`
- 或在 Publisher 端切換 resolution
- 目前 adaptive streaming 會自動調整，可能不需要手動控制

---

## 🧪 測試建議

測試框圖自動清除：
1. 拿訓練過的物件進入畫面
2. 確認出現框圖（綠色/橘色）
3. 移開物件
4. 計時，確認 3 秒後框圖消失
5. 測試翻轉螢幕（手機）
6. 測試調整視窗大小（電腦）

---

## 📝 調整參數

如果覺得 3 秒太快或太慢，修改這個值：
```javascript
const DETECTION_TIMEOUT = 3000;  // 改成 5000 = 5秒，2000 = 2秒
```

建議值：
- 快速響應：2000ms (2秒)
- 平衡：3000ms (3秒) ← 目前設定
- 保留久一點：5000ms (5秒)
