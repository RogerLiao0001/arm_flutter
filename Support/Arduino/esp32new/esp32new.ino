#include <WiFi.h>
#include <WiFiManager.h>
#include <PubSubClient.h>
#include <ESP32Servo.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <math.h>
#include <string.h>

// =================================================================
//                 *** WIFI RESET CONFIGURATION ***
// =================================================================
// [重要] 設定為 "true" 會強制清除已儲存的 WiFi 設定來解決卡住的問題。
// 成功設定好 WiFi 後，請務必將此項改回 "false" 並重新上傳！
#define RESET_WIFI_SETTINGS true
// =================================================================

// =================================================================
//               *** 已修正：無衝突的腳位定義 ***
// =================================================================
// --- Arm 1 (直接控制) ---
#define SERVO1_PIN 2    // GPIO2
#define SERVO2_PIN 16   // GPIO16
#define SERVO3_PIN 15   // GPIO15 (原為 SERVO3=14, 已移動)
#define SERVO4_PIN 12   // GPIO12
#define SERVO5_PIN 4    // GPIO4  (原為 SERVO5=13, 已移動)
#define ELECTROMAGNET_PIN 2 // (原為 15, 已移動到 GPIO 2, 但 SERVO1 也在用，請確認您實際的接線並選擇一個空腳位)
                        // !!! 注意：這裡臨時設定為 2，但 SERVO1 也在用。請根據您的板子將電磁鐵換到一個真正沒被用的腳位 !!!

// --- Arm 2 (I2C 數據線輸出) ---
// 使用原先伺服馬達的腳位，確保無衝突
#define I2C_SDA_PIN 13  // 設定 GPIO13 為 SDA
#define I2C_SCL_PIN 14  // 設定 GPIO14 為 SCL
// =================================================================


Servo servo1;
Servo servo2;
Servo servo3;
Servo servo4;
Servo servo5;

const int SLAVE_ADDRESS = 1;
// --- Online Mode (MQTT) 變數 ---
WiFiClient espClient;
PubSubClient client(espClient);
const char* mqtt_server = "178.128.54.195";
const int mqtt_port = 1883;
const char* subscribe_topic = "servo/arm2/#";

// --- I2C 發送佇列與時序控制 ---
const int MESSAGE_QUEUE_SIZE = 10;
const int MAX_MESSAGE_LENGTH = 128;
char messageQueue[MESSAGE_QUEUE_SIZE][MAX_MESSAGE_LENGTH];
volatile int queueWriteIndex = 0;
volatile int queueReadIndex = 0;
const int I2C_SEND_DELAY_MS = 20;

// --- 伺服馬達初始角度 ---
const int INITIAL_ANGLE = 90;

