#include <WiFi.h>
#include <WebServer.h>
#include <WiFiClient.h>
#include "OV2640.h"           // OV2640 驅動
#include "SimStreamer.h"
#include "OV2640Streamer.h"
#include "CRtspSession.h"

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

// WiFi 與 HTTP/RTSP 服務設定
const char* ssid = "Your_SSID";
const char* password = "Your_PASSWORD";

WebServer httpServer(80);
WiFiServer rtspServer(554);

// 建立 OV2640 攝影機物件
OV2640 cam;
// Micro-RTSP 的串流器需要傳入攝影機指標，所以這裡傳 &cam
CStreamer *streamer = nullptr;

//////////////////////////////////
// HTTP 處理函式 (MJPEG 串流與 Snapshot)
//////////////////////////////////
void handle_jpg_stream() {
  WiFiClient client = httpServer.client();
  String response = "HTTP/1.1 200 OK\r\n";
  response += "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n";
  httpServer.sendContent(response);
  while(client.connected()) {
    cam.run();
    String part = "--frame\r\nContent-Type: image/jpeg\r\n\r\n";
    client.write(part.c_str(), part.length());
    client.write((char*)cam.getfb(), cam.getSize());
    client.write("\r\n", 2);
    // 避免過度阻塞，可略加延遲
    delay(10);
  }
}

void handle_jpg() {
  WiFiClient client = httpServer.client();
  cam.run();
  if(!client.connected()) return;
  String response = "HTTP/1.1 200 OK\r\n";
  response += "Content-disposition: inline; filename=capture.jpg\r\n";
  response += "Content-type: image/jpeg\r\n\r\n";
  httpServer.sendContent(response);
  client.write((char*)cam.getfb(), cam.getSize());
}

void handleNotFound() {
  httpServer.send(200, "text/plain", "ESP32-CAM RTSP Server\nUse /stream or /jpg");
}

//////////////////////////////////
// WiFi 連線函式
//////////////////////////////////
void wifiConnect() {
  Serial.printf("Connecting to %s\n", ssid);
  WiFi.begin(ssid, password);
  while(WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWiFi connected!");
  Serial.print("IP address: ");
  Serial.println(WiFi.localIP());
}

//////////////////////////////////
// Setup 函式
//////////////////////////////////
void setup() {
  Serial.begin(115200);
  delay(100);

  // 連線 WiFi
  wifiConnect();

  // 設定 HTTP 伺服器路由
  httpServer.on("/", HTTP_GET, handle_jpg_stream);
  httpServer.on("/stream", HTTP_GET, handle_jpg_stream);
  httpServer.on("/jpg", HTTP_GET, handle_jpg);
  httpServer.onNotFound(handleNotFound);
  httpServer.begin();

  // 啟動 RTSP 伺服器
  rtspServer.begin();

  // 設定相機參數
  // 可根據需求調整 frame_size, jpeg_quality 等。
  esp32cam_aithinker_config.frame_size = FRAMESIZE_SVGA; // 800x600, 可測試其他值
  esp32cam_aithinker_config.jpeg_quality = 12; // 0~63, 數字越小畫質越好，但檔案越大
  esp32cam_aithinker_config.fb_count = 1;
  cam.init(esp32cam_aithinker_config);

  // 建立 RTSP 串流物件，傳入攝影機指標
  streamer = new OV2640Streamer(&cam);
  Serial.println("Setup done!");
  Serial.print("HTTP MJPEG Stream: http://");
  Serial.print(WiFi.localIP());
  Serial.println("/stream");
  Serial.print("HTTP Snapshot: http://");
  Serial.print(WiFi.localIP());
  Serial.println("/jpg");
  Serial.print("RTSP: rtsp://");
  Serial.print(WiFi.localIP());
  Serial.println(":554/mjpeg/1");
}

//////////////////////////////////
// Loop 函式
//////////////////////////////////
void loop() {
  // 處理 HTTP 請求
  httpServer.handleClient();

  // 處理 RTSP 連線：接收新連線
  WiFiClient rtspClientObj = rtspServer.accept();
  if(rtspClientObj) {
    Serial.print("RTSP client connected from ");
    Serial.println(rtspClientObj.remoteIP());
    // 由於 addSession 需要傳入 WiFiClient* (指標)，
    // 我們在此分配新的 WiFiClient 物件，並把值複製過去
    WiFiClient* pRtspClient = new WiFiClient(rtspClientObj);
    streamer->addSession(pRtspClient);
  }

  // 處理現有 RTSP 連線
  streamer->handleRequests(0);

  // 定時傳送新影像 (例如約 10FPS，每 100ms 一幀)
  static uint32_t lastFrameTime = millis();
  uint32_t now = millis();
  if(now - lastFrameTime >= 100) {
    streamer->streamImage(now);
    lastFrameTime = now;
  }
}
