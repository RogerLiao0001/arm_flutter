#include <ESP8266WiFi.h>
#include <WiFiManager.h>      // https://github.com/tzapu/WiFiManager
#include <PubSubClient.h>
#include <Servo.h>
#include <ArduinoJson.h>      // For MQTT JSON parsing (v6+)
#include <ESP8266WebServer.h> // For Offline Mode Web Server
#include <DNSServer.h>        // For Captive Portal in Offline Mode

// --- 腳位定義 ---
// --- Arm 1 (直接控制) ---
#define SERVO1_PIN 5    // GPIO5 (NodeMCU D1) - Arm 1 Servo 1
#define SERVO2_PIN 4    // GPIO4 (NodeMCU D2) - Arm 1 Servo 2
#define SERVO3_PIN 14   // GPIO14 (NodeMCU D5) - Arm 1 Servo 3
#define SERVO4_PIN 12   // GPIO12 (NodeMCU D6) - Arm 1 Servo 4
#define SERVO5_PIN 13   // GPIO13 (NodeMCU D7) - Arm 1 Servo 5
#define ELECTROMAGNET_PIN 16 // GPIO16 (NodeMCU D0) - Arm 1 Electromagnet

// --- 模式切換 (取代按鈕) ---
// 開機時: 接 GND -> Offline Mode | 懸空 -> Online Mode
#define MODE_SWITCH_PIN 15   // GPIO15 (NodeMCU D8) - Mode Select Pin

// --- Arm 2 (Serial 數據線輸出) ---
// Serial1 預設使用 GPIO2 (D4) 作為 TX

Servo servo1;
Servo servo2;
Servo servo3;
Servo servo4;
Servo servo5;

// --- 模式選擇 ---
enum OperatingMode {
  ONLINE_MODE,
  OFFLINE_MODE
};
OperatingMode currentMode;

// --- Online Mode (MQTT) 變數 ---
WiFiManager wifiManager;
WiFiClient espClient;
PubSubClient client(espClient);
const char* mqtt_server = "178.128.54.195";
const int mqtt_port = 1883;
const char* mqtt_arm1_servo_base_topic = "servo/";
const char* mqtt_arm1_electromagnet_topic = "electromagnet";
const char* mqtt_arm2_base_topic = "arm2/#";

// --- Offline Mode (AP + Web Server + DNS) 變數 ---
const char* ap_ssid = "ESP8266_DualArm_Control";
// const char* ap_password = "password123"; // 密碼已移除
ESP8266WebServer server(80);
DNSServer dnsServer; // DNS 伺服器物件
String currentPage = "arm1";

// --- 伺服馬達初始角度 ---
const int INITIAL_ANGLE = 90;

// --- Serial 通訊速率 (與 Arm 2 接收端需一致) ---
const long ARM2_SERIAL_BAUDRATE = 9600;

// --- JSON 文件建議大小 ---
const size_t JSON_DOC_SIZE = 192;