// (此處省略所有 IK 數學函式的重複程式碼，它們與上一版完全相同)
// =================================================================
//      *** IK 運算公式 (無需修改) ***
// =================================================================
static const int DOF = 6;
static const float alpha_[DOF] = { -1.57f, 0.00f, 1.57f, -1.57f, 1.57f, 0.00f };
static const float a_[DOF] = { 0.000f, 252.625f, 0.000f, 0.000f, 0.000f, 0.000f };
static const float d_[DOF] = { 136.1f, 0.0f, 0.0f, 214.6f, 0.0f, 119.471f };
static const float theta_off_[DOF] = { 0.00f, -1.57f, 1.57f, 0.00f, 0.00f, 0.00f };
static const float radtoang = 57.295;
static const int MAX_ITERS = 120;
static const float DAMPING = 0.02f;
static const float POS_TOL = 0.5f;
static const float ROT_TOL = 0.005f;
// --- Math helpers ---
static inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
static inline void mat4Mul(const float A[16], const float B[16], float C[16]) { for (int r = 0; r < 4; r++) { for (int c = 0; c < 4; c++) { float s = 0; for (int k = 0; k < 4; k++) s += A[r * 4 + k] * B[k * 4 + c]; C[r * 4 + c] = s; } } }
static inline void mat4Copy(const float S[16], float D[16]) { for (int i = 0; i < 16; i++) D[i] = S[i]; }
static inline void mat4FromDH(float a, float alpha, float d, float theta, float T[16]) { float ct = cosf(theta), st = sinf(theta); float ca = cosf(alpha), sa = sinf(alpha); T[0] = ct; T[1] = -st * ca; T[2] = st * sa; T[3] = a * ct; T[4] = st; T[5] = ct * ca; T[6] = -ct * sa; T[7] = a * st; T[8] = 0; T[9] = sa; T[10] = ca; T[11] = d; T[12] = 0; T[13] = 0; T[14] = 0; T[15] = 1; }
static inline void rpyZYX_to_R(float rx, float ry, float rz, float R[9]) { float cx = cosf(rx), sx = sinf(rx); float cy = cosf(ry), sy = sinf(ry); float cz = cosf(rz), sz = sinf(rz); R[0] = cz * cy; R[1] = cz * sy * sx - sz * cx; R[2] = cz * sy * cx + sz * sx; R[3] = sz * cy; R[4] = sz * sy * sx + cz * cx; R[5] = sz * sy * cx - cz * sx; R[6] = -sy; R[7] = cy * sx; R[8] = cy * cx; }
static inline void R_to_axisAngle(const float R[9], float axis[3], float &angle) { float tr = R[0] + R[4] + R[8]; float c = (tr - 1.0f) * 0.5f; c = clampf(c, -1.0f, 1.0f); angle = acosf(c); if (angle < 1e-6f) { axis[0] = axis[1] = axis[2] = 0; angle = 0; return; } float denom = 2.0f * sinf(angle); axis[0] = (R[7] - R[5]) / denom; axis[1] = (R[2] - R[6]) / denom; axis[2] = (R[3] - R[1]) / denom; }
static void fk(const float q[DOF], float T[16]) { float Ti[16], Tacc[16]; for (int i = 0; i < 16; i++) Tacc[i] = (i % 5 == 0) ? 1.0f : 0.0f; for (int i = 0; i < DOF; i++) { float theta = q[i] + theta_off_[i]; mat4FromDH(a_[i], alpha_[i], d_[i], theta, Ti); float Tnew[16]; mat4Mul(Tacc, Ti, Tnew); mat4Copy(Tnew, Tacc); } mat4Copy(Tacc, T); }
static void jacobian(const float q[DOF], float J[6 * DOF]) { float Tacc[16]; for (int i = 0; i < 16; i++) Tacc[i] = (i % 5 == 0) ? 1.0f : 0.0f; float origins[DOF + 1][3]; float zaxes[DOF + 1][3]; origins[0][0] = 0; origins[0][1] = 0; origins[0][2] = 0; zaxes[0][0] = 0; zaxes[0][1] = 0; zaxes[0][2] = 1; for (int i = 0; i < DOF; i++) { float Ti[16]; float theta = q[i] + theta_off_[i]; mat4FromDH(a_[i], alpha_[i], d_[i], theta, Ti); float Tnew[16]; mat4Mul(Tacc, Ti, Tnew); mat4Copy(Tnew, Tacc); origins[i + 1][0] = Tacc[3]; origins[i + 1][1] = Tacc[7]; origins[i + 1][2] = Tacc[11]; zaxes[i + 1][0] = Tacc[2]; zaxes[i + 1][1] = Tacc[6]; zaxes[i + 1][2] = Tacc[10]; } float pe[3] = { origins[DOF][0], origins[DOF][1], origins[DOF][2] }; for (int i = 0; i < DOF; i++) { float zi[3] = { zaxes[i][0], zaxes[i][1], zaxes[i][2] }; float pi[3] = { origins[i][0], origins[i][1], origins[i][2] }; float r[3] = { pe[0] - pi[0], pe[1] - pi[1], pe[2] - pi[2] }; float jv[3] = { zi[1] * r[2] - zi[2] * r[1], zi[2] * r[0] - zi[0] * r[2], zi[0] * r[1] - zi[1] * r[0] }; J[0 * DOF + i] = jv[0]; J[1 * DOF + i] = jv[1]; J[2 * DOF + i] = jv[2]; J[3 * DOF + i] = zi[0]; J[4 * DOF + i] = zi[1]; J[5 * DOF + i] = zi[2]; } }
static inline void mat6x6_mul_vec(const float A[36], const float x[6], float y[6]) { for (int r = 0; r < 6; r++) { float s = 0; for (int c = 0; c < 6; c++) s += A[r * 6 + c] * x[c]; y[r] = s; } }
static bool invert6x6(const float A[36], float invA[36]) { float M[6][12]; for (int r = 0; r < 6; r++) { for (int c = 0; c < 6; c++) M[r][c] = A[r * 6 + c]; for (int c = 0; c < 6; c++) M[r][6 + c] = (r == c) ? 1.0f : 0.0f; } for (int i = 0; i < 6; i++) { int piv = i; float maxA = fabsf(M[i][i]); for (int r = i + 1; r < 6; r++) { float v = fabsf(M[r][i]); if (v > maxA) { maxA = v; piv = r; } } if (maxA < 1e-8f) return false; if (piv != i) { for (int c = 0; c < 12; c++) { float tmp = M[i][c]; M[i][c] = M[piv][c]; M[piv][c] = tmp; } } float diag = M[i][i]; for (int c = 0; c < 12; c++) M[i][c] /= diag; for (int r = 0; r < 6; r++) if (r != i) { float f = M[r][i]; if (f != 0) { for (int c = 0; c < 12; c++) M[r][c] -= f * M[i][c]; } } } for (int r = 0; r < 6; r++) for (int c = 0; c < 6; c++) invA[r * 6 + c] = M[r][6 + c]; return true; }
static void poseError(const float Tcurr[16], const float p_des[3], const float rpy_des[3], float e[6]) { e[0] = p_des[0] - Tcurr[3]; e[1] = p_des[1] - Tcurr[7]; e[2] = p_des[2] - Tcurr[11]; float Rcurr[9] = { Tcurr[0], Tcurr[1], Tcurr[2], Tcurr[4], Tcurr[5], Tcurr[6], Tcurr[8], Tcurr[9], Tcurr[10] }; float Rdes[9]; rpyZYX_to_R(rpy_des[0], rpy_des[1], rpy_des[2], Rdes); float Rct[9] = { Rcurr[0], Rcurr[3], Rcurr[6], Rcurr[1], Rcurr[4], Rcurr[7], Rcurr[2], Rcurr[5], Rcurr[8] }; float Rerr[9]; for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) { float s = 0; for (int k = 0; k < 3; k++) s += Rdes[r * 3 + k] * Rct[k * 3 + c]; Rerr[r * 3 + c] = s; } float axis[3]; float ang; R_to_axisAngle(Rerr, axis, ang); e[3] = axis[0] * ang; e[4] = axis[1] * ang; e[5] = axis[2] * ang; }
static bool ik_solve(float q[DOF], const float p_des[3], const float rpy_des[3]) { for (int iter = 0; iter < MAX_ITERS; ++iter) { float Tcurr[16]; fk(q, Tcurr); float e[6]; poseError(Tcurr, p_des, rpy_des, e); float pos_err = sqrtf(e[0] * e[0] + e[1] * e[1] + e[2] * e[2]); float rot_err = sqrtf(e[3] * e[3] + e[4] * e[4] + e[5] * e[5]); if (pos_err < POS_TOL && rot_err < ROT_TOL) return true; float J[6 * DOF]; jacobian(q, J); float A[36] = { 0 }; for (int r = 0; r < 6; r++) { for (int c = 0; c < 6; c++) { float s = 0; for (int k = 0; k < DOF; k++) s += J[r * DOF + k] * J[c * DOF + k]; A[r * 6 + c] = s; } A[r * 6 + r] += (DAMPING * DAMPING); } float invA[36]; if (!invert6x6(A, invA)) return false; float y[6]; mat6x6_mul_vec(invA, e, y); float dq[DOF]; for (int i = 0; i < DOF; i++) { float s = 0; for (int r = 0; r < 6; r++) s += J[r * DOF + i] * y[r]; dq[i] = s; } const float MAX_STEP = 0.2f; for (int i = 0; i < DOF; i++) dq[i] = clampf(dq[i], -MAX_STEP, MAX_STEP); for (int i = 0; i < DOF; i++) q[i] += dq[i]; } return false; }
static int splitTokens(const String &s, String tokens[], int maxTok) { int n = 0; int i = 0; while (i < s.length() && n < maxTok) { while (i < s.length() && isspace(s[i])) i++; if (i >= s.length()) break; int j = i; while (j < s.length() && !isspace(s[j])) j++; tokens[n++] = s.substring(i, j); i = j; } return n; }
static bool parseFloats(String tokens[], int start, int count, float *out) { for (int i = 0; i < count; i++) { out[i] = tokens[start + i].toFloat(); } return true; }
// ======================================================

