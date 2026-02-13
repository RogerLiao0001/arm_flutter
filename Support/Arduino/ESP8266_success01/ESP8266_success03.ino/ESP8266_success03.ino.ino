#include <ESP8266WiFi.h>
#include <WiFiManager.h>      // https://github.com/tzapu/WiFiManager
#include <PubSubClient.h>
#include <Servo.h>
#include <ArduinoJson.h>      // For MQTT JSON parsing (v6+)
#include <ESP8266WebServer.h> // For Offline Mode Web Server
#include <DNSServer.h>        // For Captive Portal in Offline Mode
#include <Wire.h>

// --- 腳位定義 ---
// --- Arm 1 (直接控制) ---
#define SERVO1_PIN 2    // GPIO2 (NodeMCU D4) - Arm 1 Servo 1 (NodeMCU D4 is GPIO2)
#define SERVO2_PIN 16   // GPIO16 (NodeMCU D0) - Arm 1 Servo 2 (Comment says GPIO4 but D0 is GPIO16. Using 16)
                        // !!! WARNING: CONFLICTS WITH ELECTROMAGNET_PIN !!!
#define SERVO3_PIN 14   // GPIO14 (NodeMCU D5) - Arm 1 Servo 3
#define SERVO4_PIN 12   // GPIO12 (NodeMCU D6) - Arm 1 Servo 4
#define SERVO5_PIN 13   // GPIO13 (NodeMCU D7) - Arm 1 Servo 5
#define ELECTROMAGNET_PIN 15 //  (NodeMCU D8) - Arm 1 Electromagnet
                        // !!! WARNING: CONFLICTS WITH SERVO2_PIN !!!

// --- 模式切換 (取代按鈕) ---
// 開機時: 接 GND -> Offline Mode | 5V -> Online Mode
#define MODE_SWITCH_PIN 0   //    (NodeMCU D3) - Mode Select Pin

// --- Arm 2 (I2C 數據線輸出) ---：GPIO4 (D1)為SCL(Clock)，GPIO5 (D2)為 SDA (Data) gnd-gnd

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

const int SLAVE_ADDRESS = 1;
// --- Online Mode (MQTT) 變數 ---
WiFiManager wifiManager;
WiFiClient espClient;
PubSubClient client(espClient);
const char* mqtt_server = "178.128.54.195";
const int mqtt_port = 1883;
// MQTT Topics (根據 Flutter App 更新)
const char* mqtt_base_topic = "servo/"; // 所有控制都在 servo/ 下
// Arm 1: servo/1, servo/2, ..., servo/5, servo/magnet
// Arm 2: servo/arm2/a, servo/arm2/b, ..., servo/arm2/f, servo/arm2/h

// --- Offline Mode (AP + Web Server + DNS) 變數 ---
const char* ap_ssid = "ESP8266_DualArm_Control";
// const char* ap_password = "password123"; // 密碼已移除
ESP8266WebServer server(80);
DNSServer dnsServer;
String currentPage = "arm1";

// --- 伺服馬達初始角度 ---
const int INITIAL_ANGLE = 90;

// --- Serial 通訊速率 (與 Arm 2 接收端需一致) ---
const long ARM2_SERIAL_BAUDRATE = 57600;

// --- JSON 文件建議大小 (用於 MQTT 解析) ---
const size_t JSON_DOC_SIZE = 128;

// ======================================================
//  輔助函數：將 Arm 2 的 Web UI ID (1-6) 轉換為 label ('a'-'f') - (保持不變)
// ======================================================
char getArm2LabelFromWebId(int webId) {
  if (webId >= 1 && webId <= 6) {
    return (char)('a' + webId - 1);
  }
  return ' '; // Return space or some error indicator if ID is invalid
}

