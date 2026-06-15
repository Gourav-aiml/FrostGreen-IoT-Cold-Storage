/*
  Cold Storage Monitor — ESP32 Firmware (FIXED v2)

  BUGS FIXED:
  ──────────────────────────────────────────────────────────────
  FIX 1 — autoLogic() no longer fights fetchMLPrediction()
           A bool `mlOnline` tracks whether Flask responded
           successfully. autoLogic() is skipped when ML is fresh
           (within last 15 seconds). It only runs as a true
           fallback when Flask is actually unreachable.

  FIX 2 — handleRelay() no longer blocks with 409 in auto mode
           ESP32 now accepts the relay command, applies it, AND
           switches to manual mode automatically.

  FIX 3 — handleStatus() now returns "autoMode" as "auto" field
           Flutter reads this and syncs its own autoMode bool,
           so ESP32 reboot can never desync the two.

  FIX 4 — ML stale timer increased from 10s → 15s
           fetchMLPrediction() is a blocking HTTP call (1–3s).
           server.handleClient() also blocks briefly on each
           Flutter poll (every 3s). Together they caused
           millis() - lastMLSuccess to exceed 10s before the
           next ML response arrived, falsely triggering the
           "ML offline/stale" fallback even when Flask was online.
           15s window comfortably covers all blocking delays.

  FIX 5 — ML fetch interval increased from 5s → 7s
           Staggers the ML HTTP POST away from the 2s sensor
           read + autoLogic() cycle so they don't collide and
           cause the stale window to be hit mid-cycle.
  ──────────────────────────────────────────────────────────────

  WIRING:
    DHT22 sensor 1  → GPIO 4
    DHT22 sensor 2  → GPIO 5
    MQ135 sensor 1  → GPIO 34 (ADC)
    MQ135 sensor 2  → GPIO 35 (ADC)
    Relay 1 (FAN)   → GPIO 25
    Relay 2 (AC)    → GPIO 26
    Relay 3 (HEATER)→ GPIO 27

  LIBRARIES NEEDED (install via Arduino Library Manager):
    - DHT sensor library (Adafruit)
    - Adafruit Unified Sensor
    - ArduinoJson (version 6.x)
    - WebServer (built-in ESP32)
    - HTTPClient (built-in ESP32)
    - WiFi (built-in ESP32)
*/

#include <WiFi.h>
#include <WebServer.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <DHT.h>

// ── CHANGE THESE ──────────────────────────────────────────────
const char* WIFI_SSID     = "YOUR_WIFI_SSID";
const char* WIFI_PASS     = "YOUR_WIFI_PASSWORD";
const char* ML_SERVER_URL = "http://YOUR_FLASK_SERVER_IP:5000/predict";

// Change this to whichever food is stored currently
// Options: "banana" | "apple" | "potato" | "onion" | "tomato" | "mango"
String selectedFood = "banana";
// ─────────────────────────────────────────────────────────────

// ── PIN DEFINITIONS ──────────────────────────────────────────
#define DHTTYPE    DHT22
#define DHTPIN1    4
#define DHTPIN2    5
#define MQ1_PIN    34
#define MQ2_PIN    35
#define RELAY1_PIN 25   // FAN
#define RELAY2_PIN 26   // AC / COOLER
#define RELAY3_PIN 27   // HEATER

// Set true if your relay module triggers on LOW (most common blue modules)
const bool RELAY_ACTIVE_LOW = true;
// ─────────────────────────────────────────────────────────────

DHT dht1(DHTPIN1, DHTTYPE);
DHT dht2(DHTPIN2, DHTTYPE);
WebServer server(80);

// ── STATE ────────────────────────────────────────────────────
bool autoMode = true;
bool relay1   = false;  // FAN
bool relay2   = false;  // AC
bool relay3   = false;  // HEATER

float temp1 = 0, hum1 = 0;
float temp2 = 0, hum2 = 0;
int   gas1  = 0, gas2  = 0;

