#include "esp_camera.h"
#include <WiFi.h>
#include <WiFiManager.h>    // https://github.com/tzapu/WiFiManager
#include <WebServer.h>

// ====== AI-Thinker ESP32-CAM Pin 定義 ======
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

// 建立 WebServer 物件 (HTTP 端口 80)
WebServer server(80);

// ----- 影像串流處理函式 -----
void handle_jpg_stream() {
  WiFiClient client = server.client();
  String response = "HTTP/1.1 200 OK\r\n";
  response += "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n";
  server.sendContent(response);

  while (1) {
    camera_fb_t * fb = esp_camera_fb_get();
    if (!fb) {
      Serial.println("Camera capture failed");
      return;
    }
    response = "--frame\r\n";
    response += "Content-Type: image/jpeg\r\n\r\n";
    server.sendContent(response);
    client.write(fb->buf, fb->len);
    server.sendContent("\r\n");
    esp_camera_fb_return(fb);

    if (!client.connected()) break;
  }
}

// ----- 啟動攝影機 Web 伺服器 -----
void startCameraServer(){
  server.on("/", HTTP_GET, [](){
    server.send(200, "text/html", "<html><body><img src='/stream'></body></html>");
  });
  server.on("/stream", HTTP_GET, handle_jpg_stream);
  server.begin();
  Serial.println("Camera Stream Server started");
}

void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  
  // ----- WiFiManager 連線 -----
  WiFiManager wifiManager;
  // 若需要重設 WiFi 設定，可呼叫 wifiManager.resetSettings();
  if (!wifiManager.autoConnect("ESP32-CAM")) {
    Serial.println("WiFi 連線失敗，重新啟動");
    ESP.restart();
    delay(1000);
  }
  Serial.println("WiFi Connected!");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());

  // ----- 攝影機初始化設定 -----
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
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  
  // 若有 PSRAM 可設定較高解析度，否則選擇較低的
  if(psramFound()){
    config.frame_size = FRAMESIZE_XGA; // 640x480
    config.jpeg_quality = 20;
    config.fb_count = 2;
  } else {
    config.frame_size = FRAMESIZE_SVGA; // 352x288
    config.jpeg_quality = 20;
    config.fb_count = 2;
  }
  
  // 初始化攝影機
  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed with error 0x%x", err);
    return;
  }
  
  // 啟動攝影機串流伺服器
  startCameraServer();
  Serial.println("請在瀏覽器輸入 http://[ESP32-CAM_IP]/stream 以觀看串流");
}

void loop() {
  server.handleClient();
  delay(1);
}
