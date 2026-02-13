#include <ESP8266WiFi.h>
#include <WiFiManager.h>
#include <PubSubClient.h>
#include <Servo.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <math.h>

// --- 腳位定義 ---
#define SERVO1_PIN 2
#define SERVO2_PIN 16
#define SERVO3_PIN 14
#define SERVO4_PIN 12
#define SERVO5_PIN 13
#define ELECTROMAGNET_PIN 15

Servo servo1, servo2, servo3, servo4, servo5;

const int SLAVE_ADDRESS = 1;
// --- Online Mode (MQTT) 變數 ---
WiFiManager wifiManager;
WiFiClient espClient;
PubSubClient client(espClient);
const char* mqtt_server = "178.128.54.195";
const int mqtt_port = 1883;
const char* subscribe_topic = "servo/arm2/#";

// --- I2C 發送佇列 ---
const int MESSAGE_QUEUE_SIZE = 10;
const int MAX_MESSAGE_LENGTH = 128;
char messageQueue[MESSAGE_QUEUE_SIZE][MAX_MESSAGE_LENGTH];
volatile int queueWriteIndex = 0;
volatile int queueReadIndex = 0;
const int I2C_SEND_DELAY_MS = 20;

// --- 非阻塞式IK計算的變數 ---
char ik_command_buffer[MAX_MESSAGE_LENGTH];
volatile bool ik_calculation_pending = false;

const int INITIAL_ANGLE = 90;
const long ARM2_SERIAL_BAUDRATE = 57600;

// =================================================================================
//  *** START: 逆向運動學 (IK) 函式庫 ***
// =================================================================================
const float rad_to_deg = 57.295779513;
const float deg_to_rad = 0.01745329252; // *** 新增：角度轉弧度的常數 ***

static const int DOF = 6;
static const float alpha_[DOF] = { -1.57f, 0.00f, 1.57f, -1.57f, 1.57f, 0.00f };
static const float a_[DOF] = { 0.000f, 252.625f, 0.000f, 0.000f, 0.000f, 0.000f };
static const float d_[DOF] = { 136.1f, 0.0f, 0.0f, 214.6f, 0.0f, 119.471f };
static const float theta_off_[DOF] = { 0.00f, -1.57f, 1.57f, 0.00f, 0.00f, 0.00f };
static const int MAX_ITERS = 120;
static const float DAMPING = 0.02f;
static const float POS_TOL = 0.5f;
static const float ROT_TOL = 0.005f;

// --- *** 核心修正：定義每個關節的物理極限（單位：弧度） *** ---
// 格式: { {min_q1, max_q1}, {min_q2, max_q2}, ... }
// 這裡以 +/- 90度為例，您可以根據實際情況調整
const float joint_limits_[DOF][2] = {
  { -90 * deg_to_rad, 90 * deg_to_rad },  // Joint 1
  { -90 * deg_to_rad, 90 * deg_to_rad },  // Joint 2
  { -160 * deg_to_rad, 160 * deg_to_rad }, // Joint 3 (範例：放寬限制)
  { -170 * deg_to_rad, 170 * deg_to_rad }, // Joint 4
  { -90 * deg_to_rad, 90 * deg_to_rad },  // Joint 5
  { -180 * deg_to_rad, 180 * deg_to_rad }  // Joint 6
};

static float last_q[DOF] = { 0, 0, 1.57, 0, 0, 0 };

