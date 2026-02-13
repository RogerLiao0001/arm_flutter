#include "esp_camera.h"
#include <WiFiManager.h>
#include <PubSubClient.h>
#include <WiFiClient.h>

// ----- AI Thinker ESP32-CAM 腳位設定 -----
#define CAMERA_MODEL_AI_THINKER
#if defined(CAMERA_MODEL_AI_THINKER)
  #define PWDN_GPIO_NUM     32
  #define RESET_GPIO_NUM    -1
  #define XCLK_GPIO_NUM      0
  #define SIOD_GPIO_NUM     26
  #define SIOC_GPIO_NUM     27
  #define Y9_GPIO_NUM       35
  #define Y8_GPIO_NUM       34
  #define Y7_GPIO_NUM       39
  #define Y6_GPIO_NUM       36
  #define Y5_GPIO_NUM       21
  #define Y4_GPIO_NUM       19
  #define Y3_GPIO_NUM       18
  #define Y2_GPIO_NUM        5
  #define VSYNC_GPIO_NUM    25
  #define HREF_GPIO_NUM     23
  #define PCLK_GPIO_NUM     22
#else
  #error "請選擇正確的 CAMERA_MODEL"
#endif

// ----- WiFiManager & MQTT -----
WiFiManager wifiManager;
WiFiClient espClient;
PubSubClient mqttClient(espClient);

// 雲端 MQTT Broker 設定（DigitalOcean IP）
const char* mqtt_server = "178.128.54.195";
const int mqtt_port = 1883;
const char* mqtt_topic = "esp32cam/stream";

// 發佈間隔（1 秒）
unsigned long lastPublish = 0;
const unsigned long publishInterval = 50;

void initCameraConfig() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sscb_sda = SIOD_GPIO_NUM;
  config.pin_sscb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 30000000;
  // 使用 QQVGA 解析度，降低檔案大小（160x120）
  config.frame_size = FRAMESIZE_QQVGA;
  config.pixel_format = PIXFORMAT_JPEG;
  config.jpeg_quality = 60;
  config.fb_count = 1;
  
  esp_err_t err = esp_camera_init(&config);
  if(err != ESP_OK) {
    Serial.printf("Camera init failed with error 0x%x", err);
  }
}

void reconnectMQTT() {
  while (!mqttClient.connected()) {
    Serial.print("MQTT connecting...");
    if(mqttClient.connect("ESP32CAMClient")) {
      Serial.println("connected");
      mqttClient.subscribe(mqtt_topic);
    } else {
      Serial.print("failed, rc=");
      Serial.print(mqttClient.state());
      Serial.println(" try again in 5 seconds");
      delay(5000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  Serial.println();

  // 使用 WiFiManager 自動建立 AP 讓使用者設定 Wi-Fi
  wifiManager.autoConnect("ESP32CAM-Setup");
  Serial.println("WiFi connected");
  Serial.println(WiFi.localIP());

  initCameraConfig();

  mqttClient.setServer(mqtt_server, mqtt_port);
  // 調大緩衝區（例如 16384 bytes），根據您 JPEG 大小調整
  mqttClient.setBufferSize(26384);

  // 初始連線 MQTT
  reconnectMQTT();
}

void loop() {
  if (!mqttClient.connected()) {
    reconnectMQTT();
  }
  mqttClient.loop();

  unsigned long now = millis();
  if(now - lastPublish > publishInterval) {
    lastPublish = now;
    camera_fb_t * fb = esp_camera_fb_get();
    if (!fb) {
      Serial.println("Camera capture failed");
      return;
    }
    // 發佈 JPEG 影像，直接發佈二進位資料
    bool success = mqttClient.publish(mqtt_topic, fb->buf, fb->len, false);
    if(success) {
      Serial.printf("Published image, size: %d bytes\n", fb->len);
    } else {
      Serial.println("Failed to publish image");
    }
    esp_camera_fb_return(fb);
  }
}
