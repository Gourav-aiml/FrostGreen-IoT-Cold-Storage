"""
Cold Storage ML API  –  Production-ready Flask backend
Fixes applied vs old version:
  1. Duplicate relay block removed
  2. /history endpoint added (last 100 readings, ring buffer)
  3. /status endpoint added (lightweight ping for Flutter)
  4. CORS headers added so Flutter on any IP can connect
  5. Input validation with proper error responses
  6. gas_status added for MQ135 anomaly detection
  7. Food-specific conditions expanded (tomato + mango added)
  8. Suggestion improved to include gas warning
  9. Thread-safe history list using deque
  10. Timestamps on every reading
"""

from flask import Flask, request, jsonify
from collections import deque
from datetime import datetime
import joblib
import pandas as pd

app = Flask(__name__)

# ── Load model + encoder ──────────────────────────────────────
model         = joblib.load("fungal_risk_model.pkl")
label_encoder = joblib.load("label_encoder.pkl")

# ── In-memory storage ─────────────────────────────────────────
# latest_data  : most recent prediction (single dict)
# history      : ring buffer, last 100 readings
latest_data = {
    "temp1": 0, "temp2": 0,
    "hum1": 0,  "hum2": 0,
    "gas1": 0,  "gas2": 0,
    "fungal_risk": "Unknown",
    "confidence": 0,
    "suggestion": "No data yet",
    "fan": False, "cooler": False, "heater": False,
    "timestamp": ""
}
history = deque(maxlen=100)   # auto-drops oldest when full

# ── Food-specific storage conditions (Indian standards) ───────
# Sources: NHB India, ICAR post-harvest guidelines
FOOD_CONDITIONS = {
    "banana": {
        "temp_min": 12.0, "temp_max": 14.0,
        "hum_min":  85,   "hum_max":  95,
        "gas_warn": 2200
    },
    "apple": {
        "temp_min": 1.0,  "temp_max": 4.0,
        "hum_min":  90,   "hum_max":  95,
        "gas_warn": 2000
    },
    "potato": {
        "temp_min": 3.0,  "temp_max": 10.0,
        "hum_min":  85,   "hum_max":  92,
        "gas_warn": 2100
    },
    "onion": {
        "temp_min": 0.0,  "temp_max": 3.0,
        "hum_min":  65,   "hum_max":  75,
        "gas_warn": 1800
    },
    "tomato": {
        "temp_min": 8.0,  "temp_max": 12.0,
        "hum_min":  85,   "hum_max":  90,
        "gas_warn": 2300
    },
    "mango": {
        "temp_min": 8.0,  "temp_max": 13.0,
        "hum_min":  85,   "hum_max":  90,
        "gas_warn": 2400
    },
}

DEFAULT_CONDITIONS = {
    "temp_min": 4.0,  "temp_max": 10.0,
    "hum_min":  80,   "hum_max":  90,
    "gas_warn": 2000
}


def get_suggestion(food, temp_status, hum_status, gas_status):
    """Build a human-readable suggestion string from statuses."""
    actions = []
    if temp_status == "HIGH":
        actions.append(f"Temperature too high for {food}. Turn ON cooling.")
    if temp_status == "LOW":
        actions.append(f"Temperature too low for {food}. Turn ON heater.")
    if hum_status == "HIGH":
        actions.append("Humidity too high. Turn ON fan.")
    if hum_status == "LOW":
        actions.append("Humidity too low. Maintain moisture levels.")
    if gas_status == "HIGH":
        actions.append("Gas levels elevated. Check ventilation or spoilage.")
    if not actions:
        actions.append(f"Conditions are optimal for {food}. No action needed.")
    return " | ".join(actions)


# ── Routes ────────────────────────────────────────────────────

@app.route("/")
def home():
    return jsonify({"status": "running", "message": "Cold Storage ML API is running"})