// --- Math helpers (保持不變) ---
static inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
static inline void mat4Mul(const float A[16], const float B[16], float C[16]) { for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) { float s = 0; for (int k = 0; k < 4; k++) s += A[r * 4 + k] * B[k * 4 + c]; C[r * 4 + c] = s; } }
static inline void mat4Copy(const float S[16], float D[16]) { for (int i = 0; i < 16; i++) D[i] = S[i]; }
static inline void mat4FromDH(float a, float alpha, float d, float theta, float T[16]) { float ct = cosf(theta), st = sinf(theta); float ca = cosf(alpha), sa = sinf(alpha); T[0]=ct; T[1]=-st*ca; T[2]=st*sa; T[3]=a*ct; T[4]=st; T[5]=ct*ca; T[6]=-ct*sa; T[7]=a*st; T[8]=0; T[9]=sa; T[10]=ca; T[11]=d; T[12]=0; T[13]=0; T[14]=0; T[15]=1; }
static inline void rpyZYX_to_R(float rx, float ry, float rz, float R[9]) { float cx=cosf(rx),sx=sinf(rx); float cy=cosf(ry),sy=sinf(ry); float cz=cosf(rz),sz=sinf(rz); R[0]=cz*cy; R[1]=cz*sy*sx-sz*cx; R[2]=cz*sy*cx+sz*sx; R[3]=sz*cy; R[4]=sz*sy*sx+cz*cx; R[5]=sz*sy*cx-cz*sx; R[6]=-sy; R[7]=cy*sx; R[8]=cy*cx; }
static inline void R_to_axisAngle(const float R[9], float axis[3], float &angle) { float tr=R[0]+R[4]+R[8]; float c=(tr-1.0f)*0.5f; c=clampf(c,-1.0f,1.0f); angle=acosf(c); if(angle<1e-6f){ axis[0]=axis[1]=axis[2]=0; angle=0; return; } float denom=2.0f*sinf(angle); axis[0]=(R[7]-R[5])/denom; axis[1]=(R[2]-R[6])/denom; axis[2]=(R[3]-R[1])/denom; }
static void fk(const float q[DOF], float T[16]) { float Ti[16],Tacc[16]; for(int i=0;i<16;i++) Tacc[i]=(i%5==0)?1.0f:0.0f; for(int i=0;i<DOF;i++){ float theta=q[i]+theta_off_[i]; mat4FromDH(a_[i],alpha_[i],d_[i],theta,Ti); float Tnew[16]; mat4Mul(Tacc,Ti,Tnew); mat4Copy(Tnew,Tacc); } mat4Copy(Tacc,T); }
static void jacobian(const float q[DOF], float J[6*DOF]) { float Tacc[16]; for(int i=0;i<16;i++) Tacc[i]=(i%5==0)?1.0f:0.0f; float origins[DOF+1][3]; float zaxes[DOF+1][3]; origins[0][0]=0;origins[0][1]=0;origins[0][2]=0; zaxes[0][0]=0;zaxes[0][1]=0;zaxes[0][2]=1; for(int i=0;i<DOF;i++){ float Ti[16]; float theta=q[i]+theta_off_[i]; mat4FromDH(a_[i],alpha_[i],d_[i],theta,Ti); float Tnew[16]; mat4Mul(Tacc,Ti,Tnew); mat4Copy(Tnew,Tacc); origins[i+1][0]=Tacc[3];origins[i+1][1]=Tacc[7];origins[i+1][2]=Tacc[11]; zaxes[i+1][0]=Tacc[2];zaxes[i+1][1]=Tacc[6];zaxes[i+1][2]=Tacc[10]; } float pe[3]={origins[DOF][0],origins[DOF][1],origins[DOF][2]}; for(int i=0;i<DOF;i++){ float zi[3]={zaxes[i][0],zaxes[i][1],zaxes[i][2]}; float pi[3]={origins[i][0],origins[i][1],origins[i][2]}; float r[3]={pe[0]-pi[0],pe[1]-pi[1],pe[2]-pi[2]}; float jv[3]={zi[1]*r[2]-zi[2]*r[1], zi[2]*r[0]-zi[0]*r[2], zi[0]*r[1]-zi[1]*r[0]}; J[0*DOF+i]=jv[0]; J[1*DOF+i]=jv[1]; J[2*DOF+i]=jv[2]; J[3*DOF+i]=zi[0]; J[4*DOF+i]=zi[1]; J[5*DOF+i]=zi[2]; } }
static inline void mat6x6_mul_vec(const float A[36], const float x[6], float y[6]) { for(int r=0;r<6;r++){ float s=0; for(int c=0;c<6;c++) s+=A[r*6+c]*x[c]; y[r]=s; } }
static bool invert6x6(const float A[36], float invA[36]) { float M[6][12]; for(int r=0;r<6;r++){ for(int c=0;c<6;c++) M[r][c]=A[r*6+c]; for(int c=0;c<6;c++) M[r][6+c]=(r==c)?1.0f:0.0f; } for(int i=0;i<6;i++){ int piv=i; float maxA=fabsf(M[i][i]); for(int r=i+1;r<6;r++){ float v=fabsf(M[r][i]); if(v>maxA){ maxA=v; piv=r; } } if(maxA<1e-8f) return false; if(piv!=i){ for(int c=0;c<12;c++){ float tmp=M[i][c]; M[i][c]=M[piv][c]; M[piv][c]=tmp; } } float diag=M[i][i]; for(int c=0;c<12;c++) M[i][c]/=diag; for(int r=0;r<6;r++) if(r!=i){ float f=M[r][i]; if(f!=0){ for(int c=0;c<12;c++) M[r][c]-=f*M[i][c]; } } } for(int r=0;r<6;r++) for(int c=0;c<6;c++) invA[r*6+c]=M[r][6+c]; return true; }
static void poseError(const float Tcurr[16], const float p_des[3], const float rpy_des[3], float e[6]) { e[0]=p_des[0]-Tcurr[3]; e[1]=p_des[1]-Tcurr[7]; e[2]=p_des[2]-Tcurr[11]; float Rcurr[9]={Tcurr[0],Tcurr[1],Tcurr[2], Tcurr[4],Tcurr[5],Tcurr[6], Tcurr[8],Tcurr[9],Tcurr[10]}; float Rdes[9]; rpyZYX_to_R(rpy_des[0],rpy_des[1],rpy_des[2],Rdes); float Rct[9]={Rcurr[0],Rcurr[3],Rcurr[6], Rcurr[1],Rcurr[4],Rcurr[7], Rcurr[2],Rcurr[5],Rcurr[8]}; float Rerr[9]; for(int r=0;r<3;r++) for(int c=0;c<3;c++){ float s=0; for(int k=0;k<3;k++) s+=Rdes[r*3+k]*Rct[k*3+c]; Rerr[r*3+c]=s; } float axis[3]; float ang; R_to_axisAngle(Rerr,axis,ang); e[3]=axis[0]*ang; e[4]=axis[1]*ang; e[5]=axis[2]*ang; }