// ======================================================
//  Web Server HTML 頁面產生函式 (Offline Mode) - (保持不變)
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
          html += "<input type='range' id='arm1_servo" + String(i) + "' min='0' max='500' value='" + String(INITIAL_ANGLE) + "' oninput='updateArm1Servo(" + String(i) + ", this.value)' style='--value-percent:" + String(INITIAL_ANGLE*100/180) + "%;'>";
          html += "</div>";
      }
      html += "<div class='control-group'>";
      html += "<label for='magnetBtn'>手臂 1 - 電磁鐵:</label>";
      html += "<button id='magnetBtn' class='toggle-btn' onclick='toggleArm1Magnet()'>開啟電磁鐵</button>";
      html += "</div>";
  } else { // page == "arm2"
      char arm2_labels[] = {'a', 'b', 'c', 'd', 'e', 'f'};
      for (int i = 1; i <= 6; i++) { // Loop for 6 motors
          html += "<div class='control-group'>";
          String motorTypeLabel = (i <= 3) ? "伺服馬達" : "步進馬達";
          String tempLabelChar = String(arm2_labels[i-1]);
          tempLabelChar.toUpperCase();
          html += "<label for='arm2_motor" + String(i) + "'>手臂 2 - " + motorTypeLabel + " " + tempLabelChar + ": <span class='angle-display' id='arm2_angle" + String(i) + "'>" + String(INITIAL_ANGLE) + "</span>°</label>";
          html += "<input type='range' id='arm2_motor" + String(i) + "' min='0' max='500' value='" + String(INITIAL_ANGLE) + "' oninput='updateArm2Motor(" + String(i) + ", this.value)' style='--value-percent:" + String(INITIAL_ANGLE*100/180) + "%;'>";
          html += "</div>";
      }
  }

  // JavaScript
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
  html += "function updateArm2Motor(id, angle) {"; // id is 1-6 from web UI
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
//  Web Server Request Handlers (Offline Mode) - (保持不變)
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
    angle = constrain(angle, 0, 500);
    Serial.printf("[Web] Arm 1 Servo: ID=%d, Angle=%d\n", servoId, angle);
    switch (servoId) {
      case 1: servo1.write(angle); break; case 2: servo2.write(angle); break;
      case 3: servo3.write(angle); break; case 4: servo4.write(angle); break;
      case 5: servo5.write(angle); break; default:
        Serial.println("Invalid Arm 1 servo ID from web"); server.send(400, "text/plain", "Bad Servo ID"); return;
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
      angle = constrain(angle, 0, 500);
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
          Serial.println("Invalid Arm 2 motor ID from web"); server.send(400, "text/plain", "Bad Motor ID"); return;
      }
  } else { server.send(400, "text/plain", "Bad Request: Missing id or angle"); }
}


// ======================================================
//  MQTT Callback (Online Mode) - *** 這裏是唯一的修改點 ***
// ======================================================
void callback(char* topic, byte* payload, unsigned int length) {
  String message;
  for (unsigned int i = 0; i < length; i++) {
    message += (char)payload[i];
  }
  String topicStr = String(topic);

  Serial.print("MQTT Received ["); Serial.print(topicStr); Serial.print("]: "); Serial.println(message);

  String subTopic = topicStr.substring(strlen(mqtt_base_topic));

  if (subTopic.equals("magnet")) {
    Serial.print("[MQTT] Processing Arm 1 Electromagnet: ");
    if (message.equalsIgnoreCase("ON")) {
      digitalWrite(ELECTROMAGNET_PIN, HIGH);
      Serial.println("ON");
    } else if (message.equalsIgnoreCase("OFF")) {
      digitalWrite(ELECTROMAGNET_PIN, LOW);
      Serial.println("OFF");
    } else {
      Serial.println("Unknown command");
    }
  } else if (subTopic.startsWith("arm2/")) {
    if (subTopic.length() == strlen("arm2/") + 1) {
      char arm2Label = subTopic.charAt(strlen("arm2/"));
      
      // ==========================vvv 修正開始 vvv==========================
      // 原始判斷式: if (arm2Label >= 'a' && arm2Label <= 'f')
      // 現在加入對 'h' 的判斷，使其也能被處理
      if ((arm2Label >= 'a' && arm2Label <= 'z') || arm2Label == 'h') {
      // ==========================^^^ 修正結束 ^^^==========================
        DynamicJsonDocument doc(JSON_DOC_SIZE);
        DeserializationError error = deserializeJson(doc, message);

        if (error || !doc.containsKey("angle")) {
          Serial.printf("[MQTT] Arm 2 (Label %c): JSON parsing failed or missing 'angle'. Error: %s. Payload: %s\n", arm2Label, error.c_str(), message.c_str());
          return;
        }
        int angle = doc["angle"];
        angle = constrain(angle, 0, 500);
        String wireCommand = String(arm2Label) + String(angle) + "|"; 
        
        Serial.printf("[MQTT] Processing Arm 2: Label=%c, Angle=%d -> Wire: %s\n", arm2Label, angle, wireCommand.c_str());

        Wire.beginTransmission(SLAVE_ADDRESS);
        Wire.write(wireCommand.c_str());
        Wire.endTransmission();
        Serial1.print(wireCommand);

      } else {
        Serial.printf("[MQTT] Invalid Arm 2 label: %c\n", arm2Label);
      }
    } else {
      Serial.println("[MQTT] Invalid Arm 2 sub-topic format.");
    }
  } else { 
    int topicServoId = subTopic.toInt();
    if (topicServoId >= 1 && topicServoId <= 5) {
      DynamicJsonDocument doc(JSON_DOC_SIZE);
      DeserializationError error = deserializeJson(doc, message);
      
      int payloadServoId = -1;
      int angle = -1;

      if (!error && doc.containsKey("id") && doc.containsKey("angle")) {
        payloadServoId = doc["id"];
        angle = doc["angle"];
        angle = constrain(angle, 0, 500);

        if (topicServoId != payloadServoId) {
          Serial.printf("[MQTT] Warning: Topic ID (%d) mismatch with payload ID (%d)\n", topicServoId, payloadServoId);
        }
        
        int finalServoId = (payloadServoId >=1 && payloadServoId <=5) ? payloadServoId : topicServoId;

        Serial.printf("[MQTT] Processing Arm 1 Servo (JSON): ID=%d, Angle=%d\n", finalServoId, angle);
        switch (finalServoId) {
          case 1: servo1.write(angle); break;
          case 2: servo2.write(angle); break;
          case 3: servo3.write(angle); break;
          case 4: servo4.write(angle); break;
          case 5: servo5.write(angle); break;
          default: Serial.println("[MQTT] Invalid Servo ID for Arm 1 after processing."); break;
        }
      } else {
        Serial.printf("[MQTT] Arm 1 Servo (Topic %s): JSON parsing failed or invalid format. Error: %s. Payload: %s\n", subTopic.c_str(), error.c_str(), message.c_str());
      }
    } else {
      Serial.println("[MQTT] Unrecognized sub-topic under servo/: " + subTopic);
    }
  }
}

