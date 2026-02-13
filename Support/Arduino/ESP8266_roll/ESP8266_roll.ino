#include <ESP8266WiFi.h>
#include <WiFiManager.h>      // https://github.com/tzapu/WiFiManager
#include <PubSubClient.h>
#include <Servo.h>
#include <ESP8266WebServer.h> // For Offline Mode Web Server
#include <DNSServer.h>        // For Captive Portal in Offline Mode
#include <Wire.h>

// --- 腳位定義 ---
#define SERVO1_PIN 2
#define SERVO2_PIN 16
#define SERVO3_PIN 14
#define SERVO4_PIN 12
#define SERVO5_PIN 13
#define ELECTROMAGNET_PIN 15
#define MODE_SWITCH_PIN 0

// --- Arm 2 (I2C 數據線輸出) ---
const int SLAVE_ADDRESS = 1;

Servo servo1;
Servo servo2;
Servo servo3;
Servo servo4;
Servo servo5;

// --- 模式選擇 ---
enum OperatingMode { ONLINE_MODE, OFFLINE_MODE };
OperatingMode currentMode;

// --- Online Mode (MQTT) 變數 ---
WiFiManager wifiManager;
WiFiClient espClient;
PubSubClient client(espClient);
const char* mqtt_server = "178.128.54.195";
const int mqtt_port = 1883;
// **新的 Topic 定義**
const char* topic_ik = "servo/arm2/ik";
const char* topic_claw = "servo/arm2/clm";
// 舊的 Topic (用於 Arm 1 或其他傳統控制)
const char* legacy_mqtt_base_topic = "servo/";

// --- Offline Mode (AP + Web Server) 變數 ---
const char* ap_ssid = "ESP8266_DualArm_Control";
ESP8266WebServer server(80);
DNSServer dnsServer;
String currentPage = "arm1";

// --- 伺服馬達初始角度 ---
const int INITIAL_ANGLE = 90;

// --- Serial 通訊速率 (與 Arm 2 接收端需一致) ---
const long ARM2_SERIAL_BAUDRATE = 57600;

// ======================================================
//  輔助函數：將 Arm 2 的 Web UI ID (1-6) 轉換為 label ('a'-'f')
// ======================================================
char getArm2LabelFromWebId(int webId) {
  if (webId >= 1 && webId <= 6) {
    return (char)('a' + webId - 1);
  }
  return ' ';
}

// ======================================================
//  Web Server HTML 頁面產生函式 (Offline Mode) - (完整版)
// ======================================================
String buildHtmlPage(String page) {
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
  html += "<div class='nav'>";
  if (page == "arm1") {
      html += "<span>控制手臂 1</span>";
      html += "<a href='/?page=arm2'>控制手臂 2</a>";
  } else {
      html += "<a href='/?page=arm1'>控制手臂 1</a>";
      html += "<span>控制手臂 2</span>";
  }
  html += "</div>";
  if (page == "arm1") {
      for (int i = 1; i <= 5; i++) {
          html += "<div class='control-group'>";
          html += "<label for='arm1_servo" + String(i) + "'>手臂 1 - 馬達 " + String(i) + ": <span class='angle-display' id='arm1_angle" + String(i) + "'>" + String(INITIAL_ANGLE) + "</span>°</label>";
          html += "<input type='range' id='arm1_servo" + String(i) + "' min='0' max='500' value='" + String(INITIAL_ANGLE) + "' oninput='updateArm1Servo(" + String(i) + ", this.value)' style='--value-percent:" + String(INITIAL_ANGLE*100/180) + "%;'>";
          html += "</div>";
      }
      html += "<div class='control-group'>";
      html += "<label for='magnetBtn'>手臂 1 - 電磁鐵:</label>";
      html += "<button id='magnetBtn' class='toggle-btn' onclick='toggleArm1Magnet()'>開啟電磁鐵</button>";
      html += "</div>";
  } else {
      char arm2_labels[] = {'a', 'b', 'c', 'd', 'e', 'f'};
      for (int i = 1; i <= 6; i++) {
          html += "<div class='control-group'>";
          String motorTypeLabel = (i <= 3) ? "伺服馬達" : "步進馬達";
          String tempLabelChar = String(arm2_labels[i-1]);
          tempLabelChar.toUpperCase();
          html += "<label for='arm2_motor" + String(i) + "'>手臂 2 - " + motorTypeLabel + " " + tempLabelChar + ": <span class='angle-display' id='arm2_angle" + String(i) + "'>" + String(INITIAL_ANGLE) + "</span>°</label>";
          html += "<input type='range' id='arm2_motor" + String(i) + "' min='0' max='500' value='" + String(INITIAL_ANGLE) + "' oninput='updateArm2Motor(" + String(i) + ", this.value)' style='--value-percent:" + String(INITIAL_ANGLE*100/180) + "%;'>";
          html += "</div>";
      }
  }
  html += "<script>";
  html += "function updateSliderFill(slider) { const percentage = (slider.value - slider.min) / (slider.max - slider.min) * 100; slider.style.setProperty('--value-percent', percentage + '%'); }";
  html += "function updateArm1Servo(id, angle) {";
  html += "  document.getElementById('arm1_angle' + id).innerText = angle;";
  html += "  const slider = document.getElementById('arm1_servo' + id); updateSliderFill(slider);";
  html += "  fetch('/setArm1Servo?id=' + id + '&angle=' + angle).catch(err => console.error('Fetch error:', err));";
  html += "}";
  html += "let magnetState = false;";
  html += "function toggleArm1Magnet() {";
  html += "  magnetState = !magnetState;";
  html += "  const btn = document.getElementById('magnetBtn');";
  html += "  const command = magnetState ? 'ON' : 'OFF';";
  html += "  fetch('/setArm1Magnet?state=' + command).catch(err => console.error('Fetch error:', err));";
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
    // angle = constrain(angle, 0, 500); // 移除限制
    Serial.printf("[Web] Arm 1 Servo: ID=%d, Angle=%d\n", servoId, angle);
    switch (servoId) {
      case 1: servo1.write(angle); break; case 2: servo2.write(angle); break;
      case 3: servo3.write(angle); break; case 4: servo4.write(angle); break;
      case 5: servo5.write(angle); break;
      default: server.send(400, "text/plain", "Bad Servo ID"); return;
    }
    server.send(200, "text/plain", "OK");
  } else { server.send(400, "text/plain", "Bad Request: Missing id or angle"); }
}