// --- *** [MODIFIED] ik_solve 函式，增加了關節限制 *** ---
static bool ik_solve(float q[DOF], const float p_des[3], const float rpy_des[3]) {
  for (int iter = 0; iter < MAX_ITERS; ++iter) {
    float Tcurr[16]; fk(q, Tcurr);
    float e[6]; poseError(Tcurr, p_des, rpy_des, e);
    float pos_err = sqrtf(e[0]*e[0] + e[1]*e[1] + e[2]*e[2]);
    float rot_err = sqrtf(e[3]*e[3] + e[4]*e[4] + e[5]*e[5]);
    if (pos_err < POS_TOL && rot_err < ROT_TOL) return true;
    
    float J[6*DOF]; jacobian(q, J);
    float A[36] = {0};
    for (int r = 0; r < 6; r++) {
      for (int c = 0; c < 6; c++) {
        float s = 0;
        for (int k = 0; k < DOF; k++) s += J[r*DOF + k] * J[c*DOF + k];
        A[r*6 + c] = s;
      }
      A[r*6 + r] += (DAMPING * DAMPING);
    }
    
    float invA[36]; if (!invert6x6(A, invA)) return false;
    float y[6]; mat6x6_mul_vec(invA, e, y);
    float dq[DOF];
    for (int i = 0; i < DOF; i++) {
      float s = 0;
      for (int r = 0; r < 6; r++) s += J[r*DOF + i] * y[r];
      dq[i] = s;
    }
    
    const float MAX_STEP = 0.2f;
    for (int i = 0; i < DOF; i++) dq[i] = clampf(dq[i], -MAX_STEP, MAX_STEP);
    
    for (int i = 0; i < DOF; i++) {
        q[i] += dq[i];
        // *** 核心修正：在每次迭代後，強制將關節角度限制在物理範圍內 ***
        q[i] = clampf(q[i], joint_limits_[i][0], joint_limits_[i][1]);
    }
  }
  return false;
}