// ======================================================
//  Web Server HTML 頁面產生函式 (Offline Mode)
// ======================================================
String buildHtmlPage(String page) {
  // HTML 內容與上一版完全相同，此處省略以節省空間...
  // 確保上一版的 buildHtmlPage 函數內容複製到這裡
  String html = "<!DOCTYPE html><html lang='zh-TW'><head><meta charset='UTF-8'><meta name='viewport' content='width=device-width, initial-scale=1.0'>";
  html += "<title>ESP8266 機械手臂控制 - 手臂 ";
  html += (page == "arm2" ? "2" : "1");
  html += "</title>";
  html += "<style>";
  html += "body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f0f2f5; color: #333; max-width: 450px; margin: 15px auto; padding: 20px; border: 1px solid #d9d9d9; border-radius: 10px; box-shadow: 0 4px 8px rgba(0,0,0,0.1); }";
  html += "h1 { text-align: center; color: #1877f2; margin-bottom: 10px; }";
  html += ".nav { text-align: center; margin-bottom: 25px; padding-bottom: 15px; border-bottom: 1px solid #e0e0e0;}";
  html += ".nav a, .nav span { display: inline-block; margin: 0 10px; padding: 8px 15px; text-decoration: none; color: #fff; background-color: #6c757d; border-radius: 5px; transition: background-color 0.3s ease; font-weight: bold;}";
  html += ".nav a:hover { background-color: #5a6268; }";
  html += ".nav span { background-color: #007bff; }";
  html += ".control-group { margin-bottom: 25px; padding: 15px; background-color: #fff; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.05); }";
  html += "label { display: block; margin-bottom: 8px; font-weight: 600; color: #555; }";
  html += "input[type=range] { width: calc(100% - 55px); height: 8px; cursor: pointer; vertical-align: middle; background: linear-gradient(to right, #007bff 0%, #007bff var(--value-percent, 50%), #dee2e6 var(--value-percent, 50%), #dee2e6 100%); -webkit-appearance: none; appearance: none; border-radius: 5px; outline: none;}";
  html += "input[type=range]::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 20px; height: 20px; background: #007bff; border-radius: 50%; cursor: pointer; }";
  html += "input[type=range]::-moz-range-thumb { width: 20px; height: 20px; background: #007bff; border-radius: 50%; cursor: pointer; border: none; }";
  html += ".angle-display { display: inline-block; margin-left: 10px; font-weight: bold; color: #007bff; min-width: 35px; text-align: right; font-size: 1.1em; vertical-align: middle;}";
  html += "button.toggle-btn { background-color: #dc3545; color: white; padding: 10px 20px; border: none; border-radius: 5px; cursor: pointer; font-size: 1em; font-weight: bold; transition: background-color 0.3s ease; width: 100%; }";
  html += "button.toggle-btn.on { background-color: #28a745; }";
  html += "button.toggle-btn:hover { opacity: 0.9; }";
  html += "</style>";
  html += "</head><body>";
  html += "<h1>ESP8266 機械手臂控制</h1>";

  // Navigation
  html += "<div class='nav'>";
  if (page == "arm1") {
      html += "<span>控制手臂 1</span>";
      html += "<a href='/?page=arm2'>控制手臂 2</a>";
  } else { // page == "arm2"
      html += "<a href='/?page=arm1'>控制手臂 1</a>";
      html += "<span>控制手臂 2</span>";
  }
  html += "</div>";

  // Content Area
  if (page == "arm1") {
      for (int i = 1; i <= 5; i++) {
          html += "<div class='control-group'>";
          html += "<label for='arm1_servo" + String(i) + "'>手臂 1 - 馬達 " + String(i) + ": <span class='angle-display' id='arm1_angle" + String(i) + "'>" + String(INITIAL_ANGLE) + "</span>°</label>";
          html += "<input type='range' id='arm1_servo" + String(i) + "' min='0' max='180' value='" + String(INITIAL_ANGLE) + "' oninput='updateArm1Servo(" + String(i) + ", this.value)' style='--value-percent:" + String(INITIAL_ANGLE*100/180) + "%;'>";
          html += "</div>";
      }
      html += "<div class='control-group'>";
      html += "<label for='magnetBtn'>手臂 1 - 電磁鐵:</label>";
      html += "<button id='magnetBtn' class='toggle-btn' onclick='toggleArm1Magnet()'>開啟電磁鐵</button>";
      html += "</div>";
  } else { // page == "arm2"
      for (int i = 1; i <= 6; i++) {
          html += "<div class='control-group'>";
          String motorLabel = (i <= 3) ? "伺服馬達" : "步進馬達";
          int displayId = (i <= 3) ? i : i - 3;
          html += "<label for='arm2_motor" + String(i) + "'>手臂 2 - " + motorLabel + " " + String(displayId) + ": <span class='angle-display' id='arm2_angle" + String(i) + "'>" + String(INITIAL_ANGLE) + "</span>°</label>";
          html += "<input type='range' id='arm2_motor" + String(i) + "' min='0' max='180' value='" + String(INITIAL_ANGLE) + "' oninput='updateArm2Motor(" + String(i) + ", this.value)' style='--value-percent:" + String(INITIAL_ANGLE*100/180) + "%;'>";
          html += "</div>";
      }
  }

  // JavaScript
  html += "<script>";
  html += "function updateSliderFill(slider) { const percentage = (slider.value - slider.min) / (slider.max - slider.min) * 100; slider.style.setProperty('--value-percent', percentage + '%'); }";
  html += "function updateArm1Servo(id, angle) {";
  html += "  document.getElementById('arm1_angle' + id).innerText = angle;";
  html += "  const slider = document.getElementById('arm1_servo' + id); updateSliderFill(slider);";
  html += "  fetch('/setServo?id=' + id + '&angle=' + angle).catch(err => console.error('Fetch error:', err));";
  html += "}";
  html += "let magnetState = false;";
  html += "function toggleArm1Magnet() {";
  html += "  magnetState = !magnetState;";
  html += "  const btn = document.getElementById('magnetBtn');";
  html += "  const command = magnetState ? 'ON' : 'OFF';";
  html += "  fetch('/setMagnet?state=' + command).catch(err => console.error('Fetch error:', err));";
  html += "  if (magnetState) { btn.innerText = '關閉電磁鐵'; btn.classList.add('on'); }";
  html += "  else { btn.innerText = '開啟電磁鐵'; btn.classList.remove('on'); }";
  html += "}";
  html += "function updateArm2Motor(id, angle) {";
  html += "  document.getElementById('arm2_angle' + id).innerText = angle;";
  html += "  const slider = document.getElementById('arm2_motor' + id); updateSliderFill(slider);";
  html += "  fetch('/setArm2Motor?id=' + id + '&angle=' + angle).catch(err => console.error('Fetch error:', err));";
  html += "}";
  html += "window.addEventListener('load', () => { document.querySelectorAll('input[type=range]').forEach(updateSliderFill); });";
  html += "</script>";
  html += "</body></html>";
  return html;
}

