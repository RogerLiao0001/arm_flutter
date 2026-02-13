/*
  ESP32-CAM CameraWebServer + WiFiManager (精簡版)
  - 使用者可透過 WiFiManager 動態設定 Wi-Fi 帳密
  - 成功連線後，提供 /stream 串流
  - 移除 dl_lib.h、fd_forward.h、fr_forward.h、fb_gfx.h 等，以避免編譯錯誤

  請先在「庫管理員」安裝 WiFiManager (by tzapu)
  在「工具 → 開發板」選擇 ESP32 Dev Module 或 AI Thinker ESP32-CAM
  Partition Scheme 建議用 Huge APP，避免空間不足
*/

#include <esp_camera.h>
#include <WiFi.h>
#include <WiFiManager.h>       // WiFiManager by tzapu
#include <esp_http_server.h>
#include <esp_timer.h>
#include <img_converters.h>    // 基本影像轉換函式

// 選擇相機模組，預設 AI THINKER
#define CAMERA_MODEL_AI_THINKER
//#define CAMERA_MODEL_WROVER_KIT
//#define CAMERA_MODEL_ESP_EYE
//#define CAMERA_MODEL_M5STACK_PSRAM
//#define CAMERA_MODEL_M5STACK_V2_PSRAM
//#define CAMERA_MODEL_M5STACK_WIDE
//#define CAMERA_MODEL_M5STACK_ESP32CAM

#if defined(CAMERA_MODEL_AI_THINKER)
  #define PWDN_GPIO_NUM     32
  #define RESET_GPIO_NUM    -1
  #define XCLK_GPIO_NUM     0
  #define SIOD_GPIO_NUM     26
  #define SIOC_GPIO_NUM     27
  #define Y9_GPIO_NUM       35
  #define Y8_GPIO_NUM       34
  #define Y7_GPIO_NUM       39
  #define Y6_GPIO_NUM       36
  #define Y5_GPIO_NUM       21
  #define Y4_GPIO_NUM       19
  #define Y3_GPIO_NUM       18
  #define Y2_GPIO_NUM       5
  #define VSYNC_GPIO_NUM    25
  #define HREF_GPIO_NUM     23
  #define PCLK_GPIO_NUM     22

#elif defined(CAMERA_MODEL_WROVER_KIT)
  #define PWDN_GPIO_NUM    -1
  #define RESET_GPIO_NUM   -1
  #define XCLK_GPIO_NUM    21
  #define SIOD_GPIO_NUM    26
  #define SIOC_GPIO_NUM    27
  #define Y9_GPIO_NUM      35
  #define Y8_GPIO_NUM      34
  #define Y7_GPIO_NUM      39
  #define Y6_GPIO_NUM      36
  #define Y5_GPIO_NUM      19
  #define Y4_GPIO_NUM      18
  #define Y3_GPIO_NUM       5
  #define Y2_GPIO_NUM       4
  #define VSYNC_GPIO_NUM   25
  #define HREF_GPIO_NUM    23
  #define PCLK_GPIO_NUM    22

#else
  #error "請在上面選擇您的 CAMERA_MODEL_X"
#endif

// ====== HTTP MJPEG Streaming Handler ======
static httpd_handle_t camera_httpd = NULL;

static const char* _STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=frame";
static const char* _STREAM_BOUNDARY = "\r\n--frame\r\n";
static const char* _STREAM_PART = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

static esp_err_t stream_handler(httpd_req_t *req){
  httpd_resp_set_type(req, _STREAM_CONTENT_TYPE);
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

  while(true){
    camera_fb_t * fb = esp_camera_fb_get();
    if(!fb){
      Serial.println("Camera capture failed");
      httpd_resp_send_500(req);
      return ESP_FAIL;
    }

    size_t fb_len = fb->len;
    // 若非 JPEG, 需 frame2jpg, 但 AI THINKER 預設即傳 JPEG
    httpd_resp_send_chunk(req, _STREAM_BOUNDARY, strlen(_STREAM_BOUNDARY));
    char header[64];
    int hlen = snprintf(header, 64, _STREAM_PART, fb_len);
    httpd_resp_send_chunk(req, header, hlen);
    httpd_resp_send_chunk(req, (const char*)fb->buf, fb->len);

    esp_camera_fb_return(fb);
  }
  return ESP_OK;
}

static const httpd_uri_t stream_uri = {
  .uri       = "/stream",
  .method    = HTTP_GET,
  .handler   = stream_handler,
  .user_ctx  = NULL
};

void startCameraServer(){
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80; // 使用 80 port
  if(httpd_start(&camera_httpd, &config) == ESP_OK){
    httpd_register_uri_handler(camera_httpd, &stream_uri);
  }
}

// ====== Camera Init ======
esp_err_t initCamera(){
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
  config.frame_size = FRAMESIZE_VGA;      // 可修改 QVGA, VGA, SVGA...
  config.pixel_format = PIXFORMAT_JPEG;  // 使用 JPEG 格式
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.jpeg_quality = 12;  // 0(品質最高)~63(最低)
  config.fb_count = 2;

  // 初始化相機
  esp_err_t err = esp_camera_init(&config);
  if(err != ESP_OK){
    Serial.printf("Camera init failed with error 0x%x\n", err);
    return err;
  }
  return ESP_OK;
}

void setup(){
  Serial.begin(115200);
  Serial.println();

  // STEP 1: 使用 WiFiManager 讓使用者輸入 Wi-Fi 帳密
  WiFiManager wm;
  wm.setDebugOutput(true);  
  wm.setConfigPortalTimeout(120); // 兩分鐘內未配置即結束
  
  bool res = wm.autoConnect("ESP32-CAM-AP"); 
  if(!res) {
    Serial.println("WiFi connect failed or timed out");
    ESP.restart();
  } else {
    Serial.println("WiFi connected! IP:");
    Serial.println(WiFi.localIP());
  }

  // STEP 2: 初始化 Camera
  if(initCamera() != ESP_OK){
    Serial.println("Camera init failed");
    ESP.restart();
  }

  // STEP 3: 啟動 Camera WebServer
  startCameraServer();
  Serial.println("Camera Stream Ready! Go to: http://<this_ip>/stream");
}

void loop(){
  // do nothing
  delay(10);
}