static int splitTokens(const String &s, String tokens[], int maxTok) { int n=0; int i=0; while(i<s.length() && n<maxTok){ while(i<s.length() && isspace(s[i])) i++; if(i>=s.length()) break; int j=i; while(j<s.length() && !isspace(s[j])) j++; tokens[n++]=s.substring(i,j); i=j; } return n; }
static bool parseFloats(String tokens[], int start, int count, float *out) { for (int i = 0; i < count; i++) { out[i] = tokens[start + i].toFloat(); } return true; }
// =================================================================================
//  *** END: 逆向運動學 (IK) 函式庫 ***
// =================================================================================

// ======================================================
//  MQTT Callback
// ======================================================
void callback(char* topic, byte* payload, unsigned int length) {
  char receivedMessage[MAX_MESSAGE_LENGTH];
  unsigned int len_to_copy = min((unsigned int)length, (unsigned int)MAX_MESSAGE_LENGTH - 1);
  memcpy(receivedMessage, payload, len_to_copy);
  receivedMessage[len_to_copy] = '\0';

  Serial.print("MQTT Received ["); Serial.print(topic); Serial.print("]: "); Serial.println(receivedMessage);
  
  if (strncmp(receivedMessage, "IK ", 3) == 0) {
    if (ik_calculation_pending) {
      Serial.println("  -> #WARN: Previous IK calculation is still pending. New IK command dropped.");
      return;
    }
    strncpy(ik_command_buffer, receivedMessage, MAX_MESSAGE_LENGTH);
    ik_calculation_pending = true; 
    Serial.println("  -> IK command received, scheduled for processing in main loop.");
  } else {
    Serial.println("  -> Passthrough command detected. Adding to I2C queue.");
    if ((queueWriteIndex + 1) % MESSAGE_QUEUE_SIZE == queueReadIndex) {
      Serial.println("[ERROR] I2C message queue is full! Passthrough message dropped.");
      return;
    }
    strncpy(messageQueue[queueWriteIndex], receivedMessage, MAX_MESSAGE_LENGTH);
    queueWriteIndex = (queueWriteIndex + 1) % MESSAGE_QUEUE_SIZE;
  }
}

// ======================================================
//  *** [MODIFIED] IK計算函式，修正單位並使用狀態記憶 ***
// ======================================================
void process_ik_command() {
  Serial.println("  -> Starting IK calculation in main loop...");

  String payloadStr(ik_command_buffer);
  String tok[20];
  int n = splitTokens(payloadStr, tok, 20);

  if (n == 1 + 6 || n == 1 + 6 + DOF) {
    float p[3], rpy[3];
    // 1. 正常解析所有浮點數 (位置單位是mm，角度單位是度)
    parseFloats(tok, 1, 3, p);
    parseFloats(tok, 4, 3, rpy);

    // *** 核心修正：將 rpy 陣列從角度轉換為弧度 ***
    Serial.printf("  -> RPY (deg): %.2f, %.2f, %.2f\n", rpy[0], rpy[1], rpy[2]);
    for (int i = 0; i < 3; i++) {
        rpy[i] = rpy[i] * deg_to_rad;
    }
    Serial.printf("  -> RPY (rad): %.4f, %.4f, %.4f\n", rpy[0], rpy[1], rpy[2]);
    
    float q[DOF];
    memcpy(q, last_q, sizeof(q));
    
    if (n == 1 + 6 + DOF) parseFloats(tok, 1 + 6, DOF, q);

    bool ok = ik_solve(q, p, rpy); // 現在傳入的是正確的弧度單位
    if (!ok) {
      Serial.println("  -> #WARN: IK not fully converged, but sending result anyway.");
    }

    memcpy(last_q, q, sizeof(q));
    
    char jm_buffer[MAX_MESSAGE_LENGTH];
    snprintf(jm_buffer, sizeof(jm_buffer), "jm %d %d %d %d %d %d",
             (int)round(q[0] * rad_to_deg), (int)round(q[1] * rad_to_deg),
             (int)round(q[2] * rad_to_deg), (int)round(q[3] * rad_to_deg),
             (int)round(q[4] * rad_to_deg), (int)round(q[5] * rad_to_deg));
    
    Serial.print("  -> Calculated jm command (rounded): "); Serial.println(jm_buffer);
    
    if ((queueWriteIndex + 1) % MESSAGE_QUEUE_SIZE != queueReadIndex) {
        strncpy(messageQueue[queueWriteIndex], jm_buffer, MAX_MESSAGE_LENGTH);
        queueWriteIndex = (queueWriteIndex + 1) % MESSAGE_QUEUE_SIZE;
        Serial.println("  -> 'jm' message added to I2C queue.");
    } else {
        Serial.println("[ERROR] I2C message queue is full! 'jm' message dropped.");
    }
  } else {
    Serial.println("  -> #ERROR: Invalid IK command format. Calculation skipped.");
  }
  ik_calculation_pending = false;
}