// ======================================================
//  MQTT Reconnect Logic (Online Mode) - (保持不變)
// ======================================================
void reconnect() {
  while (!client.connected()) {
    Serial.print("Attempting MQTT connection... ");
    String clientId = "ESP8266DualArmClient-";
    clientId += String(random(0xffff), HEX);
    if (client.connect(clientId.c_str())) {
      Serial.println("connected!");
      String subscribe_topic = String(mqtt_base_topic) + "#";
      if (client.subscribe(subscribe_topic.c_str())) {
        Serial.print("Subscribed to: "); Serial.println(subscribe_topic);
      } else {
        Serial.print("Failed to subscribe to: "); Serial.println(subscribe_topic);
      }
    } else {
      Serial.print("failed, rc=");
      Serial.print(client.state());
      Serial.println(" try again in 5 seconds");
      delay(5000);
    }
  }
}

// ======================================================
//  Setup Functions per Mode - (保持不變)
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
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());
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
      Serial.println("Connect to OPEN WiFi and control page should appear, or go to http://<AP_IP_ADDRESS>/");
  } else {
      Serial.println("Failed to start AP!");
  }
}

// ======================================================
//  Main Setup - (保持不變)
// ======================================================
void setup() {
  Wire.begin();
  Serial.begin(115200);
  Serial.println("\n\nESP8266 Dual Robot Arm Controller v2.6 Booting..."); // Version bump for h-motor support
  delay(1000);

  Serial1.begin(ARM2_SERIAL_BAUDRATE);
  Serial.print("Serial1 (GPIO2 TX) for Arm 2 started at "); Serial.print(ARM2_SERIAL_BAUDRATE); Serial.println(" bps (for logging/backup).");

  pinMode(MODE_SWITCH_PIN, INPUT_PULLUP);
  Serial.print("Reading Mode Switch Pin (D8/GPIO15)... ");
  delay(100);

  if (SERVO2_PIN == ELECTROMAGNET_PIN) {
    Serial.println("\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
    Serial.println("!!! CRITICAL WARNING: SERVO2_PIN and ELECTROMAGNET_PIN !!!");
    Serial.print("!!! are BOTH set to GPIO"); Serial.print(SERVO2_PIN); Serial.println(". This WILL cause issues!     !!!");
    Serial.println("!!! Please assign them to SEPARATE GPIO pins.          !!!");
    Serial.println("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");
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
//  Main Loop - (保持不變)
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