// ======================================================
//  Web Server Request Handlers (Offline Mode)
// ======================================================
// handleRoot, handleSetArm1Servo, handleSetArm1Magnet, handleSetArm2Motor
// 函數內容與上一版完全相同，此處省略...
void handleRoot() {
  if (server.hasArg("page")) {
    currentPage = server.arg("page");
    if (currentPage != "arm1" && currentPage != "arm2") { currentPage = "arm1"; }
  }
  server.send(200, "text/html", buildHtmlPage(currentPage));
}

void handleSetArm1Servo() {
  if (server.hasArg("id") && server.hasArg("angle")) {
    int servoId = server.arg("id").toInt();
    int angle = server.arg("angle").toInt();
    angle = constrain(angle, 0, 180);
    Serial.printf("[Web] Arm 1 Servo: ID=%d, Angle=%d\n", servoId, angle);
    switch (servoId) {
      case 1: servo1.write(angle); break; case 2: servo2.write(angle); break;
      case 3: servo3.write(angle); break; case 4: servo4.write(angle); break;
      case 5: servo5.write(angle); break; default:
        Serial.println("Invalid Arm 1 servo ID"); server.send(400, "text/plain", "Bad ID"); return;
    }
    server.send(200, "text/plain", "OK");
  } else { server.send(400, "text/plain", "Bad Request"); }
}

void handleSetArm1Magnet() {
  if (server.hasArg("state")) {
    String state = server.arg("state");
    Serial.printf("[Web] Arm 1 Magnet: State=%s\n", state.c_str());
    if (state.equalsIgnoreCase("ON")) { digitalWrite(ELECTROMAGNET_PIN, HIGH); server.send(200, "text/plain", "OK"); }
    else if (state.equalsIgnoreCase("OFF")) { digitalWrite(ELECTROMAGNET_PIN, LOW); server.send(200, "text/plain", "OK"); }
    else { server.send(400, "text/plain", "Bad State"); }
  } else { server.send(400, "text/plain", "Bad Request"); }
}