String fungalRisk   = "Unknown";
String suggestion   = "No data yet";
float  mlConfidence = 0.0;

unsigned long lastSensorRead = 0;
unsigned long lastMLUpdate   = 0;

// FIX 1: Track whether Flask ML is reachable
// autoLogic() only runs as fallback when this is false
bool          mlOnline       = false;
unsigned long lastMLSuccess  = 0;
const unsigned long ML_STALE_MS = 15000; // 15s without ML = fallback kicks in
                                          // Increased from 10s to cover blocking
                                          // delays from HTTP + handleClient()

// ── FOOD-SPECIFIC THRESHOLDS ─────────────────────────────────
struct FoodThreshold {
  float tempMin, tempMax;
  float humMin,  humMax;
};

FoodThreshold getFoodThreshold(String food) {
  if (food == "banana") return {12.0, 14.0, 85.0, 95.0};
  if (food == "apple")  return { 1.0,  4.0, 90.0, 95.0};
  if (food == "potato") return { 3.0, 10.0, 85.0, 92.0};
  if (food == "onion")  return { 0.0,  3.0, 65.0, 75.0};
  if (food == "tomato") return { 8.0, 12.0, 85.0, 90.0};
  if (food == "mango")  return { 8.0, 13.0, 85.0, 90.0};
  return {4.0, 10.0, 80.0, 90.0};
}

// ── RELAY CONTROL ─────────────────────────────────────────────
void setRelay(int pin, bool state) {
  digitalWrite(pin, RELAY_ACTIVE_LOW ? (state ? LOW : HIGH)
                                     : (state ? HIGH : LOW));
}

void applyRelays() {
  setRelay(RELAY1_PIN, relay1);
  setRelay(RELAY2_PIN, relay2);
  setRelay(RELAY3_PIN, relay3);
}

// ── SENSOR READ ───────────────────────────────────────────────
void readSensors() {
  float t1 = dht1.readTemperature();
  float h1 = dht1.readHumidity();
  float t2 = dht2.readTemperature();
  float h2 = dht2.readHumidity();

  if (!isnan(t1)) temp1 = t1;
  if (!isnan(h1)) hum1  = h1;
  if (!isnan(t2)) temp2 = t2;
  if (!isnan(h2)) hum2  = h2;

  gas1 = analogRead(MQ1_PIN);
  gas2 = analogRead(MQ2_PIN);

  Serial.printf("[Sensors] T1=%.1f T2=%.1f H1=%.1f H2=%.1f G1=%d G2=%d\n",
                temp1, temp2, hum1, hum2, gas1, gas2);
}

// ── AUTO LOGIC (fallback only — runs ONLY when Flask is offline) ──
// FIX 1: Guard added. If ML responded within the last 10 seconds,
//         skip this entirely. Flask ML is the primary decision maker.
void autoLogic() {
  if (!autoMode) return;

  // Skip if ML is fresh — Flask already set the relays correctly
  bool mlFresh = mlOnline && (millis() - lastMLSuccess < ML_STALE_MS);
  if (mlFresh) {
    Serial.println("[Auto] ML is fresh, skipping local fallback");
    return;
  }

  Serial.println("[Auto] ML offline/stale — using local food thresholds");

  float avgTemp = (temp1 + temp2) / 2.0;
  float avgHum  = (hum1  + hum2)  / 2.0;

  FoodThreshold th = getFoodThreshold(selectedFood);

  relay1 = (avgHum  > th.humMax);
  relay2 = (avgTemp > th.tempMax);
  relay3 = (avgTemp < th.tempMin);

  applyRelays();
  Serial.printf("[Auto] Fallback relays → FAN=%d AC=%d HEATER=%d\n",
                relay1, relay2, relay3);
}