// ======================================================
//  MQTT Reconnect & Setup & Loop (保持不變)
// ======================================================
void reconnect() {
  while (!client.connected()) {
    Serial.print("Attempting MQTT connection... ");
    String clientId = "ESP8266-Forwarder-";
    clientId += String(random(0xffff), HEX);
    if (client.connect(clientId.c_str())) {
      Serial.println("connected!");
      client.subscribe(subscribe_topic);
      Serial.print("Subscribed to wildcard topic: "); Serial.println(subscribe_topic);
    } else {
      Serial.print("failed, rc=");
      Serial.print(client.state());
      Serial.println(" try again in 5 seconds");
      delay(5000);
    }
  }
}

void setup() {
  Wire.begin();
  Serial.begin(115200);
  Serial.println("\n\nESP8266 IK-Processor v9.0 (Unit-Corrected & Joint-Limited) Booting...");
  delay(1000);

  Serial1.begin(ARM2_SERIAL_BAUDRATE);
  Serial.print("Serial1 (GPIO2 TX) for Arm 2 started at "); Serial.print(ARM2_SERIAL_BAUDRATE); Serial.println(" bps (for logging/backup).");

  if (SERVO2_PIN == ELECTROMAGNET_PIN) {
    Serial.println("\n!!! CRITICAL WARNING: SERVO2_PIN and ELECTROMAGNET_PIN are conflicting!");
  }

  servo1.attach(SERVO1_PIN); servo2.attach(SERVO2_PIN); servo3.attach(SERVO3_PIN);
  servo4.attach(SERVO4_PIN); servo5.attach(SERVO5_PIN);
  servo1.write(INITIAL_ANGLE); servo2.write(INITIAL_ANGLE); servo3.write(INITIAL_ANGLE);
  servo4.write(INITIAL_ANGLE); servo5.write(INITIAL_ANGLE);
  pinMode(ELECTROMAGNET_PIN, OUTPUT);
  digitalWrite(ELECTROMAGNET_PIN, LOW);
  Serial.println("Arm 1 Hardware Initialized.");

  Serial.println("-----------------------------------------");
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
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);
  
  Serial.println("-----------------------------------------");
  Serial.println("Setup complete. Entering main loop...");
}

void loop() {
  if (!client.connected()) {
    reconnect();
  }
  client.loop();

  if (ik_calculation_pending) {
    process_ik_command();
  }

  if (queueReadIndex != queueWriteIndex) {
    char* messageToSend = messageQueue[queueReadIndex];
    queueReadIndex = (queueReadIndex + 1) % MESSAGE_QUEUE_SIZE;

    Wire.beginTransmission(SLAVE_ADDRESS);
    Wire.write(messageToSend);
    Wire.endTransmission();
    
    Serial1.print(messageToSend);
    Serial.printf("[I2C SENT] Forwarded: %s\n", messageToSend);

    delay(I2C_SEND_DELAY_MS);
  }
}