void handleSetArm2Motor() {
  if (server.hasArg("id") && server.hasArg("angle")) {
      int motorId = server.arg("id").toInt();
      int angle = server.arg("angle").toInt();
      angle = constrain(angle, 0, 180);
      Serial.printf("[Web] Arm 2 Motor: ID=%d, Angle=%d -> Serial\n", motorId, angle);
      if (motorId >= 1 && motorId <= 6) {
          String serialCommand = String(motorId) + ":" + String(angle);
          Serial1.println(serialCommand); // Send via Serial1 (GPIO2/D4 TX)
          Serial.print("Sent to Arm 2 via Serial1: "); Serial.println(serialCommand);
          server.send(200, "text/plain", "OK");
      } else {
          Serial.println("Invalid Arm 2 motor ID"); server.send(400, "text/plain", "Bad ID"); return;
      }
  } else { server.send(400, "text/plain", "Bad Request"); }
}


// ======================================================
//  MQTT Callback (Online Mode)
// ======================================================
// callback 函數內容與上一版完全相同，此處省略...
void callback(char* topic, byte* payload, unsigned int length) {
  String message;
  for (unsigned int i = 0; i < length; i++) { message += (char)payload[i]; }
  String topicStr = String(topic);

  Serial.print("MQTT Received ["); Serial.print(topicStr); Serial.print("]: "); Serial.println(message);

  // --- Arm 1 Commands ---
  if (topicStr.startsWith(mqtt_arm1_servo_base_topic)) {
      DynamicJsonDocument doc(JSON_DOC_SIZE);
      DeserializationError error = deserializeJson(doc, message);
      int servoId = -1; int angle = -1;
      if (!error && doc.containsKey("id") && doc.containsKey("angle")) {
          servoId = doc["id"]; angle = doc["angle"]; angle = constrain(angle, 0, 180);
          Serial.printf("Processing Arm 1 Servo (JSON): ID=%d, Angle=%d\n", servoId, angle);
      } else {
          Serial.printf("JSON parsing failed for Arm 1 servo [%s]. Fallback...\n", error.c_str());
          String servoIdStr = topicStr.substring(strlen(mqtt_arm1_servo_base_topic));
          servoId = servoIdStr.toInt(); angle = message.toInt(); angle = constrain(angle, 0, 180);
          if (servoId >= 1 && servoId <= 5) {
              Serial.printf("Processing Arm 1 Servo (Fallback): ID=%d, Angle=%d\n", servoId, angle);
          } else { Serial.println("Invalid Servo ID in fallback."); return; }
      }
      switch (servoId) {
          case 1: servo1.write(angle); break; case 2: servo2.write(angle); break;
          case 3: servo3.write(angle); break; case 4: servo4.write(angle); break;
          case 5: servo5.write(angle); break; default: Serial.printf("Unknown Arm 1 servo ID: %d\n", servoId); break;
      }
  } else if (topicStr.equals(mqtt_arm1_electromagnet_topic)) {
      Serial.print("Processing Arm 1 Electromagnet: ");
      if (message.equalsIgnoreCase("ON")) { digitalWrite(ELECTROMAGNET_PIN, HIGH); Serial.println("ON"); }
      else if (message.equalsIgnoreCase("OFF")) { digitalWrite(ELECTROMAGNET_PIN, LOW); Serial.println("OFF"); }
      else { Serial.println("Unknown command"); }
  }
  // --- Arm 2 Commands ---
  else if (topicStr.startsWith("arm2/")) {
      int secondSlash = topicStr.indexOf('/', 5);
      if (secondSlash == -1 || topicStr.indexOf('/', secondSlash + 1) != -1) {
          Serial.println("Invalid Arm 2 topic structure"); return;
      }
      String motorType = topicStr.substring(5, secondSlash);
      String motorIdStr = topicStr.substring(secondSlash + 1);
      int typeSpecificId = motorIdStr.toInt();
      int serialId = -1;

      if (motorType.equals("servo") && typeSpecificId >= 1 && typeSpecificId <= 3) { serialId = typeSpecificId; }
      else if (motorType.equals("stepper") && typeSpecificId >= 1 && typeSpecificId <= 3) { serialId = typeSpecificId + 3; }
      else { Serial.println("Invalid motor type or type-specific ID for Arm 2"); return; }

      DynamicJsonDocument doc(JSON_DOC_SIZE);
      DeserializationError error = deserializeJson(doc, message);
      if (error || !doc.containsKey("angle")) {
          Serial.printf("JSON parsing failed or missing 'angle' for Arm 2 [%s]\n", error.c_str()); return;
      }
      int angle = doc["angle"];
      angle = constrain(angle, 0, 180);

      Serial.printf("Processing Arm 2: Type=%s, TypeID=%d -> SerialID=%d, Angle=%d\n",
                    motorType.c_str(), typeSpecificId, serialId, angle);

      String serialCommand = String(serialId) + ":" + String(angle);
      Serial1.println(serialCommand);
      Serial.print("Sent to Arm 2 via Serial1: "); Serial.println(serialCommand);
  }
  else { Serial.println("Unrecognized topic"); }
}