// ── ML FETCH ─────────────────────────────────────────────────
void fetchMLPrediction() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[ML] WiFi not connected, skipping");
    mlOnline = false;
    return;
  }

  HTTPClient http;
  http.begin(ML_SERVER_URL);
  http.addHeader("Content-Type", "application/json");

  StaticJsonDocument<256> reqDoc;
  reqDoc["temp1"] = temp1;
  reqDoc["temp2"] = temp2;
  reqDoc["hum1"]  = hum1;
  reqDoc["hum2"]  = hum2;
  reqDoc["gas1"]  = gas1;
  reqDoc["gas2"]  = gas2;
  reqDoc["food"]  = selectedFood;

  String reqBody;
  serializeJson(reqDoc, reqBody);
  Serial.println("[ML] Sending: " + reqBody);

  int httpCode = http.POST(reqBody);
  Serial.printf("[ML] HTTP response code: %d\n", httpCode);

  if (httpCode == 200) {
    String response = http.getString();
    Serial.println("[ML] Response: " + response);

    StaticJsonDocument<768> resDoc;
    DeserializationError err = deserializeJson(resDoc, response);

    if (!err) {
      if (resDoc.containsKey("fungal_risk"))
        fungalRisk   = resDoc["fungal_risk"].as<String>();
      if (resDoc.containsKey("suggestion"))
        suggestion   = resDoc["suggestion"].as<String>();
      if (resDoc.containsKey("confidence"))
        mlConfidence = resDoc["confidence"].as<float>();

      // Apply relay decisions from Flask in auto mode
      if (autoMode) {
        if (resDoc.containsKey("fan"))    relay1 = resDoc["fan"].as<bool>();
        if (resDoc.containsKey("cooler")) relay2 = resDoc["cooler"].as<bool>();
        if (resDoc.containsKey("heater")) relay3 = resDoc["heater"].as<bool>();
        applyRelays();
        Serial.printf("[ML] Relays set → FAN=%d AC=%d HEATER=%d\n",
                      relay1, relay2, relay3);
      }

      // FIX 1: Mark ML as successful so autoLogic() stays suppressed
      mlOnline      = true;
      lastMLSuccess = millis();

    } else {
      Serial.println("[ML] JSON parse error: " + String(err.c_str()));
      mlOnline = false;
    }
  } else {
    Serial.printf("[ML] Request failed, code: %d\n", httpCode);
    mlOnline = false;
  }

  http.end();
}

// ── HTTP HANDLERS ─────────────────────────────────────────────

// GET /status  → Flutter polls this every 3 seconds
void handleStatus() {
  StaticJsonDocument<512> doc;
  doc["online"]     = true;
  doc["temp1"]      = temp1;
  doc["temp2"]      = temp2;
  doc["hum1"]       = hum1;
  doc["hum2"]       = hum2;
  doc["gas1"]       = gas1;
  doc["gas2"]       = gas2;
  doc["auto"]       = autoMode;   // FIX 3: Flutter reads this to stay in sync
  doc["relay1"]     = relay1;
  doc["relay2"]     = relay2;
  doc["relay3"]     = relay3;
  doc["fungalRisk"] = fungalRisk;
  doc["suggestion"] = suggestion;
  doc["confidence"] = mlConfidence;
  doc["food"]       = selectedFood;
  doc["mlOnline"]   = mlOnline;   // Bonus: Flutter can show ML status

  String output;
  serializeJson(doc, output);
  server.send(200, "application/json", output);
}

// POST /mode  → Flutter sends {"auto": true/false}
void handleMode() {
  if (!server.hasArg("plain")) {
    server.send(400, "text/plain", "Missing body");
    return;
  }

  StaticJsonDocument<128> doc;
  DeserializationError err = deserializeJson(doc, server.arg("plain"));
  if (err) {
    server.send(400, "text/plain", "Bad JSON");
    return;
  }

  if (doc.containsKey("auto")) {
    autoMode = doc["auto"].as<bool>();
    Serial.printf("[Mode] Switched to %s\n", autoMode ? "AUTO" : "MANUAL");
  }

  if (autoMode) {
    readSensors();
    autoLogic();
  }

  server.send(200, "application/json", "{\"ok\":true}");
}

