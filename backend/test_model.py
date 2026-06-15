"""
test_model.py  –  Manual test runner for the trained ML model
Run: python test_model.py

FIX vs old version:
  OLD: only sent 6 raw features → crashed or gave wrong results
  NEW: sends all 12 features (raw + engineered) matching train_model.py
"""

import joblib
import pandas as pd

# ── Load ──────────────────────────────────────────────────────
model         = joblib.load("fungal_risk_model.pkl")
label_encoder = joblib.load("label_encoder.pkl")
print("Model and encoder loaded.\n")


def predict(label, temp1, temp2, hum1, hum2, gas1, gas2):
    """Run one test case and print the result."""
    avg_temp  = (temp1 + temp2) / 2
    avg_hum   = (hum1  + hum2)  / 2
    avg_gas   = (gas1  + gas2)  / 2
    temp_diff = abs(temp1 - temp2)
    hum_diff  = abs(hum1  - hum2)
    gas_diff  = abs(gas1  - gas2)

    sample = pd.DataFrame([{
        "temp1": temp1, "temp2": temp2,
        "hum1":  hum1,  "hum2":  hum2,
        "gas1":  gas1,  "gas2":  gas2,
        "avg_temp":  avg_temp,  "avg_hum":  avg_hum,  "avg_gas":  avg_gas,
        "temp_diff": temp_diff, "hum_diff": hum_diff, "gas_diff": gas_diff,
    }])

    pred       = label_encoder.inverse_transform(model.predict(sample))[0]
    proba      = dict(zip(label_encoder.classes_, model.predict_proba(sample)[0]))
    confidence = round(max(proba.values()) * 100, 1)

    print(f"  Test : {label}")
    print(f"  Input: temp=({temp1},{temp2})  hum=({hum1},{hum2})  gas=({gas1},{gas2})")
    print(f"  → Predicted: {pred}   Confidence: {confidence}%")
    print(f"  → Probabilities: High={proba['High']*100:.1f}%  "
          f"Low={proba['Low']*100:.1f}%  Medium={proba['Medium']*100:.1f}%")
    print()


# ── Test cases ────────────────────────────────────────────────
print("="*55)
print("BANANA")
print("="*55)
predict("Banana – OPTIMAL",    13.0, 13.2, 88.0, 89.0,  950,  980)
predict("Banana – HOT+HUMID",  28.0, 28.5, 97.0, 98.0, 3500, 3600)
predict("Banana – COLD",        9.0,  9.2, 87.0, 88.0, 1100, 1120)

print("="*55)
print("APPLE")
print("="*55)
predict("Apple  – OPTIMAL",     2.0,  2.3, 92.0, 93.0,  800,  820)
predict("Apple  – HOT",        14.0, 14.5, 97.0, 98.0, 3200, 3300)

print("="*55)
print("POTATO")
print("="*55)
predict("Potato – OPTIMAL",     7.0,  7.3, 87.0, 88.0, 1000, 1020)
predict("Potato – HOT",        20.0, 20.5, 94.0, 95.0, 2900, 3000)

print("="*55)
print("ONION")
print("="*55)
predict("Onion  – OPTIMAL",     1.5,  1.7, 68.0, 69.0,  700,  720)
predict("Onion  – HOT+WET",    18.0, 18.5, 88.0, 89.0, 2800, 2900)

print("="*55)
print("TOMATO")
print("="*55)
predict("Tomato – OPTIMAL",    10.0, 10.2, 87.0, 88.0,  950,  980)
predict("Tomato – HOT",        22.0, 22.5, 95.0, 96.0, 3100, 3200)

print("="*55)
print("MANGO")
print("="*55)
predict("Mango  – OPTIMAL",    11.0, 11.2, 87.0, 88.0, 1000, 1030)
predict("Mango  – HOT+HUMID",  28.0, 28.8, 97.0, 98.0, 3800, 3900)