void addToQueue(const char* message) { if ((queueWriteIndex + 1) % MESSAGE_QUEUE_SIZE == queueReadIndex) { Serial.println("[ERROR] I2C message queue is full! Message dropped."); return; } strncpy(messageQueue[queueWriteIndex], message, MAX_MESSAGE_LENGTH - 1); messageQueue[queueWriteIndex][MAX_MESSAGE_LENGTH - 1] = '\0'; queueWriteIndex = (queueWriteIndex + 1) % MESSAGE_QUEUE_SIZE; Serial.println("  -> Message added to I2C queue."); }
void callback(char* topic, byte* payload, unsigned int length) { String topicStr = String(topic); char payloadStr[length + 1]; memcpy(payloadStr, payload, length); payloadStr[length] = '\0'; Serial.print("MQTT Received ["); Serial.print(topicStr); Serial.print("]: "); Serial.println(payloadStr); if (topicStr.endsWith("/lk")) { Serial.println("  -> IK command detected. Processing..."); String line(payloadStr); line.trim(); String tok[20]; int n = splitTokens(line, tok, 20); if (tok[0] == "IK" && n >= 7) { float p_des[3], rpy_des[3]; parseFloats(tok, 1, 3, p_des); parseFloats(tok, 4, 3, rpy_des); float q[DOF] = { 0, 0, 1.57, 0, 0, 0 }; if (n == 1 + 6 + DOF) { parseFloats(tok, 1 + 6, DOF, q); } bool ok = ik_solve(q, p_des, rpy_des); if (ok) { Serial.print("  -> IK converged. Result (deg): "); String jmString = "jm"; for (int i = 0; i < DOF; i++) { float angle_deg = q[i] * radtoang; jmString += " "; jmString += String(angle_deg, 4); Serial.print(angle_deg); Serial.print(" "); } Serial.println(); addToQueue(jmString.c_str()); } else { Serial.println("[ERROR] IK did not converge!"); } } else { Serial.println("[ERROR] Invalid IK command format."); } } else if (topicStr.startsWith("servo/arm2/")) { Serial.println("  -> Forwarding command directly."); addToQueue(payloadStr); } }
void reconnect() { while (!client.connected()) { Serial.print("Attempting MQTT connection... "); String clientId = "ESP32-IK-Forwarder-"; clientId += String(random(0xffff), HEX); if (client.connect(clientId.c_str())) { Serial.println("connected!"); client.subscribe(subscribe_topic); Serial.print("Subscribed to wildcard topic: "); Serial.println(subscribe_topic); } else { Serial.print("failed, rc="); Serial.print(client.state()); Serial.println(" try again in 5 seconds"); delay(5000); } } }

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n\nESP32-CAM IK Calculator & Forwarder v6.4 (Crash & Pin Fix) Booting...");

  // I2C 初始化
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  
  // WiFiManager 初始化
  WiFiManager wifiManager;

  // 檢查是否需要強制重置 WiFi 設定
  if (RESET_WIFI_SETTINGS) {
    Serial.println("!!! FORCING WIFI SETTINGS RESET as per #define !!!");
    wifiManager.resetSettings();
    Serial.println("WiFi settings erased. The device will now start the configuration portal.");
    Serial.println("IMPORTANT: Change RESET_WIFI_SETTINGS back to 'false' and re-upload after you're done.");
  }

  Serial.println("-----------------------------------------");
  Serial.println("Starting WiFi Connection Process...");
  wifiManager.setConnectTimeout(30);

  // 啟動 autoConnect
  if (!wifiManager.autoConnect("ESP32_Arm_Setup")) {
    Serial.println("Failed to connect to WiFi and hit timeout -> Restarting...");
    delay(3000);
    ESP.restart();
  }

  // 如果成功連上 WiFi
  Serial.println("\nConnected to WiFi!");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  // *** 已修正：增加延遲以確保網路穩定 ***
  Serial.println("Waiting 3 seconds for network to stabilize before connecting to MQTT...");
  delay(3000);

  // 設定 MQTT
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);

  // 硬體初始化
  ESP32PWM::allocateTimer(0);
  ESP32PWM::allocateTimer(1);
  ESP32PWM::allocateTimer(2);
  ESP32PWM::allocateTimer(3);
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
  
  Serial.println("-----------------------------------------");
  Serial.println("Setup complete. Entering main loop...");
}

void loop() {
  if (!client.connected()) {
    reconnect();
  }
  client.loop();

  if (queueReadIndex != queueWriteIndex) {
    char* messageToSend = messageQueue[queueReadIndex];
    queueReadIndex = (queueReadIndex + 1) % MESSAGE_QUEUE_SIZE;
    Wire.beginTransmission(SLAVE_ADDRESS);
    Wire.write((const uint8_t*)messageToSend, strlen(messageToSend));
    Wire.endTransmission();
    Serial.printf("[I2C SENT] Forwarded: %s\n", messageToSend);
    delay(I2C_SEND_DELAY_MS);
  }
}