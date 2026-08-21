// ============================================================
//  FruityVens ESP32-CAM Eye
//  DIYMORE ESP32-CAM / OV2640
//
//  Arduino IDE board: "AI Thinker ESP32-CAM"
//  Mode: Wi-Fi station + camera endpoints for the Flutter app
//
//  Wi-Fi SSID: Parafiber_F0C0 2.4G
//  Camera IP: 192.168.1.34
//
//  Flutter-compatible endpoints:
//    http://192.168.1.34/snapshot.jpg
//    http://192.168.1.34/status
//    http://192.168.1.34/preview/start
//    http://192.168.1.34/preview/stop
//
//  No hosted web page is served. The camera is used as an eye for
//  FruityVens/backend AI only.
// ============================================================

#include "esp_camera.h"
#include "esp_http_server.h"
#include <WiFi.h>

// ------------------------------------------------------------
//  Router credentials. Replace WIFI_PASSWORD before flashing.
// ------------------------------------------------------------
const char* WIFI_SSID = "Parafiber_F0C0 2.4G";
const char* WIFI_PASSWORD = "CHANGE_ME";

IPAddress LOCAL_IP(192, 168, 1, 34);
IPAddress GATEWAY(192, 168, 1, 1);
IPAddress SUBNET(255, 255, 255, 0);
IPAddress DNS(192, 168, 1, 1);

// ------------------------------------------------------------
//  DIYMORE ESP32-CAM (CH340X) pin map
// ------------------------------------------------------------
#define PWDN_GPIO_NUM   -1
#define RESET_GPIO_NUM   5
#define XCLK_GPIO_NUM   15
#define SIOD_GPIO_NUM   22
#define SIOC_GPIO_NUM   23
#define Y9_GPIO_NUM     39
#define Y8_GPIO_NUM     34
#define Y7_GPIO_NUM     33
#define Y6_GPIO_NUM     27
#define Y5_GPIO_NUM     12
#define Y4_GPIO_NUM     35
#define Y3_GPIO_NUM     14
#define Y2_GPIO_NUM      2
#define VSYNC_GPIO_NUM  18
#define HREF_GPIO_NUM   36
#define PCLK_GPIO_NUM   26

// AI Thinker-style flash LED. Kept OFF; the app does not use camera flash.
#define FLASH_LED_GPIO   4

httpd_handle_t camera_httpd = NULL;
volatile bool previewEnabled = false;

// ------------------------------------------------------------
//  Helpers
// ------------------------------------------------------------
void addCorsHeaders(httpd_req_t* req) {
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
}

// ------------------------------------------------------------
//  Single JPEG frame: /snapshot.jpg
// ------------------------------------------------------------
static esp_err_t jpgHandler(httpd_req_t* req) {
  if (!previewEnabled) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    httpd_resp_set_type(req, "application/json");
    addCorsHeaders(req);
    return httpd_resp_sendstr(req, "{\"ok\":false,\"error\":\"preview is stopped\"}");
  }

  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("[CAM] JPEG capture failed");
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }

  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Content-Disposition", "inline; filename=fruityvens.jpg");
  addCorsHeaders(req);

  esp_err_t res = httpd_resp_send(req, (const char*)fb->buf, fb->len);
  esp_camera_fb_return(fb);
  return res;
}