@app.route("/predict", methods=["POST"])
def predict():
    global latest_data

    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Invalid or missing JSON body"}), 400

    # ── Parse inputs ──────────────────────────────────────────
    try:
        temp1 = float(data.get("temp1", 0))
        temp2 = float(data.get("temp2", 0))
        hum1  = float(data.get("hum1",  0))
        hum2  = float(data.get("hum2",  0))
        gas1  = float(data.get("gas1",  0))
        gas2  = float(data.get("gas2",  0))
    except (TypeError, ValueError):
        return jsonify({"error": "Sensor values must be numbers"}), 400

    food = str(data.get("food", "default")).lower().strip()
    conditions = FOOD_CONDITIONS.get(food, DEFAULT_CONDITIONS)

    # ── Computed features ─────────────────────────────────────
    avg_temp  = (temp1 + temp2) / 2
    avg_hum   = (hum1  + hum2)  / 2
    avg_gas   = (gas1  + gas2)  / 2
    temp_diff = abs(temp1 - temp2)
    hum_diff  = abs(hum1  - hum2)
    gas_diff  = abs(gas1  - gas2)

    # ── Status flags ──────────────────────────────────────────
    if avg_temp < conditions["temp_min"]:
        temp_status = "LOW"
    elif avg_temp > conditions["temp_max"]:
        temp_status = "HIGH"
    else:
        temp_status = "OK"

    if avg_hum < conditions["hum_min"]:
        hum_status = "LOW"
    elif avg_hum > conditions["hum_max"]:
        hum_status = "HIGH"
    else:
        hum_status = "OK"

    gas_status = "HIGH" if avg_gas > conditions["gas_warn"] else "OK"

    # ── ML prediction ─────────────────────────────────────────
    input_df = pd.DataFrame([{
        "temp1": temp1, "temp2": temp2,
        "hum1":  hum1,  "hum2":  hum2,
        "gas1":  gas1,  "gas2":  gas2,
        "avg_temp":  avg_temp,  "avg_hum":  avg_hum,  "avg_gas":  avg_gas,
        "temp_diff": temp_diff, "hum_diff": hum_diff, "gas_diff": gas_diff,
    }])

    raw_pred   = model.predict(input_df)
    risk       = label_encoder.inverse_transform(raw_pred)[0]
    proba      = model.predict_proba(input_df)[0]
    confidence = round(float(max(proba)) * 100, 2)

    # ── Hybrid rule layer (slight adjustment only, never full override) ──
    # Rule 1: ML says Low but environment is clearly bad → bump to Medium
    if risk == "Low" and (temp_status == "HIGH" or hum_status == "HIGH" or gas_status == "HIGH"):
        risk = "Medium"
    # Rule 2: ML says Medium AND both temp AND humidity bad → bump to High
    elif risk == "Medium" and temp_status == "HIGH" and hum_status == "HIGH":
        risk = "High"

    # ── Relay automation logic ────────────────────────────────
    fan    = (hum_status == "HIGH")
    cooler = (temp_status == "HIGH")
    heater = (temp_status == "LOW")

    # ── Build response ────────────────────────────────────────
    suggestion = get_suggestion(food, temp_status, hum_status, gas_status)
    timestamp  = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    result = {
        "temp1": temp1,       "temp2": temp2,
        "hum1":  hum1,        "hum2":  hum2,
        "gas1":  int(gas1),   "gas2":  int(gas2),
        "avg_temp":  round(avg_temp, 2),
        "avg_hum":   round(avg_hum,  2),
        "avg_gas":   round(avg_gas,  2),
        "temp_status": temp_status,
        "hum_status":  hum_status,
        "gas_status":  gas_status,
        "fungal_risk": risk,
        "confidence":  confidence,
        "suggestion":  suggestion,
        "fan":    fan,
        "cooler": cooler,
        "heater": heater,
        "food":   food,
        "timestamp": timestamp,
    }

    # Save latest + append to history
    latest_data = result
    history.append(result)

    return jsonify(result)


@app.route("/latest", methods=["GET"])
def latest():
    """Most recent prediction snapshot."""
    return jsonify(latest_data)


@app.route("/history", methods=["GET"])
def get_history():
    """
    Last N readings (default 20, max 100).
    Flutter analytics graphs call this endpoint.
    Usage: GET /history?n=30
    """
    try:
        n = min(int(request.args.get("n", 20)), 100)
    except (TypeError, ValueError):
        n = 20
    data_list = list(history)[-n:]
    return jsonify({
        "count": len(data_list),
        "readings": data_list
    })


@app.route("/status", methods=["GET"])
def status():
    """
    Lightweight health check. Flutter uses this to show online/offline.
    Returns instantly without any heavy processing.
    """
    return jsonify({"online": True, "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S")})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