void handleSetArm1Magnet() {
  if (server.hasArg("state")) {
    String state = server.arg("state");
    Serial.printf("[Web] Arm 1 Magnet: State=%s\n", state.c_str());
    if (state.equalsIgnoreCase("ON")) { digitalWrite(ELECTROMAGNET_PIN, HIGH); }
    else if (state.equalsIgnoreCase("OFF")) { digitalWrite(ELECTROMAGNET_PIN, LOW); }
    else { server.send(400, "text/plain", "Bad State"); return; }
    server.send(200, "text/plain", "OK");
  } else { server.send(400, "text/plain", "Bad Request: Missing state"); }
}

void handleSetArm2Motor() {
  if (server.hasArg("id") && server.hasArg("angle")) {
      int webMotorId = server.arg("id").toInt();
      int angle = server.arg("angle").toInt();
      // angle = constrain(angle, 0, 500); // 移除限制
      char motorLabel = getArm2LabelFromWebId(webMotorId);
      if (motorLabel != ' ') {
          String serialCommand = String(motorLabel) + String(angle) + "|";
          Wire.beginTransmission(SLAVE_ADDRESS);
          Wire.write(serialCommand.c_str());
          Wire.endTransmission();
          Serial.printf("[Web] Arm 2 Motor: WebID=%d -> Label=%c, Angle=%d -> Wire: %s\n", webMotorId, motorLabel, angle, serialCommand.c_str());
          Serial1.print(serialCommand);
          server.send(200, "text/plain", "OK");
      } else {
          server.send(400, "text/plain", "Bad Motor ID"); return;
      }
  } else { server.send(400, "text/plain", "Bad Request: Missing id or angle"); }
}

// ======================================================
//  MQTT Callback (Online Mode) - *** 已修正 ***
// ======================================================
void callback(char* topic, byte* payload, unsigned int length) {
  String message;
  for (unsigned int i = 0; i < length; i++) {
    message += (char)payload[i];
  }
  String topicStr = String(topic);

  Serial.print("MQTT Received ["); Serial.print(topicStr); Serial.print("]: "); Serial.println(message);

  // --- 新格式處理 (Arm 2) ---
  if (topicStr.equals(topic_ik) || topicStr.equals(topic_claw)) {
    // 直接將整個 payload 字串轉發，不做任何解析或限制
    Wire.beginTransmission(SLAVE_ADDRESS);
    Wire.write(message.c_str());
    Wire.endTransmission();
    
    Serial1.print(message); // 也透過 Serial1 轉發 (備用/日誌)
    Serial.printf("[MQTT] Forwarded Arm 2 data via Wire: %s\n", message.c_str());
  }
  // --- 保留舊格式處理 (Arm 1, 如果需要的話) ---
  else if (topicStr.startsWith(legacy_mqtt_base_topic)) {
    // ... (這部分可以保留用於控制 Arm 1，或根據需要移除)
  }
}