// ------------------------------------------------------------
//  Health/status endpoint: /status
// ------------------------------------------------------------
static esp_err_t statusHandler(httpd_req_t* req) {
  char payload[240];
  snprintf(
      payload,
      sizeof(payload),
      "{\"ok\":true,\"device\":\"FruityVens ESP32-CAM Eye\","
      "\"ssid\":\"%s\",\"ip\":\"%s\",\"snapshot\":\"/snapshot.jpg\","
      "\"preview\":%s,\"rssi\":%d}",
      WIFI_SSID,
      WiFi.localIP().toString().c_str(),
      previewEnabled ? "true" : "false",
      WiFi.RSSI());

  httpd_resp_set_type(req, "application/json");
  addCorsHeaders(req);
  return httpd_resp_send(req, payload, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t previewStartHandler(httpd_req_t* req) {
  previewEnabled = true;
  httpd_resp_set_type(req, "application/json");
  addCorsHeaders(req);
  return httpd_resp_sendstr(req, "{\"ok\":true,\"preview\":true}");
}

static esp_err_t previewStopHandler(httpd_req_t* req) {
  previewEnabled = false;
  httpd_resp_set_type(req, "application/json");
  addCorsHeaders(req);
  return httpd_resp_sendstr(req, "{\"ok\":true,\"preview\":false}");
}

// ------------------------------------------------------------
//  Start direct camera-eye endpoints
// ------------------------------------------------------------
bool startCameraEyeEndpoints() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;
  config.ctrl_port = 32769;
  config.max_uri_handlers = 4;
  config.recv_wait_timeout = 10;
  config.send_wait_timeout = 10;

  httpd_uri_t jpg_uri = {};
  jpg_uri.uri = "/snapshot.jpg";
  jpg_uri.method = HTTP_GET;
  jpg_uri.handler = jpgHandler;

  httpd_uri_t status_uri = {};
  status_uri.uri = "/status";
  status_uri.method = HTTP_GET;
  status_uri.handler = statusHandler;

  httpd_uri_t preview_start_uri = {};
  preview_start_uri.uri = "/preview/start";
  preview_start_uri.method = HTTP_GET;
  preview_start_uri.handler = previewStartHandler;

  httpd_uri_t preview_stop_uri = {};
  preview_stop_uri.uri = "/preview/stop";
  preview_stop_uri.method = HTTP_GET;
  preview_stop_uri.handler = previewStopHandler;

  if (httpd_start(&camera_httpd, &config) != ESP_OK) {
    Serial.println("[HTTP] Camera endpoint failed to start");
    return false;
  }

  httpd_register_uri_handler(camera_httpd, &jpg_uri);
  httpd_register_uri_handler(camera_httpd, &status_uri);
  httpd_register_uri_handler(camera_httpd, &preview_start_uri);
  httpd_register_uri_handler(camera_httpd, &preview_stop_uri);

  Serial.println("[HTTP] Camera endpoints ready on port 80");
  Serial.println("[HTTP] Snapshot: http://192.168.1.34/snapshot.jpg");
  Serial.println("[HTTP] Status:   http://192.168.1.34/status");
  return true;
}

// ------------------------------------------------------------
//  Camera setup
// ------------------------------------------------------------
bool setupCamera() {
  camera_config_t config = {};
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
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 4000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_QVGA;
  config.jpeg_quality = 12;
  config.fb_count = 2;

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("[CAM] Init failed: 0x%x\n", err);
    return false;
  }

  sensor_t* sensor = esp_camera_sensor_get();
  sensor->set_hmirror(sensor, 0);
  sensor->set_vflip(sensor, 0);
  sensor->set_whitebal(sensor, 1);
  sensor->set_exposure_ctrl(sensor, 1);
  sensor->set_gain_ctrl(sensor, 1);

  Serial.println("[CAM] Ready | QVGA | JPEG quality 12 | dual frame buffer");
  return true;
}

// ------------------------------------------------------------
//  Router connection
// ------------------------------------------------------------
bool setupWifi() {
  if (strcmp(WIFI_PASSWORD, "CHANGE_ME") == 0) {
    Serial.println("[WiFi] Set WIFI_PASSWORD in the sketch before flashing");
    return false;
  }

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  if (!WiFi.config(LOCAL_IP, GATEWAY, SUBNET, DNS)) {
    Serial.println("[WiFi] Static IP configuration failed");
    return false;
  }

  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.printf("[WiFi] Connecting to %s", WIFI_SSID);
  const unsigned long startedAt = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - startedAt < 20000) {
    delay(500);
    Serial.print('.');
  }
  Serial.println();

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WiFi] Connection timed out; restarting in 5 seconds");
    delay(5000);
    ESP.restart();
  }

  Serial.printf("[WiFi] Connected, IP: %s\n", WiFi.localIP().toString().c_str());
  return true;
}

// ------------------------------------------------------------
//  Arduino setup / loop
// ------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(300);

  pinMode(FLASH_LED_GPIO, OUTPUT);
  digitalWrite(FLASH_LED_GPIO, LOW);

  Serial.println();
  Serial.println("[BOOT] FruityVens ESP32-CAM Eye starting");

  if (!setupCamera()) {
    Serial.println("[BOOT] Camera setup failed; restarting in 5 seconds");
    delay(5000);
    ESP.restart();
    return;
  }
  if (!setupWifi()) {
    return;
  }

  if (!startCameraEyeEndpoints()) {
    delay(5000);
    ESP.restart();
    return;
  }

  Serial.println("[READY] Camera available at http://192.168.1.34");
}

void loop() {
  static unsigned long disconnectedAt = 0;
  if (WiFi.status() != WL_CONNECTED) {
    if (disconnectedAt == 0) {
      disconnectedAt = millis();
      Serial.println("[WiFi] Connection lost; reconnecting");
      WiFi.reconnect();
    } else if (millis() - disconnectedAt > 15000) {
      ESP.restart();
    }
  } else {
    disconnectedAt = 0;
  }
  delay(100);
}
