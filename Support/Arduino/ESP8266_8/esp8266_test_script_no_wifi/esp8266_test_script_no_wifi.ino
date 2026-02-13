#include <Servo.h>

// --- 定義腳位 ---
// 請根據你的板子對應的 GPIO 數字設定
#define SERVO1_PIN 5    // GPIO5 (NodeMCU D1)
#define SERVO2_PIN 4    // GPIO4 (NodeMCU D2)
#define SERVO3_PIN 14   // GPIO14 (NodeMCU D5)
#define SERVO4_PIN 12   // GPIO12 (NodeMCU D6)
#define SERVO5_PIN 13   // GPIO13 (NodeMCU D7)
#define ELECTROMAGNET_PIN 16 // GPIO16 (NodeMCU D0)

// --- 宣告五個 Servo 物件 ---
Servo servo1;
Servo servo2;
Servo servo3;
Servo servo4;
Servo servo5;

// 變數用來做伺服馬達往返移動
int pos = 0;
int increment = 1; // 每次改變的角度

// 電磁鐵切換控制變數
unsigned long lastElectroTime = 0;
bool electromagnetState = false;

void setup() {
  Serial.begin(115200);
  delay(1000);
  
  // 連接伺服馬達到指定腳位
  servo1.attach(SERVO1_PIN);
  servo2.attach(SERVO2_PIN);
  servo3.attach(SERVO3_PIN);
  servo4.attach(SERVO4_PIN);
  servo5.attach(SERVO5_PIN);
  
  // 設定初始位置（90° 可作為中間位置）
  servo1.write(90);
  servo2.write(90);
  servo3.write(90);
  servo4.write(90);
  servo5.write(90);
  
  // 設定電磁鐵控制腳位為輸出，初始關閉（LOW）
  pinMode(ELECTROMAGNET_PIN, OUTPUT);
  digitalWrite(ELECTROMAGNET_PIN, LOW);
}

void loop() {
  // 讓伺服馬達依序移動
  // 這裡讓 Servo 1、3、5 同時從 0 到 180 來回移動
  // 而 Servo 2、4 則反向運動（從 180 到 0）
  servo1.write(pos);
  servo2.write(180 - pos);
  servo3.write(pos);
  servo4.write(180 - pos);
  servo5.write(pos);
  
  pos += increment;
  if (pos >= 180 || pos <= 0) {
    increment = -increment; // 反向運動
  }
  
  // 每 20 毫秒更新一次伺服角度（可調整速度）
  delay(20);
  
  // 每 2 秒切換一次電磁鐵狀態
  if (millis() - lastElectroTime > 2000) {
    electromagnetState = !electromagnetState;
    digitalWrite(ELECTROMAGNET_PIN, electromagnetState ? HIGH : LOW);
    Serial.print("Electromagnet is now: ");
    Serial.println(electromagnetState ? "ON" : "OFF");
    lastElectroTime = millis();
  }
}
