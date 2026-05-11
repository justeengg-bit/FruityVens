// ============================================================
//  FruityVens ESP32-CAM Eye
//  DIYMORE ESP32-CAM / OV2640
//
//  Arduino IDE board: "AI Thinker ESP32-CAM"
//  Mode: Access Point + direct camera endpoints only
//
//  AP SSID: FruityVens
//  AP IP:   192.168.4.1
//
//  Direct backend endpoints:
//    http://192.168.4.1:81/stream  MJPEG stream for camera-eye processing
//    http://192.168.4.1:81/jpg     Single JPEG frame for YOLO snapshots
//    http://192.168.4.1:81/status  Lightweight health check
//
//  No hosted web page is served. The camera is used as an eye for
//  FruityVens/backend AI only.
// ============================================================

#include "esp_camera.h"
#include "esp_http_server.h"
#include <WiFi.h>

// ------------------------------------------------------------
//  AP credentials
// ------------------------------------------------------------
const char* AP_SSID = "FruityVens";
const char* AP_PASSWORD = "1234";

IPAddress AP_IP(192, 168, 4, 1);
IPAddress AP_GATEWAY(192, 168, 4, 1);
IPAddress AP_SUBNET(255, 255, 255, 0);

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

// ------------------------------------------------------------
//  MJPEG stream constants
// ------------------------------------------------------------
#define PART_BOUNDARY "123456789000000000000987654321"

static const char* STREAM_CONTENT_TYPE =
    "multipart/x-mixed-replace;boundary=" PART_BOUNDARY;
static const char* STREAM_BOUNDARY = "\r\n--" PART_BOUNDARY "\r\n";
static const char* STREAM_PART =
    "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

httpd_handle_t camera_httpd = NULL;

// ------------------------------------------------------------
//  Helpers
// ------------------------------------------------------------
void addCorsHeaders(httpd_req_t* req) {
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
}

// ------------------------------------------------------------
//  Direct MJPEG stream: /stream
// ------------------------------------------------------------
static esp_err_t streamHandler(httpd_req_t* req) {
  camera_fb_t* fb = NULL;
  esp_err_t res = ESP_OK;
  char part_buf[64];

  res = httpd_resp_set_type(req, STREAM_CONTENT_TYPE);
  if (res != ESP_OK) {
    return res;
  }
  addCorsHeaders(req);

  while (true) {
    fb = esp_camera_fb_get();
    if (!fb) {
      Serial.println("[CAM] Frame capture failed");
      return ESP_FAIL;
    }

    res = httpd_resp_send_chunk(req, STREAM_BOUNDARY, strlen(STREAM_BOUNDARY));
    if (res != ESP_OK) {
      esp_camera_fb_return(fb);
      break;
    }

    size_t hlen = snprintf(part_buf, sizeof(part_buf), STREAM_PART, fb->len);
    res = httpd_resp_send_chunk(req, part_buf, hlen);
    if (res != ESP_OK) {
      esp_camera_fb_return(fb);
      break;
    }

    res = httpd_resp_send_chunk(req, (const char*)fb->buf, fb->len);
    esp_camera_fb_return(fb);
    if (res != ESP_OK) {
      break;
    }

    delay(25);
  }

  return res;
}

// ------------------------------------------------------------
//  Single JPEG frame: /jpg
// ------------------------------------------------------------
static esp_err_t jpgHandler(httpd_req_t* req) {
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
  char payload[180];
  snprintf(
      payload,
      sizeof(payload),
      "{\"ok\":true,\"device\":\"FruityVens ESP32-CAM Eye\","
      "\"ssid\":\"%s\",\"stream\":\"/stream\",\"snapshot\":\"/jpg\","
      "\"clients\":%d}",
      AP_SSID,
      WiFi.softAPgetStationNum());

  httpd_resp_set_type(req, "application/json");
  addCorsHeaders(req);
  return httpd_resp_send(req, payload, HTTPD_RESP_USE_STRLEN);
}

// ------------------------------------------------------------
//  Start direct camera-eye endpoints
// ------------------------------------------------------------
void startCameraEyeEndpoints() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 81;
  config.ctrl_port = 32769;
  config.max_uri_handlers = 3;
  config.recv_wait_timeout = 10;
  config.send_wait_timeout = 10;

  httpd_uri_t stream_uri = {};
  stream_uri.uri = "/stream";
  stream_uri.method = HTTP_GET;
  stream_uri.handler = streamHandler;

  httpd_uri_t jpg_uri = {};
  jpg_uri.uri = "/jpg";
  jpg_uri.method = HTTP_GET;
  jpg_uri.handler = jpgHandler;

  httpd_uri_t status_uri = {};
  status_uri.uri = "/status";
  status_uri.method = HTTP_GET;
  status_uri.handler = statusHandler;

  if (httpd_start(&camera_httpd, &config) != ESP_OK) {
    Serial.println("[HTTP] Camera endpoint failed to start");
    return;
  }

  httpd_register_uri_handler(camera_httpd, &stream_uri);
  httpd_register_uri_handler(camera_httpd, &jpg_uri);
  httpd_register_uri_handler(camera_httpd, &status_uri);

  Serial.println("[HTTP] Direct camera-eye endpoints ready on port 81");
  Serial.println("[HTTP] Stream:   http://192.168.4.1:81/stream");
  Serial.println("[HTTP] Snapshot: http://192.168.4.1:81/jpg");
  Serial.println("[HTTP] Status:   http://192.168.4.1:81/status");
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
  config.pin_sscb_sda = SIOD_GPIO_NUM;
  config.pin_sscb_scl = SIOC_GPIO_NUM;
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
//  Access point setup
// ------------------------------------------------------------
bool setupAccessPoint() {
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(AP_IP, AP_GATEWAY, AP_SUBNET);

  bool started = false;
  if (strlen(AP_PASSWORD) >= 8) {
    started = WiFi.softAP(AP_SSID, AP_PASSWORD);
  } else {
    started = WiFi.softAP(AP_SSID);
    Serial.println("[WiFi] WPA password must be 8+ chars; using open AP.");
    Serial.printf("[WiFi] Requested short password was: %s\n", AP_PASSWORD);
  }

  if (!started) {
    Serial.println("[WiFi] AP failed");
    return false;
  }

  Serial.printf("[WiFi] AP SSID: %s\n", AP_SSID);
  Serial.printf("[WiFi] AP IP:   %s\n", WiFi.softAPIP().toString().c_str());
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
    return;
  }
  if (!setupAccessPoint()) {
    return;
  }

  startCameraEyeEndpoints();

  Serial.println("[READY] Connect phone/backend to SSID FruityVens");
  Serial.println("[READY] Use direct endpoint http://192.168.4.1:81/stream");
}

void loop() {
  static unsigned long lastLog = 0;
  if (millis() - lastLog > 10000) {
    lastLog = millis();
    Serial.printf("[WiFi] Connected clients: %d\n", WiFi.softAPgetStationNum());
  }
  delay(100);
}
