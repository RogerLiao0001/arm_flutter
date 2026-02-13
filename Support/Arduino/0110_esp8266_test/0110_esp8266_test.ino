#include <ESP8266WiFi.h>

// WiFi 設定
const char* ssid = "7530_2.4";  // WiFi 名稱
const char* password = "";      // WiFi 無密碼 (若有密碼請填入)

// 建立 Web 伺服器 (HTTP 80 port)
WiFiServer server(80);

void setup() {
  Serial.begin(115200);
  delay(100);

  Serial.println();
  Serial.print("正在連線到 WiFi: ");
  Serial.println(ssid);

  WiFi.mode(WIFI_STA);  // 設定 ESP8266 為 WiFi 用戶端模式
  WiFi.begin(ssid, password);

  // 等待 WiFi 連線
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }

  Serial.println("\nWiFi 連線成功！");
  Serial.print("ESP8266 IP 地址: ");
  Serial.println(WiFi.localIP());  // 顯示 IP

  server.begin();  // 啟動 Web Server
  Serial.println("HTTP 伺服器已啟動！");
}

void loop() {
  // 檢查 WiFi 連線狀態
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi 斷線，重新連線...");
    WiFi.disconnect();
    WiFi.begin(ssid, password);
    delay(5000);
    return;
  }

  WiFiClient client = server.available(); // 等待客戶端連線
  if (!client) { return; }  // 沒有連線時，回到 loop

  Serial.println("新客戶端連線！");

  // 等待客戶端發送請求
  while (client.connected()) {
    if (client.available()) {
      String request = client.readStringUntil('\r');  // 讀取客戶端請求
      Serial.print("收到請求: ");
      Serial.println(request);
      client.flush();

      // HTTP 回應標頭
      client.println("HTTP/1.1 200 OK");
      client.println("Content-Type: text/html");
      client.println("Connection: close");
      client.println();
      
      // 回應 HTML 內容
      client.println("<!DOCTYPE HTML>");
      client.println("<html>");
      client.println("<h2>ESP8266 Web Server 測試</h2>");
      client.println("<p>點擊以下連結控制 GPIO:</p>");
      client.println("<a href=\"/gpio/1\">開啟 GPIO</a><br>");
      client.println("<a href=\"/gpio/0\">關閉 GPIO</a>");
      client.println("</html>");

      break;  // 處理完請求後離開 while
    }
  }

  // 斷開客戶端連線
  delay(100);
  client.stop();
  Serial.println("客戶端已斷線。");
}