// ======================================================
//  MQTT Reconnect Logic (Online Mode) - *** 已修正 ***
// ======================================================
void reconnect() {
  while (!client.connected()) {
    Serial.print("Attempting MQTT connection... ");
    String clientId = "ESP8266-IK-Client-";
    clientId += String(random(0xffff), HEX);
    if (client.connect(clientId.c_str())) {
      Serial.println("connected!");
      // **明確訂閱新的 Arm 2 Topic**
      client.subscribe(topic_ik);
      client.subscribe(topic_claw);
      Serial.print("Subscribed to: "); Serial.println(topic_ik);
      Serial.print("Subscribed to: "); Serial.println(topic_claw);

    } else {
      Serial.print("failed, rc=");
      Serial.print(client.state());
      Serial.println(" try again in 5 seconds");
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
  if (!wifiManager.autoConnect("ESP8266_Arm_Setup")) {
    Serial.println("Failed to connect to WiFi and hit timeout -> Restarting...");
    delay(3000);
    ESP.restart();
    delay(5000);
  }
  Serial.println("\nConnected to WiFi!");
  Serial.print("IP Address: "); Serial.println(WiFi.localIP());
  Serial.print("MQTT Server: "); Serial.print(mqtt_server); Serial.print(":"); Serial.println(mqtt_port);
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);
}

void setupOfflineMode() {
  Serial.println("Setting up Offline Mode (AP + Web Server + DNS)...");
  WiFi.mode(WIFI_AP);
  if (WiFi.softAP(ap_ssid)) {
      Serial.println("\nAP Mode Active! Network is OPEN.");
      Serial.print("SSID: "); Serial.println(ap_ssid);
      IPAddress myIP = WiFi.softAPIP();
      Serial.print("AP IP address: "); Serial.println(myIP);
      if (dnsServer.start(53, "*", myIP)) {
          Serial.println("DNS Server started.");
      } else {
          Serial.println("Failed to start DNS Server!");
      }
      server.on("/", HTTP_GET, handleRoot);
      server.on("/setArm1Servo", HTTP_GET, handleSetArm1Servo);
      server.on("/setArm1Magnet", HTTP_GET, handleSetArm1Magnet);
      server.on("/setArm2Motor", HTTP_GET, handleSetArm2Motor);
      server.onNotFound([]() {
          Serial.println("Handling not found (Captive Portal?) -> Redirecting to root.");
          handleRoot();
      });
      server.begin();
      Serial.println("Web Server started.");
  } else {
      Serial.println("Failed to start AP!");
  }
}

// ======================================================
//  Main Setup
// ======================================================
void setup() {
  Wire.begin();
  Serial.begin(115200);
  Serial.println("\n\nESP8266 Dual Arm Controller v3.1 (IK/CLM Fixed) Booting...");
  delay(1000);
  Serial1.begin(ARM2_SERIAL_BAUDRATE);
  pinMode(MODE_SWITCH_PIN, INPUT_PULLUP);
  Serial.print("Reading Mode Switch Pin... ");
  delay(100);

  if (SERVO2_PIN == ELECTROMAGNET_PIN) {
    Serial.println("\n!!! CRITICAL WARNING: SERVO2_PIN and ELECTROMAGNET_PIN are the same! !!!\n");
  }

  servo1.attach(SERVO1_PIN);
  servo2.attach(SERVO2_PIN);
  servo3.attach(SERVO3_PIN);
  servo4.attach(SERVO4_PIN);
  servo5.attach(SERVO5_PIN);
  servo1.write(INITIAL_ANGLE);
  servo2.write(INITIAL_ANGLE);
  servo3.write(INITIAL_ANGLE);
  servo4.write(INITIAL_ANGLE);
  servo5.write(INITIAL_ANGLE);

  pinMode(ELECTROMAGNET_PIN, OUTPUT);
  digitalWrite(ELECTROMAGNET_PIN, LOW);
  Serial.println("Arm 1 Hardware Initialized.");

  if (digitalRead(MODE_SWITCH_PIN) == LOW) {
    currentMode = OFFLINE_MODE;
    Serial.println("Result: LOW -> Entering OFFLINE Mode");
  } else {
    currentMode = ONLINE_MODE;
    Serial.println("Result: HIGH (or floating) -> Entering ONLINE Mode");
  }
  Serial.println("-----------------------------------------");

  if (currentMode == ONLINE_MODE) {
    setupOnlineMode();
  } else {
    setupOfflineMode();
  }
  Serial.println("-----------------------------------------");
  Serial.println("Setup complete. Entering main loop...");
}

// ======================================================
//  Main Loop
// ======================================================
void loop() {
  if (currentMode == ONLINE_MODE) {
    if (!client.connected()) {
      reconnect();
    }
    client.loop();
  } else {
    dnsServer.processNextRequest();
    server.handleClient();
  }
}