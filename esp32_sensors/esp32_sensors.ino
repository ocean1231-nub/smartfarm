/* ============================================================
   스마트팜 ESP32 (ESP32-WROOM-32) — 센서 → Supabase sensor_data
   센서: DFRobot Gravity pH V2.0 (SEN0161-V2, H-101 전극)
         DFRobot Gravity TDS Meter V1.0 (SEN0244)  → EC(µS/cm)
         DHT22 (온도/습도, 온도는 EC 온도보상에도 사용)

   배선 (센서 보드 3핀: 신호/전원/GND — 보드 실크 확인할 것)
     pH  보드  A(신호) → GPIO34   + → 5V(VIN)   - → GND
     TDS 보드  A(신호) → GPIO35   + → 5V(VIN)   - → GND
       (둘 다 ADC1 핀. GPIO32~39만 쓸 것: ADC2는 WiFi와 충돌)
       (출력이 pH 0~3.0V / TDS 0~2.3V라 3.3V 입력에 직결해도 안전)
     DHT22 데이터 → DHT_PIN
   ★ 라이브러리: "DHT sensor library"(Adafruit) + "Adafruit Unified Sensor"
   ★ 보드: ESP32 Dev Module
   ============================================================ */
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <DHT.h>

// ───────── 1. 사용자 설정 ─────────
// ⚠ ESP32는 2.4GHz만 지원. "_5G" 공유기는 연결 안 됨 → 2.4GHz 이름이 따로 있으면 그걸로 바꿀 것
const char* WIFI_SSID = "adminoffice_2.4G";
// 비번 후보를 차례로 시도 (맞는 걸 알면 하나만 남길 것)
const char* WIFI_PASSES[] = {"12341234"};   // 확인됨(2026-11-12). 틀린 비번 반복 시 공유기가 잠시 차단(202)
const int   WIFI_PASS_COUNT = 1;
const unsigned long WIFI_RETRY_MS = 60000;   // 실패 시 1분 뒤 재시도
unsigned long lastWifiTry = 0;

const char* SUPABASE_URL = "https://eoioozljabtxxhzpjrnu.supabase.co";
const char* SUPABASE_KEY = "sb_publishable_X7UQkWJI5H_8IocFdOUiHQ_malGU24g";   // Publishable key만. Secret key 금지

#define PIN_PH   34
#define PIN_EC   35
#define DHT_PIN  4     // (GPIO36은 입력전용이라 DHT22 불가 → 4번 사용)
#define DHT_TYPE DHT22

const unsigned long POST_INTERVAL_MS = 5000;   // 5초마다 한 행

// ───────── 2. pH 보정값 (DFRobot 공식 방식, 2점 보정) ─────────
// 기본값은 DFRobot 출고 기준. pH 7.00 / 4.01 완충액에 담가서 시리얼로 mV를 보고
// 아래 두 값을 고치면 된다. (명령: 시리얼에 "cal7" / "cal4" 입력 → 자동 저장)
float PH_NEUTRAL_MV = 1500.0;   // pH 7.0일 때 mV
float PH_ACID_MV    = 2032.0;   // pH 4.0일 때 mV

// ───────── 3. EC 보정 ─────────
// TDS Meter 공식으로 EC(µS/cm) 계산 (2026-11-12 mS→µS 단위 변경). 기준용액(1413µS/cm)으로 확인 후
// 실측이 다르면 이 배율만 조정 (예: 1413인데 1300 나오면 1413/1300).
float EC_SCALE = 1.0;

// ───────── 4. 내부 ─────────
DHT dht(DHT_PIN, DHT_TYPE);
Preferences prefs;
unsigned long lastPost = 0;

// 노이즈 줄이려고 여러 번 읽어 중앙값 → mV (ESP32 보정 ADC)
float readMilliVolts(int pin) {
  const int N = 25;
  int v[N];
  for (int i = 0; i < N; i++) { v[i] = analogReadMilliVolts(pin); delay(8); }
  for (int i = 1; i < N; i++) {            // 삽입정렬
    int k = v[i], j = i - 1;
    while (j >= 0 && v[j] > k) { v[j + 1] = v[j]; j--; }
    v[j + 1] = k;
  }
  float sum = 0;                           // 가운데 11개 평균
  for (int i = 7; i < 18; i++) sum += v[i];
  return sum / 11.0;
}

float phFromMv(float mv) {
  float slope = (7.0 - 4.0) / ((PH_NEUTRAL_MV - 1500.0) / 3.0 - (PH_ACID_MV - 1500.0) / 3.0);
  float intercept = 7.0 - slope * (PH_NEUTRAL_MV - 1500.0) / 3.0;
  return slope * (mv - 1500.0) / 3.0 + intercept;
}

// 반환: µS/cm. tempC는 온도보상용
float ecFromMv(float mv, float tempC) {
  float v = mv / 1000.0;
  float comp = 1.0 + 0.02 * (tempC - 25.0);
  float vc = v / comp;
  float us = 133.42 * vc * vc * vc - 255.86 * vc * vc + 857.39 * vc;   // µS/cm
  if (us < 0) us = 0;
  return us * EC_SCALE;
}