// POST /relay  → Flutter sends {"id": 1, "state": true}
//
// FIX 2: Removed the 409 block that silently rejected commands in auto mode.
//         Now accepts the command, forces manual mode, and applies it.
//         This means tapping a relay in Flutter ALWAYS works immediately.
void handleRelay() {
  if (!server.hasArg("plain")) {
    server.send(400, "text/plain", "Missing body");
    return;
  }

  StaticJsonDocument<128> doc;
  DeserializationError err = deserializeJson(doc, server.arg("plain"));
  if (err) {
    server.send(400, "text/plain", "Bad JSON");
    return;
  }

  int  id    = doc["id"]    | -1;
  bool state = doc["state"] | false;

  if (id < 1 || id > 3) {
    server.send(400, "text/plain", "Invalid relay id (use 1, 2, or 3)");
    return;
  }

  // FIX 2: If a manual relay command arrives while in auto mode,
  //         switch to manual automatically instead of rejecting it.
  //         This handles the race condition where Flutter UI is in manual
  //         but ESP32 didn't receive the /mode switch yet.
  if (autoMode) {
    autoMode = false;
    Serial.println("[Relay] Auto→Manual forced by relay command");
  }

  if      (id == 1) relay1 = state;
  else if (id == 2) relay2 = state;
  else if (id == 3) relay3 = state;

  applyRelays();
  Serial.printf("[Relay] id=%d state=%d\n", id, state);

  // Return current relay states so Flutter can confirm
  StaticJsonDocument<128> res;
  res["ok"]     = true;
  res["relay1"] = relay1;
  res["relay2"] = relay2;
  res["relay3"] = relay3;
  res["auto"]   = autoMode;
  String out;
  serializeJson(res, out);
  server.send(200, "application/json", out);
}

// ── SETUP ─────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n=== Cold Storage Monitor Booting ===");

  // Set relay pins to OFF BEFORE pinMode to prevent boot glitch
  digitalWrite(RELAY1_PIN, RELAY_ACTIVE_LOW ? HIGH : LOW);
  digitalWrite(RELAY2_PIN, RELAY_ACTIVE_LOW ? HIGH : LOW);
  digitalWrite(RELAY3_PIN, RELAY_ACTIVE_LOW ? HIGH : LOW);
  pinMode(RELAY1_PIN, OUTPUT);
  pinMode(RELAY2_PIN, OUTPUT);
  pinMode(RELAY3_PIN, OUTPUT);
  applyRelays();

  dht1.begin();
  dht2.begin();
  Serial.println("[DHT] Sensors initialized");

  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.print("[WiFi] Connecting");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\n[WiFi] Connected!");
  Serial.print("[WiFi] ESP32 IP: ");
  Serial.println(WiFi.localIP());
  Serial.println(">>> COPY THIS IP INTO Flutter espBaseUrl <<<");

  server.on("/status", HTTP_GET,  handleStatus);
  server.on("/mode",   HTTP_POST, handleMode);
  server.on("/relay",  HTTP_POST, handleRelay);
  server.begin();
  Serial.println("[Server] HTTP server started on port 80");
  Serial.println("=== Boot complete ===\n");
}

// ── LOOP ──────────────────────────────────────────────────────
void loop() {
  server.handleClient();

  unsigned long now = millis();

  // Read sensors every 2 seconds
  if (now - lastSensorRead >= 2000) {
    lastSensorRead = now;
    readSensors();
    autoLogic();  // Only fires as fallback when ML is offline/stale
  }

  // Call Flask ML every 7 seconds
  // Increased from 5s to stagger away from the 2s sensor read cycle
  // and give handleClient() time to finish before blocking HTTP POST
  if (now - lastMLUpdate >= 7000) {
    lastMLUpdate = now;
    fetchMLPrediction();
  }
}