// ======================================================
//  MQTT Reconnect Logic (Online Mode)
// ======================================================
// reconnect 函數內容與上一版完全相同，此處省略...
void reconnect() {
  while (!client.connected()) {
    Serial.print("Attempting MQTT connection...");
    String clientId = "ESP8266DualArmClient-"; clientId += String(random(0xffff), HEX);
    if (client.connect(clientId.c_str())) {
      Serial.println(" connected");
      String arm1_subscribe_topic = String(mqtt_arm1_servo_base_topic) + "#";
      client.subscribe(arm1_subscribe_topic.c_str());
      client.subscribe(mqtt_arm1_electromagnet_topic);
      Serial.print("Subscribed to Arm 1: "); Serial.print(arm1_subscribe_topic); Serial.print(" and "); Serial.println(mqtt_arm1_electromagnet_topic);
      client.subscribe(mqtt_arm2_base_topic);
      Serial.print("Subscribed to Arm 2: "); Serial.println(mqtt_arm2_base_topic);
    } else {
      Serial.print(" failed, rc="); Serial.print(client.state()); Serial.println(" try again in 5 seconds");
      delay(5000);
    }
  }
}


// ======================================================
//  Setup Functions per Mode
// ======================================================

void setupOnlineMode() {
  Serial.println("Setting up Online Mode (STA + MQTT)...");
  wifiManager.setConnectTimeout(60);
  // wifiManager.resetSettings(); // 取消註解以強制重設 WiFi 設定
  if (!wifiManager.autoConnect("ESP8266_Arm_Setup")) {
      Serial.println("Failed WiFi connection -> Restarting..."); delay(3000); ESP.restart(); delay(5000);
  }
  Serial.println("\nConnected to WiFi!"); Serial.print("IP Address: "); Serial.println(WiFi.localIP());
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);
}