void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  Serial.print("WiFi 연결 중");
  WiFi.mode(WIFI_STA);
  for (int k = 0; k < WIFI_PASS_COUNT && WiFi.status() != WL_CONNECTED; k++) {
    Serial.printf("\n[%s] 비번 후보 %d 시도", WIFI_SSID, k + 1);
    WiFi.disconnect(); delay(300);
    WiFi.begin(WIFI_SSID, WIFI_PASSES[k]);
    for (int i = 0; i < 20 && WiFi.status() != WL_CONNECTED; i++) { delay(500); Serial.print("."); }
  }
  if (WiFi.status() == WL_CONNECTED) { Serial.println(" 연결됨"); return; }
  Serial.println(" 실패(다음 주기에 재시도)");
  // 실패 시 주변 와이파이 목록 출력 (2.4GHz 이름 찾기용, 채널 1~13이 2.4GHz)
  WiFi.disconnect(); delay(500);
  int n = WiFi.scanNetworks();
  Serial.printf("주변 와이파이 %d개:\n", n);
  for (int i = 0; i < n; i++) Serial.printf("  %s  (채널 %d, %d dBm)\n", WiFi.SSID(i).c_str(), WiFi.channel(i), WiFi.RSSI(i));
}

bool postRow(float ph, float ec, float temp, float hum) {
  if (WiFi.status() != WL_CONNECTED) return false;
  WiFiClientSecure client;
  client.setInsecure();            // 공개 센서값만 보내므로 인증서 검증 생략
  HTTPClient http;
  String url = String(SUPABASE_URL) + "/rest/v1/sensor_data";
  http.begin(client, url);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_KEY);
  http.addHeader("Prefer", "return=minimal");
  String body = "{\"PH\":" + String(ph, 2) + ",\"EC\":" + String(ec, 1);
  if (!isnan(temp)) body += ",\"온도\":" + String(temp, 1);
  if (!isnan(hum))  body += ",\"습도\":" + String(hum, 1);
  body += "}";
  int code = http.POST(body);
  Serial.printf("POST %d  %s\n", code, body.c_str());
  http.end();
  return code >= 200 && code < 300;
}

// 시리얼 명령: cal7 / cal4 (지금 pH 전극이 담긴 완충액 기준으로 보정 저장), show
void handleSerial() {
  if (!Serial.available()) return;
  String cmd = Serial.readStringUntil('\n'); cmd.trim();
  if (cmd == "cal7") {
    PH_NEUTRAL_MV = readMilliVolts(PIN_PH);
    prefs.putFloat("neutral", PH_NEUTRAL_MV);
    Serial.printf("pH7 보정 저장: %.0f mV\n", PH_NEUTRAL_MV);
  } else if (cmd == "cal4") {
    PH_ACID_MV = readMilliVolts(PIN_PH);
    prefs.putFloat("acid", PH_ACID_MV);
    Serial.printf("pH4 보정 저장: %.0f mV\n", PH_ACID_MV);
  } else if (cmd == "show") {
    Serial.printf("neutral=%.0f acid=%.0f ecScale=%.3f\n", PH_NEUTRAL_MV, PH_ACID_MV, EC_SCALE);
  }
}

void setup() {
  Serial.begin(115200);
  analogReadResolution(12);
  analogSetPinAttenuation(PIN_PH, ADC_11db);
  analogSetPinAttenuation(PIN_EC, ADC_11db);
  dht.begin();

  prefs.begin("smartfarm", false);
  PH_NEUTRAL_MV = prefs.getFloat("neutral", PH_NEUTRAL_MV);
  PH_ACID_MV    = prefs.getFloat("acid", PH_ACID_MV);

  connectWifi();
  Serial.println("명령: cal7 (pH7 완충액에 담근 채) / cal4 (pH4 완충액) / show");
}

void loop() {
  handleSerial();
  if (millis() - lastPost < POST_INTERVAL_MS) return;
  lastPost = millis();

  if (WiFi.status() != WL_CONNECTED && millis() - lastWifiTry > WIFI_RETRY_MS) { lastWifiTry = millis(); connectWifi(); }

  float temp = dht.readTemperature();
  float hum  = dht.readHumidity();
  float tcomp = isnan(temp) ? 25.0 : temp;

  float phMv = readMilliVolts(PIN_PH);
  float ecMv = readMilliVolts(PIN_EC);
  float ph = phFromMv(phMv);
  float ec = ecFromMv(ecMv, tcomp);

  Serial.printf("pH %.2f (%.0f mV) | EC %.1f µS/cm (%.0f mV) | %.1f°C %.1f%%\n",
                ph, phMv, ec, ecMv, temp, hum);

  // 비정상 값(센서 미연결 등)은 DB에 올리지 않음
  if (ph < 0 || ph > 14) { Serial.println("pH 범위 밖 → 전송 생략"); return; }
  postRow(ph, ec, temp, hum);
}
