#include <ESP8266WiFi.h>
#include <PubSubClient.h>
#include <Servo.h>
#include <ArduinoJson.h>
#include <WiFiManager.h>

// 定義 8 個伺服馬達連接腳位（依 NodeMCU 引腳編號）  
#define SERVO1_PIN 14  // D5 (GPIO14)
#define SERVO2_PIN 12  // D6 (GPIO12)
#define SERVO3_PIN 13  // D7 (GPIO13)
#define SERVO4_PIN 15  // D8 (GPIO15)
#define SERVO5_PIN 5   // D1 (GPIO5) 
#define SERVO6_PIN 4   // D2 (GPIO4)
#define SERVO7_PIN 16  // D0 (GPIO16)
#define SERVO8_PIN 2   // D4 (GPIO2)

// 8 個 Servo 物件
Servo servo1, servo2, servo3, servo4, servo5, servo6, servo7, servo8;

// MQTT 伺服器資訊
const char* mqtt_server = "178.128.54.195";
const int mqtt_port = 1883;
const char* mqtt_topic = "servo/#";

WiFiClient espClient;
PubSubClient client(espClient);
WiFiManager wifiManager;

bool motorsAttached = false;      // 用於標記馬達是否 attach
int mqttFailCount = 0;           // MQTT 連線失敗次數
const int maxFailCount = 2;      // 超過 2 次失敗就重啟
const int retryDelay = 2000;     // 失敗後等 2 秒

// --------------------------------------------------------
// 當接收到 MQTT 訊息時的回呼函式
// --------------------------------------------------------
void callback(char* topic, byte* payload, unsigned int length) {
  Serial.print("收到 MQTT 訊息，主題: ");
  Serial.println(topic);

  char jsonBuffer[200];
  if (length >= sizeof(jsonBuffer)) length = sizeof(jsonBuffer) - 1;
  memcpy(jsonBuffer, payload, length);
  jsonBuffer[length] = '\0';

  StaticJsonDocument<256> doc;
  DeserializationError error = deserializeJson(doc, jsonBuffer);
  if (error) {
    Serial.print("JSON 解析失敗: ");
    Serial.println(error.f_str());
    return;
  }

  int id = doc["id"];
  float angle = doc["angle"];
  Serial.printf("設定馬達 %d 角度為: %.1f\n", id, angle);

  if (!motorsAttached) {
    Serial.println("警告: 馬達尚未 attach，忽略此命令。");
    return;
  }

  switch (id) {
    case 1:  servo1.write(angle); break;
    case 2:  servo2.write(angle); break;
    case 3:  servo3.write(angle); break;
    case 4:  servo4.write(angle); break;
    case 5:  servo5.write(angle); break;
    case 6:  servo6.write(angle); break;
    case 7:  servo7.write(angle); break;
    case 8:  servo8.write(angle); break;
    default:
      Serial.println("錯誤: 無效的馬達 ID");
  }
}

// --------------------------------------------------------
// 強制重啟 WiFiManager 配置
// --------------------------------------------------------
void forceWiFiManager() {
  Serial.println("=== 強制重啟 WiFiManager 配置 ===");
  wifiManager.resetSettings(); // 清除先前 WiFi 記憶
  ESP.restart();
}

// --------------------------------------------------------
// MQTT 連線
// --------------------------------------------------------
void reconnect() {
  while (!client.connected()) {
    Serial.println("嘗試重新連線 MQTT...");
    if (client.connect("ESP8266Client")) {
      Serial.println("MQTT 連線成功！");
      client.subscribe(mqtt_topic);
      mqttFailCount = 0; // 成功則歸零
    } else {
      mqttFailCount++;
      Serial.print("MQTT 連線失敗, rc=");
      Serial.print(client.state());
      Serial.print(", 第 ");
      Serial.print(mqttFailCount);
      Serial.println(" 次失敗");
      if (mqttFailCount >= maxFailCount) {
        Serial.println("超過最大失敗次數，進入 WiFiManager 配置");
        forceWiFiManager();
      }
      delay(retryDelay);
    }
  }
}

// --------------------------------------------------------
// Attach 所有馬達，並歸中 (90°)
// --------------------------------------------------------
void attachAllMotors() {
  // 設定脈衝範圍，避免亂轉
  servo1.attach(SERVO1_PIN, 500, 2400);
  servo2.attach(SERVO2_PIN, 500, 2400);
  servo3.attach(SERVO3_PIN, 500, 2400);
  servo4.attach(SERVO4_PIN, 500, 2400);
  servo5.attach(SERVO5_PIN, 500, 2400);
  servo6.attach(SERVO6_PIN, 500, 2400);
  servo7.attach(SERVO7_PIN, 500, 2400);
  servo8.attach(SERVO8_PIN, 500, 2400);

  servo1.write(90);
  servo2.write(90);
  servo3.write(90);
  servo4.write(90);
  servo5.write(90);
  servo6.write(90);
  servo7.write(90);
  servo8.write(90);

  motorsAttached = true;
  Serial.println("所有伺服馬達已 attach 並設為 90°");
}

// --------------------------------------------------------
// Arduino Setup
// --------------------------------------------------------
void setup() {
  Serial.begin(115200);
  Serial.println();

  // 先 detach 所有馬達，避免上電瞬間亂動
  servo1.detach();
  servo2.detach();
  servo3.detach();
  servo4.detach();
  servo5.detach();
  servo6.detach();
  servo7.detach();
  servo8.detach();
  motorsAttached = false;

  wifiManager.setDebugOutput(true);

  // 自動建立 AP，AP 名稱 "ESP8266-Setup"
  if (!wifiManager.autoConnect("ESP8266-Setup")) {
    Serial.println("WiFi 連線失敗或逾時, 系統重啟...");
    ESP.restart();
  }

  Serial.println("WiFi 已連接");
  Serial.print("IP 位址: ");
  Serial.println(WiFi.localIP());

  // 設定 MQTT 伺服器資訊
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);

  // 此時 WiFi 已就緒，再 attach 馬達
  attachAllMotors();

  Serial.println("=== Setup 完成, 進入主迴圈 ===");
}

// --------------------------------------------------------
// Arduino Loop
// --------------------------------------------------------
void loop() {
  if (!client.connected()) {
    reconnect();
  }
  client.loop();

  // 若馬達亂動仍發生，可考慮在此檢查 WiFi 或 MQTT 狀態
  // 也可根據其他條件 detach/attach
}
