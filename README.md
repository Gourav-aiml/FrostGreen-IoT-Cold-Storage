# 🌿 FrostGreen — IoT Cold Storage Monitor

> IoT-based cold storage monitoring and fungal risk prediction system  
> using ESP32, Flutter, Flask, and Random Forest ML

---

## 📌 Overview

FrostGreen is a smart cold storage monitoring system built as part of a Summer Internship Project (SIP) at Woxsen University. It continuously monitors temperature, humidity, and gas levels inside a cold storage unit, predicts fungal risk using a trained ML model, and automatically controls cooling, heating, and ventilation via relays.

---

## 🔧 Tech Stack

| Layer | Technology |
|-------|-----------|
| Hardware | ESP32, DHT22 (×2), MQ135 (×2), Relay Module (×3) |
| Firmware | Arduino C++ (ESP32 WebServer + HTTPClient) |
| ML Model | Random Forest — scikit-learn (97.17% CV accuracy) |
| Backend | Python Flask REST API |
| Mobile App | Flutter (Dart) — Dashboard, Analytics, Control, Alerts |

---

## 📁 Project Structure
FrostGreen-IoT-Cold-Storage/
│
├── firmware/
│   └── cold_storage_esp32.ino
│
├── backend/
│   ├── app.py
│   ├── train_model.py
│   ├── test_model.py
│   └── cold_storage_dataset.csv
│
├── flutter_app/
│   └── lib/
│       └── main.dart
│   └── pubspec.yaml
│
└── README.md

---

## ⚙️ How It Works

1. **ESP32** reads temperature, humidity, and gas levels every 2 seconds
2. Sensor data is sent to the **Flask backend** every 7 seconds via HTTP POST
3. Flask runs the **Random Forest model** and returns fungal risk level + relay decisions
4. ESP32 applies relay states (FAN / AC / HEATER) automatically
5. **Flutter app** polls ESP32 every 3 seconds and displays live data, risk alerts, and manual controls

---

## 🚀 Setup & Usage

### Backend (Flask)
```bash
cd backend
pip install flask scikit-learn pandas numpy
python train_model.py   # Train and save the model
python app.py           # Start Flask server
```

### Firmware (ESP32)
1. Open `firmware/cold_storage_esp32.ino` in Arduino IDE
2. Fill in your WiFi credentials and Flask server IP in the config section
3. Install libraries: DHT sensor (Adafruit), ArduinoJson, WiFi, HTTPClient
4. Upload to ESP32

### Flutter App
```bash
cd flutter_app
flutter pub get
flutter run
```
Update `espBaseUrl` in `main.dart` with your ESP32's local IP address.

---

## 📊 ML Model

- **Algorithm:** Random Forest Classifier
- **Cross-validation Accuracy:** 97.17%
- **Input Features:** temp1, temp2, hum1, hum2, gas1, gas2, food type
- **Output:** Fungal risk level + suggested action + relay decisions
- **Supported Foods:** Banana, Apple, Potato, Onion, Tomato, Mango

---

## 🌱 SDG Alignment

| SDG | Goal |
|-----|------|
| SDG 2 — Zero Hunger | Reduces post-harvest food loss in cold storage |
| SDG 9 — Industry & Innovation | IoT + ML for smart agriculture infrastructure |
| SDG 12 — Responsible Consumption | Minimizes food waste through early fungal detection |

---


## 👥 Team

Gourav Saha, Pranav Yeddula, Yash Raj, Debangshu Dhak  
**Mentor:** Dr. N. Soujanya  
**Co- Mentor:** Dr. S. Bhanu prakash
**Institution:** Woxsen University, Hyderabad — BTech CSE AI/ML (2025–29)

---

## 📄 License

MIT License — feel free to use, modify, and build on this project.