void setupOfflineMode() {
  Serial.println("Setting up Offline Mode (AP + Web Server + DNS)...");
  // --- 設定為 AP 模式，不使用密碼 ---
  WiFi.mode(WIFI_AP);
  if (WiFi.softAP(ap_ssid)) { // 移除密碼參數
      Serial.println("\nAP Mode Active! Network is OPEN."); // 提醒網路是開放的
      Serial.print("SSID: "); Serial.println(ap_ssid);
      IPAddress myIP = WiFi.softAPIP();
      Serial.print("AP IP address: "); Serial.println(myIP);

      // --- 啟動 DNS 伺服器 ---
      // 將所有域名請求指向本機 IP
      if (dnsServer.start(53, "*", myIP)) {
          Serial.println("DNS Server started.");
      } else {
          Serial.println("Failed to start DNS Server!");
      }

      // --- Web Server Routes ---
      server.on("/", HTTP_GET, handleRoot);
      server.on("/setServo", HTTP_GET, handleSetArm1Servo);
      server.on("/setMagnet", HTTP_GET, handleSetArm1Magnet);
      server.on("/setArm2Motor", HTTP_GET, handleSetArm2Motor);
      // --- Captive Portal Handling ---
      // 將所有其他請求 (例如 /generate_204, /fwlink 等) 導向根目錄
      server.onNotFound([]() {
          Serial.println("Handling not found (Captive Portal check?) -> Redirecting to root.");
          handleRoot(); // 顯示主控制頁面
          // 或者可以用 server.sendHeader("Location", "/", true); server.send(302, "text/plain", ""); 來做重定向
      });
      server.begin(); // 啟動 Web Server
      Serial.println("Web Server started.");
      Serial.println("Connect to the OPEN WiFi network and the control page should pop up.");

  } else {
      Serial.println("Failed to start AP!");
      // 可以考慮重啟或進入錯誤狀態
  }
}

// ======================================================
//  Main Setup
// ======================================================
void setup() {
  Serial.begin(115200);
  Serial.println("\n\nESP8266 Dual Robot Arm Controller v2.2 Booting..."); // Version bump
  delay(1000);

  // --- 初始化 Serial1 (始終需要) ---
  Serial1.begin(ARM2_SERIAL_BAUDRATE);
  Serial.print("Serial1 (GPIO2 TX) for Arm 2 started at "); Serial.print(ARM2_SERIAL_BAUDRATE); Serial.println(" bps.");

  // --- 初始化模式切換腳位 ---
  pinMode(MODE_SWITCH_PIN, INPUT_PULLUP);
  Serial.print("Reading Mode Switch Pin (D8/GPIO15)... "); delay(100);

  // --- 初始化 Arm 1 硬體 ---
  servo1.attach(SERVO1_PIN); servo2.attach(SERVO2_PIN); servo3.attach(SERVO3_PIN);
  servo4.attach(SERVO4_PIN); servo5.attach(SERVO5_PIN);
  servo1.write(INITIAL_ANGLE); servo2.write(INITIAL_ANGLE); servo3.write(INITIAL_ANGLE);
  servo4.write(INITIAL_ANGLE); servo5.write(INITIAL_ANGLE);
  pinMode(ELECTROMAGNET_PIN, OUTPUT); digitalWrite(ELECTROMAGNET_PIN, LOW);
  Serial.println("Arm 1 Hardware Initialized.");

  // --- 決定模式 ---
  if (digitalRead(MODE_SWITCH_PIN) == LOW) {
    currentMode = OFFLINE_MODE; Serial.println("Result: LOW -> Entering OFFLINE Mode");
  } else {
    currentMode = ONLINE_MODE; Serial.println("Result: HIGH -> Entering ONLINE Mode");
  }
  Serial.println("-----------------------------------------");

  // --- 執行模式特定設定 ---
  if (currentMode == ONLINE_MODE) setupOnlineMode();
  else setupOfflineMode();

  Serial.println("-----------------------------------------");
  Serial.println("Setup complete.");
}

// ======================================================
//  Main Loop
// ======================================================
void loop() {
  if (currentMode == ONLINE_MODE) {
    if (!client.connected()) reconnect();
    client.loop();
  } else { // OFFLINE_MODE
    dnsServer.processNextRequest(); // 處理 DNS 請求 (for Captive Portal)
    server.handleClient();          // 處理 HTTP 請求
  }
  // yield(); // 通常不需要，除非有長時間阻塞的操作
}