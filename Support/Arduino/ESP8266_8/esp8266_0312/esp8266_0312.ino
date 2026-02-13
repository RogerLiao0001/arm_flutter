#include <ESP8266WiFi.h>
#include <WiFiManager.h>  // https://github.com/tzapu/WiFiManager
#include <PubSubClient.h>
#include <Servo.h>
#include <ArduinoJson.h>  // 加入 ArduinoJson 庫

// --- 腳位定義 ---
// 依據 NodeMCU 的實際 GPIO 數字設定：
#define SERVO1_PIN 5    // GPIO5 (NodeMCU D1)
#define SERVO2_PIN 4    // GPIO4 (NodeMCU D2)
#define SERVO3_PIN 14   // GPIO14 (NodeMCU D5)
#define SERVO4_PIN 12   // GPIO12 (NodeMCU D6)
#define SERVO5_PIN 13   // GPIO13 (NodeMCU D7)
#define ELECTROMAGNET_PIN 16 // GPIO16 (NodeMCU D0)

Servo servo1;
Servo servo2;
Servo servo3;
Servo servo4;
Servo servo5;

WiFiManager wifiManager;
WiFiClient espClient;
PubSubClient client(espClient);

// MQTT Broker 設定
const char* mqtt_server = "178.128.54.195";
const int mqtt_port = 1883;

// --- MQTT 訊息處理回呼 ---
void callback(char* topic, byte* payload, unsigned int length) {
  // 將 payload 轉換成 String
  String message;
  for (unsigned int i = 0; i < length; i++) {
    message += (char)payload[i];
  }
  
  Serial.print("Received [");
  Serial.print(topic);
  Serial.print("]: ");
  Serial.println(message);
  
  // 如果訊息是 JSON 格式（以 '{' 開頭），則解析 JSON
  if (message.startsWith("{")) {
    // 預留足夠空間給兩個鍵值
    const size_t capacity = JSON_OBJECT_SIZE(2) + 60;
    DynamicJsonDocument doc(capacity);
    DeserializationError error = deserializeJson(doc, message);
    if (error) {
      Serial.print("JSON 解析失敗: ");
      Serial.println(error.f_str());
      return;
    }
    int servoId = doc["id"];           // 從 JSON 中取得 id
    float angleF = doc["angle"];         // 從 JSON 中取得 angle（浮點數）
    int angle = (int)angleF;             // 轉換成整數
    switch (servoId) {
      case 1:
        servo1.write(angle);
        Serial.print("Set Servo 1 to ");
        Serial.println(angle);
        break;
      case 2:
        servo2.write(angle);
        Serial.print("Set Servo 2 to ");
        Serial.println(angle);
        break;
      case 3:
        servo3.write(angle);
        Serial.print("Set Servo 3 to ");
        Serial.println(angle);
        break;
      case 4:
        servo4.write(angle);
        Serial.print("Set Servo 4 to ");
        Serial.println(angle);
        break;
      case 5:
        servo5.write(angle);
        Serial.print("Set Servo 5 to ");
        Serial.println(angle);
        break;
      default:
        Serial.print("未知的 servo id: ");
        Serial.println(servoId);
        break;
    }
  }
  // 如果訊息非 JSON 格式，可能是電磁鐵控制命令 "ON"/"OFF"
  else {
    String topicStr = String(topic);
    if (topicStr.indexOf("electromagnet") >= 0) {
      if (message.equalsIgnoreCase("ON")) {
        digitalWrite(ELECTROMAGNET_PIN, HIGH);
        Serial.println("Electromagnet turned ON");
      } else if (message.equalsIgnoreCase("OFF")) {
        digitalWrite(ELECTROMAGNET_PIN, LOW);
        Serial.println("Electromagnet turned OFF");
      }
    } else {
      Serial.println("Unrecognized message format");
    }
  }
}

// --- 重新連線 MQTT ---
void reconnect() {
  while (!client.connected()) {
    Serial.print("Attempting MQTT connection...");
    String clientId = "ESP8266Client-";
    clientId += String(random(0xffff), HEX);
    if (client.connect(clientId.c_str())) {
      Serial.println(" connected");
      client.subscribe("servo/#");
    } else {
      Serial.print(" failed, rc=");
      Serial.print(client.state());
      Serial.println(" try again in 5 seconds");
      delay(5000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  
  // --- 伺服馬達初始化 ---
  servo1.attach(SERVO1_PIN);
  servo2.attach(SERVO2_PIN);
  servo3.attach(SERVO3_PIN);
  servo4.attach(SERVO4_PIN);
  servo5.attach(SERVO5_PIN);
  
  // 設定初始角度為 90 度
  servo1.write(90);
  servo2.write(90);
  servo3.write(90);
  servo4.write(90);
  servo5.write(90);
  
  // --- 電磁帖控制腳位初始化 ---
  pinMode(ELECTROMAGNET_PIN, OUTPUT);
  digitalWrite(ELECTROMAGNET_PIN, LOW); // 初始關閉
  
  // --- WiFiManager 連線 ---
  wifiManager.autoConnect("ESP8266_AP");
  Serial.println("Connected to WiFi");
  
  // --- MQTT 初始化 ---
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);
  
  reconnect();
}

void loop() {
  if (!client.connected()) {
    reconnect();
  }
  client.loop();
}
