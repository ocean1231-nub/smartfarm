/* ============================================================
   스마트팜 ESP32 #2 (CH340 보드) — DHT22 온도/습도만 → Supabase sensor_data
   (원래 형이 올린 펌웨어는 PH 6.2 / EC 1.4 고정 테스트값을 같이 보냈음 → 제거)
   pH/EC는 ESP32 #1(esp32_sensors)이 담당.

   DHT22 데이터 핀은 원본 소스가 없어 모름 → 부팅 시 후보 핀을 돌며 자동 탐지.
   찾은 핀은 시리얼에 출력되니, 확인되면 DHT_PIN_FIXED에 적어두면 탐지 생략.
   ============================================================ */
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <DHT.h>

// ESP32 #1(esp32_sensors)과 같은 공유기. 12341234로 연결 확인됨(2026-11-12).
// 틀린 비번을 반복 시도하면 공유기가 잠시 차단(이유 202)하므로 하나만 둔다.
const char* WIFI_SSID = "adminoffice_2.4G";
const char* WIFI_PASSES[] = {"12341234"};
const int   WIFI_PASS_COUNT = 1;
const unsigned long WIFI_RETRY_MS = 60000;   // 실패하면 1분 뒤 재시도
unsigned long lastWifiTry = 0;

const char* SUPABASE_URL = "https://eoioozljabtxxhzpjrnu.supabase.co";
const char* SUPABASE_KEY = "sb_publishable_X7UQkWJI5H_8IocFdOUiHQ_malGU24g";   // Publishable key만

#define DHT_TYPE DHT22
const int DHT_PIN_FIXED = 23;  // 2026-11-12 자동탐지로 확인   // 핀 알면 여기 숫자로 (예: 4). -1이면 자동 탐지
// 후보: 플래시(6~11)·UART0(1,3)·입력전용(34~39) 제외
// 34~39는 입력전용이라 원래 DHT 불가지만, 예전 메모에 "GPIO36"이 있어 마지막에 시도
const int CANDIDATES[] = {4, 15, 5, 2, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33, 36, 39, 34, 35};

const unsigned long POST_INTERVAL_MS = 5000;

DHT* dht = nullptr;
int dhtPin = -1;
unsigned long lastPost = 0;

int detectDhtPin() {
  for (int p : CANDIDATES) {
    DHT t(p, DHT_TYPE);
    t.begin();
    delay(2100);
    float h = t.readHumidity(true);
    float c = t.readTemperature();
    pinMode(p, INPUT);
    Serial.printf("  GPIO%d: %.1f°C %.1f%%\n", p, c, h);
    if (!isnan(h) && !isnan(c)) return p;
  }
  return -1;
}

void setupDht() {
  if (DHT_PIN_FIXED >= 0) dhtPin = DHT_PIN_FIXED;
  else { Serial.println("DHT22 핀 탐지 중..."); dhtPin = detectDhtPin(); }
  if (dhtPin < 0) { Serial.println("DHT22 못 찾음 (배선 확인)"); return; }
  Serial.printf("DHT22 = GPIO%d\n", dhtPin);
  dht = new DHT(dhtPin, DHT_TYPE);
  dht->begin();
}

void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  Serial.print("WiFi 연결 중");
  WiFi.mode(WIFI_STA);
  for (int k = 0; k < WIFI_PASS_COUNT && WiFi.status() != WL_CONNECTED; k++) {
    Serial.printf("\n[%s] 비번 후보 %d", WIFI_SSID, k + 1);
    WiFi.disconnect(); delay(300);
    WiFi.begin(WIFI_SSID, WIFI_PASSES[k]);
    for (int i = 0; i < 20 && WiFi.status() != WL_CONNECTED; i++) { delay(500); Serial.print("."); }
  }
  if (WiFi.status() == WL_CONNECTED) { Serial.printf(" 연결됨 %s\n", WiFi.localIP().toString().c_str()); return; }
  Serial.println(" 실패(다음 주기 재시도)");
  WiFi.disconnect(); delay(300);
  int n = WiFi.scanNetworks();
  Serial.printf("주변 와이파이 %d개:\n", n);
  for (int i = 0; i < n; i++) Serial.printf("  %s (ch%d, %d dBm)\n", WiFi.SSID(i).c_str(), WiFi.channel(i), WiFi.RSSI(i));
}

void postRow(float temp, float hum) {
  if (WiFi.status() != WL_CONNECTED) return;
  WiFiClientSecure client;
  client.setInsecure();
  HTTPClient http;
  http.begin(client, String(SUPABASE_URL) + "/rest/v1/sensor_data");
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_KEY);
  http.addHeader("Prefer", "return=minimal");
  String body = "{\"온도\":" + String(temp, 1) + ",\"습도\":" + String(hum, 1) + "}";
  int code = http.POST(body);
  Serial.printf("POST %d  %s\n", code, body.c_str());
  if (code >= 400) Serial.println("  응답: " + http.getString());
  http.end();
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("\n[ESP32 #2] DHT22 온습도 전용");
  WiFi.onEvent([](WiFiEvent_t e, WiFiEventInfo_t info) {
    Serial.printf("\n  WiFi 끊김 이유=%d\n", info.wifi_sta_disconnected.reason);
  }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
  setupDht();
  connectWifi();
}

void loop() {
  if (millis() - lastPost < POST_INTERVAL_MS) return;
  lastPost = millis();
  if (WiFi.status() != WL_CONNECTED && millis() - lastWifiTry > WIFI_RETRY_MS) {
    lastWifiTry = millis();
    connectWifi();
  }
  if (!dht) {                                   // 못 찾았으면 1분마다 재탐지
    static unsigned long lastScan = 0;
    if (millis() - lastScan > 60000) { lastScan = millis(); setupDht(); }
    return;
  }
  float h = dht->readHumidity();
  float t = dht->readTemperature();
  if (isnan(h) || isnan(t)) {
    Serial.println("DHT22 읽기 실패 → 전송 생략");
    return;
  }
  postRow(t, h);
}
