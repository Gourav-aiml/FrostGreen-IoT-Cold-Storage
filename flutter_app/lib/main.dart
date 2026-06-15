// ═══════════════════════════════════════════════════════════════════════════
//  Cold Storage Monitor  –  main.dart  (FIXED)
//
//  BUGS FIXED vs previous version:
//
//  FIX 1 — autoMode now synced from ESP32 /status response
//    Old: data["auto"] was fetched but never applied to Flutter's autoMode.
//         ESP32 reboot silently desynced modes; Flutter thought it was
//         manual while ESP32 was in auto, causing relay commands to be
//         rejected (HTTP 409) without Flutter knowing.
//    Fix: autoMode = data["auto"] ?? autoMode  inside _fetchStatus setState.
//
//  FIX 2 — _sendRelay() now checks HTTP response and confirms relay state
//    Old: _sendRelay() fired POST and ignored the response entirely.
//         If ESP32 returned 409 (auto mode rejection) Flutter showed the
//         toggle as changed but the relay never actually fired.
//    Fix: Parse the relay response JSON. If "ok" is false or status != 200,
//         revert the optimistic UI state. Also reads back confirmed relay
//         states from ESP32 response to keep UI accurate.
//
//  FIX 3 — Mode card Switch now waits for /mode to confirm before updating
//    Old: setState() flipped autoMode immediately on switch tap, then sent
//         /mode async. If the request failed, UI showed wrong mode.
//    Fix: Send /mode first, only flip UI on success. On failure, revert.
//
//  KEPT — ALL original UI and FIX 1/2/3 from previous version:
//    Per-relay lock map, real Flask /history analytics, mlConfidence
//    threshold alerts, gas_status badge, tomato + mango food options,
//    AnimatedSwitcher, bottom nav, all cards, charts, alerts tab.
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

// ── CHANGE THESE TO YOUR ACTUAL IPs ────────────────────────────────────────
const String espBaseUrl = "Your ESP32 IP"; // ESP32
const String flaskBaseUrl = "Your Flask ML Server IP"; // Flask ML server
// ───────────────────────────────────────────────────────────────────────────

// How long a manually-toggled relay is protected from polling overwrite
const Duration kRelayLockDuration = Duration(seconds: 5);

void main() {
  runApp(const ColdStorageApp());
}

class ColdStorageApp extends StatelessWidget {
  const ColdStorageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Cold Storage Monitor',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        cardColor: const Color(0xFF141C28),
        dividerColor: Colors.white12,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF0D111A),
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white54,
          type: BottomNavigationBarType.fixed,
        ),
      ),
      home: const Dashboard(),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  DASHBOARD
// ════════════════════════════════════════════════════════════════════════════
class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  // ── Tab ─────────────────────────────────────────────────────────────────
  int _tabIndex = 0;

  // ── Relay states ─────────────────────────────────────────────────────────
  bool autoMode = true;
  bool relay1 = false; // FAN
  bool relay2 = false; // COOLER
  bool relay3 = false; // HEATER

  // ── Per-relay lock map ───────────────────────────────────────────────────
  final Map<String, DateTime?> _relayLockUntil = {
    'relay1': null,
    'relay2': null,
    'relay3': null,
  };

  bool _isRelayLocked(String key) {
    final until = _relayLockUntil[key];
    if (until == null) return false;
    return DateTime.now().isBefore(until);
  }

  void _lockRelay(String key) {
    _relayLockUntil[key] = DateTime.now().add(kRelayLockDuration);
  }

  // ── Sensor data ──────────────────────────────────────────────────────────
  double temp1 = 4.2;
  double temp2 = 5.1;
  int gas1 = 120;
  int gas2 = 135;
  double humidity1 = 82.0;
  double humidity2 = 84.0;

  // ── ML / prediction ──────────────────────────────────────────────────────
  int fungalRiskPercent = 0;
  double mlConfidence = 0.0;
  String fungalRisk = "Unknown";
  String suggestion = "No data yet";
  String tempStatus = "OK";
  String humStatus = "OK";
  String gasStatus = "OK";

  // ── Food ─────────────────────────────────────────────────────────────────
  String selectedFood = "banana";

  int get fungalAlertThreshold {
    switch (selectedFood) {
      case "banana":
        return 60;
      case "apple":
        return 75;
      case "potato":
        return 65;
      case "onion":
        return 70;
      case "tomato":
        return 65;
      case "mango":
        return 62;
      default:
        return 70;
    }
  }

  bool get isFungalHigh => fungalRisk == "High";

  // ── Derived averages ─────────────────────────────────────────────────────
  double get tempMerged => (temp1 + temp2) / 2;
  double get humMerged => (humidity1 + humidity2) / 2;
  double get gasMerged => (gas1 + gas2) / 2;

  // ── MQ135 gas conversion ──────────────────────────────────────────────────
  static const double _RL = 10000;
  static const double _Vc = 3.3;
  static const double _Ro = 3296;

  double _rsRoRatio(double adc) {
    if (adc <= 0) return 9999;
    final vout = adc * (_Vc / 4095.0);
    if (vout <= 0) return 9999;
    final rs = _RL * (_Vc - vout) / vout;
    return rs / _Ro;
  }

  double get co2Ppm {
    final r = _rsRoRatio(gasMerged);
    return (116.6020682 * pow(r, -2.769034857)).clamp(400.0, 5000.0);
  }

  double get nh3Ppm {
    final r = _rsRoRatio(gasMerged);
    return (102.2 * pow(r, -2.473)).clamp(0.0, 300.0);
  }

  double get coPpm {
    final r = _rsRoRatio(gasMerged);
    return (605.18 * pow(r, -3.937)).clamp(0.0, 200.0);
  }

  double get ethanolPpm {
    final r = _rsRoRatio(gasMerged);
    return (77.255 * pow(r, -3.18)).clamp(0.0, 200.0);
  }

  double get acetonePpm {
    final r = _rsRoRatio(gasMerged);
    return (34.668 * pow(r, -3.369)).clamp(0.0, 100.0);
  }

  double get eCO2 => co2Ppm;
  double get eNH3 => nh3Ppm;
  double get ethanol => ethanolPpm;
  double get acetone => acetonePpm;
  double get toluene => ethanolPpm * 0.14;

  // ── Alerts ───────────────────────────────────────────────────────────────
  final List<Map<String, dynamic>> _alerts = [];
  bool _fungalNotified = false;
  bool _hasNewAlerts = false;

  // ── Connectivity ─────────────────────────────────────────────────────────
  bool isOnline = false;
  DateTime lastUpdated = DateTime.now();
  bool _loading = true;
  String? _lastError;

  // ── Notifications ────────────────────────────────────────────────────────
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  // ── Analytics history ─────────────────────────────────────────────────────
  List<Map<String, dynamic>> _historyReadings = [];
  bool _historyLoading = false;
  int _rangeIndex = 0;

  // ── Poll timer ───────────────────────────────────────────────────────────
  Timer? _pollTimer;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _initNotifications();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  // ── Polling ──────────────────────────────────────────────────────────────
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _fetchStatus();
    });
    _fetchStatus();
  }

  // ── Fetch sensor status from ESP32 ───────────────────────────────────────
  Future<void> _fetchStatus() async {
    try {
      if (mounted && !isOnline) {
        setState(() => _loading = true);
      }

      final res = await http
          .get(Uri.parse("$espBaseUrl/status"))
          .timeout(const Duration(seconds: 3));

      if (res.statusCode != 200) throw Exception("HTTP ${res.statusCode}");

      final data = jsonDecode(res.body) as Map<String, dynamic>;

      if (!mounted) return;
      setState(() {
        isOnline = true;
        lastUpdated = DateTime.now();
        _loading = false;
        _lastError = null;

        temp1 = (data["temp1"] ?? temp1).toDouble();
        temp2 = (data["temp2"] ?? temp2).toDouble();
        humidity1 = (data["hum1"] ?? humidity1).toDouble();
        humidity2 = (data["hum2"] ?? humidity2).toDouble();
        gas1 = (data["gas1"] ?? gas1).toInt();
        gas2 = (data["gas2"] ?? gas2).toInt();

        // ── FIX 1: Sync autoMode from ESP32 ──────────────────────────────
        // Previously this line was missing. Without it, if ESP32 rebooted
        // (resetting to auto=true), Flutter stayed in manual mode and all
        // relay commands were silently rejected by ESP32 with HTTP 409.
        autoMode = data["auto"] ?? autoMode;

        // ── Relay sync with lock protection ──────────────────────────────
        if (autoMode) {
          relay1 = data["relay1"] ?? relay1;
          relay2 = data["relay2"] ?? relay2;
          relay3 = data["relay3"] ?? relay3;
        } else {
          if (!_isRelayLocked('relay1')) relay1 = data["relay1"] ?? relay1;
          if (!_isRelayLocked('relay2')) relay2 = data["relay2"] ?? relay2;
          if (!_isRelayLocked('relay3')) relay3 = data["relay3"] ?? relay3;
        }
      });

      await _sendToML();
    } catch (e) {
      String msg = e.toString();
      if (msg.contains("TimeoutException")) {
        msg = "No response from ESP32 (check IP & Wi-Fi)";
      } else if (msg.contains("SocketException")) {
        msg = "Network error (ESP32 not reachable)";
      }
      if (!mounted) return;
      setState(() {
        isOnline = false;
        _lastError = msg;
        _loading = false;
      });
    }
  }

  // ── Send sensor data to Flask ML ─────────────────────────────────────────
  Future<void> _sendToML() async {
    try {
      final response = await http
          .post(
            Uri.parse("$flaskBaseUrl/predict"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "temp1": temp1,
              "temp2": temp2,
              "hum1": humidity1,
              "hum2": humidity2,
              "gas1": gas1,
              "gas2": gas2,
              "food": selectedFood,
            }),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final ml = jsonDecode(response.body) as Map<String, dynamic>;
        if (!mounted) return;
        setState(() {
          fungalRisk = ml['fungal_risk'] ?? "Unknown";
          mlConfidence = (ml['confidence'] ?? 0).toDouble();
          suggestion = ml['suggestion'] ?? "No suggestion";
          tempStatus = ml['temp_status'] ?? "OK";
          humStatus = ml['hum_status'] ?? "OK";
          gasStatus = ml['gas_status'] ?? "OK";

          if (fungalRisk == "High")
            fungalRiskPercent = 85;
          else if (fungalRisk == "Medium")
            fungalRiskPercent = 55;
          else
            fungalRiskPercent = 20;

          if (autoMode) {
            relay1 = ml['fan'] ?? relay1;
            relay2 = ml['cooler'] ?? relay2;
            relay3 = ml['heater'] ?? relay3;
          }
        });

        await _checkFungalAndNotify();
      }
    } catch (_) {
      // Flask offline — keep last known prediction, no crash
    }
  }

  // ── Send relay command to ESP32 ──────────────────────────────────────────
  // FIX 2: Now checks the HTTP response.
  //   - If ESP32 returns ok=false or non-200, reverts the optimistic UI state.
  //   - If ESP32 returns confirmed relay states, applies them directly.
  //   - This fixes the "need to spam buttons" issue caused by silent 409s.
  Future<void> _sendRelay(int id, bool state) async {
    _lockRelay('relay$id');

    // Optimistic update already applied by caller (setState in _relayCard)
    try {
      final res = await http
          .post(
            Uri.parse("$espBaseUrl/relay"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"id": id, "state": state}),
          )
          .timeout(const Duration(seconds: 3));

      if (!mounted) return;

      if (res.statusCode == 200) {
        // Parse confirmed relay states from ESP32 response
        try {
          final body = jsonDecode(res.body) as Map<String, dynamic>;
          final ok = body["ok"] ?? true;

          if (!ok) {
            // ESP32 rejected — revert optimistic state
            setState(() {
              _lastError = body["msg"] ?? "Relay command rejected by ESP32";
              if (id == 1) relay1 = !state;
              if (id == 2) relay2 = !state;
              if (id == 3) relay3 = !state;
            });
            return;
          }

          // Apply confirmed states if ESP32 returned them
          setState(() {
            _lastError = null;
            if (body.containsKey("relay1")) relay1 = body["relay1"];
            if (body.containsKey("relay2")) relay2 = body["relay2"];
            if (body.containsKey("relay3")) relay3 = body["relay3"];
            // If ESP32 auto-switched to manual, sync that too
            if (body.containsKey("auto")) autoMode = body["auto"];
          });
        } catch (_) {
          // Response wasn't JSON — still OK, keep optimistic state
        }
      } else {
        // Non-200 — revert optimistic state
        setState(() {
          _lastError = "Relay update failed (HTTP ${res.statusCode})";
          if (id == 1) relay1 = !state;
          if (id == 2) relay2 = !state;
          if (id == 3) relay3 = !state;
        });
      }
    } catch (e) {
      if (!mounted) return;
      // Network error — revert optimistic state
      setState(() {
        _lastError = "Relay update failed (network error)";
        if (id == 1) relay1 = !state;
        if (id == 2) relay2 = !state;
        if (id == 3) relay3 = !state;
      });
    }
  }

  // ── Send mode to ESP32 ───────────────────────────────────────────────────
  // FIX 3: Returns bool success so caller can revert UI on failure.
  Future<bool> _sendMode(bool auto) async {
    try {
      final res = await http
          .post(
            Uri.parse("$espBaseUrl/mode"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"auto": auto}),
          )
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Notifications ────────────────────────────────────────────────────────
  Future<void> _initNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _notifications.initialize(initSettings);
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> _showFungalNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'fungal_channel',
      'Fungal Alerts',
      channelDescription: 'Alerts when fungal risk is high',
      importance: Importance.max,
      priority: Priority.high,
    );
    await _notifications.show(
      1,
      '⚠ High Fungal Risk',
      'Risk: $fungalRisk for $selectedFood. '
          'Confidence: ${mlConfidence.toStringAsFixed(1)}%',
      const NotificationDetails(android: androidDetails),
    );
  }

  Future<void> _checkFungalAndNotify() async {
    if (fungalRisk == "High" &&
        mlConfidence >= fungalAlertThreshold &&
        !_fungalNotified) {
      _fungalNotified = true;
      _addAlert(
        title: "High Fungal Risk",
        message:
            "ML confidence: ${mlConfidence.toStringAsFixed(1)}%. "
            "Check humidity/temp/airflow for $selectedFood.",
        level: "HIGH",
      );
      await _showFungalNotification();
    }
    if (fungalRisk == "Low") _fungalNotified = false;
  }

  void _addAlert({
    required String title,
    required String message,
    required String level,
  }) {
    setState(() {
      _alerts.insert(0, {
        "time": DateTime.now(),
        "title": title,
        "message": message,
        "level": level,
      });
      _hasNewAlerts = true;
    });
  }

  // ── Load history from Flask ───────────────────────────────────────────────
  Future<void> _loadHistory(int n) async {
    if (!mounted) return;
    setState(() => _historyLoading = true);
    try {
      final res = await http
          .get(Uri.parse("$flaskBaseUrl/history?n=$n"))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final readings =
            (body['readings'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (mounted) setState(() => _historyReadings = readings);
      }
    } catch (_) {
      // Offline — keep last fetched data
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  int _rangeToN(int index) {
    switch (index) {
      case 0:
        return 10;
      case 1:
        return 20;
      default:
        return 30;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  HELPERS
  // ─────────────────────────────────────────────────────────────────────────
  String co2DangerLabel(double ppm) {
    if (ppm > 3500) return "CRITICAL";
    if (ppm > 2000) return "DANGER";
    if (ppm > 800) return "CAUTION";
    return "SAFE";
  }

  Color co2DangerColor(String label) {
    switch (label) {
      case "SAFE":
        return Colors.green;
      case "CAUTION":
        return Colors.orange;
      case "DANGER":
        return Colors.red;
      case "CRITICAL":
        return Colors.purple;
      default:
        return Colors.blueGrey;
    }
  }

  String get fungalLabel {
    if (fungalRiskPercent >= 70) return "HIGH";
    if (fungalRiskPercent >= 40) return "MEDIUM";
    return "LOW";
  }

  Color _statusBadgeColor(String status) {
    switch (status) {
      case "HIGH":
        return Colors.red;
      case "LOW":
        return Colors.blue;
      default:
        return Colors.green;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Cold Storage"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _statusChip(),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF080B12), Color(0xFF0D111A), Color(0xFF0A0F17)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final offsetAnimation = Tween<Offset>(
                begin: const Offset(0.08, 0.0),
                end: Offset.zero,
              ).animate(animation);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(position: offsetAnimation, child: child),
              );
            },
            child: _tabIndex == 0
                ? _dashboardTab(key: const ValueKey('dash'))
                : _tabIndex == 1
                ? _controlTab(key: const ValueKey('control'))
                : _tabIndex == 2
                ? _analyticsTab(key: const ValueKey('analytics'))
                : _alertsTab(key: const ValueKey('alerts')),
          ),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _tabIndex,
        onTap: (i) {
          setState(() {
            _tabIndex = i;
            if (i == 3) _hasNewAlerts = false;
            if (i == 2) _loadHistory(_rangeToN(_rangeIndex));
          });
        },
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.dashboard),
            label: "Dashboard",
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.tune),
            label: "Control",
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.show_chart),
            label: "Analytics",
          ),
          BottomNavigationBarItem(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications),
                if (_hasNewAlerts)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            label: "Alerts",
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  SHARED WIDGETS
  // ─────────────────────────────────────────────────────────────────────────
  Widget _statusChip() {
    final c = autoMode ? Colors.green : Colors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: c),
          const SizedBox(width: 6),
          Text(
            autoMode ? "AUTO" : "MANUAL",
            style: TextStyle(fontWeight: FontWeight.bold, color: c),
          ),
        ],
      ),
    );
  }

  Widget _systemHeader() {
    final bool online = isOnline;
    final bool connecting = _loading;
    final String statusText = connecting
        ? "CONNECTING..."
        : (online ? "ONLINE" : "OFFLINE");
    final Color c = connecting
        ? Colors.amber
        : (online ? Colors.green : Colors.red);
    String sub =
        "Last updated: ${lastUpdated.hour.toString().padLeft(2, '0')}:"
        "${lastUpdated.minute.toString().padLeft(2, '0')}";
    if (!online && !connecting && _lastError != null) {
      sub = "Reason: $_lastError";
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              color: c.withOpacity(0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.wifi, color: c),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: TextStyle(fontWeight: FontWeight.bold, color: c),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
          if (!online && !connecting)
            IconButton(
              tooltip: "Retry",
              onPressed: _fetchStatus,
              icon: const Icon(Icons.refresh),
            ),
          _statusChip(),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  DASHBOARD TAB
  // ─────────────────────────────────────────────────────────────────────────
  Widget _dashboardTab({Key? key}) {
    return ListView(
      key: key,
      children: [
        const SizedBox(height: 10),

        // ── Food selector ────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(10),
            ),
            child: DropdownButton<String>(
              value: selectedFood,
              isExpanded: true,
              dropdownColor: const Color(0xFF0D111A),
              underline: const SizedBox(),
              items: ["banana", "apple", "potato", "onion", "tomato", "mango"]
                  .map((food) {
                    const emojis = {
                      "banana": "🍌",
                      "apple": "🍎",
                      "potato": "🥔",
                      "onion": "🧅",
                      "tomato": "🍅",
                      "mango": "🥭",
                    };
                    return DropdownMenuItem(
                      value: food,
                      child: Text(
                        "${emojis[food] ?? '🍽️'} ${food.toUpperCase()}",
                        style: const TextStyle(color: Colors.white),
                      ),
                    );
                  })
                  .toList(),
              onChanged: (v) => setState(() => selectedFood = v!),
            ),
          ),
        ),

        const SizedBox(height: 10),
        _systemHeader(),
        const SizedBox(height: 12),
        _fungalAlertBanner(),
        const SizedBox(height: 10),

        const Text(
          "Overview",
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),

        // ── Mini stat cards ──────────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: _miniStatCard(
                title: "Temp",
                value: "${tempMerged.toStringAsFixed(1)}°C",
                icon: Icons.thermostat,
                color: Colors.indigo,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _miniStatCard(
                title: "Humidity",
                value: "${humMerged.toStringAsFixed(0)}%",
                icon: Icons.water_drop,
                color: Colors.blue,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _miniStatCard(
                title: "CO₂",
                value: "${co2Ppm.toStringAsFixed(0)} ppm",
                icon: Icons.co2,
                color: co2DangerColor(co2DangerLabel(eCO2)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _relayStatusRow(),

        // ── Status badges ────────────────────────────────────────────────
        const SizedBox(height: 14),
        _statusBadgesRow(),

        // ── Air quality ───────────────────────────────────────────────────
        const SizedBox(height: 20),
        const Text(
          "Air Quality (MQ135)",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        _mainGasCO2Card(),
        const SizedBox(height: 6),
        const Text(
          "Cold Storage Gas Breakdown",
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        _gasDetailRow(
          "NH₃ (Ammonia)",
          nh3Ppm,
          25,
          "Refrigerant/decay",
          Colors.orange,
        ),
        _gasDetailRow("Ethanol", ethanolPpm, 50, "Fermentation", Colors.purple),
        _gasDetailRow(
          "CO (Carbon Mon.)",
          coPpm,
          10,
          "Machinery/combustion",
          Colors.red,
        ),
        _gasDetailRow(
          "Acetone",
          acetonePpm,
          20,
          "Fungal activity",
          Colors.amber,
        ),

        // ── Fungal risk ───────────────────────────────────────────────────
        const SizedBox(height: 14),
        const Text(
          "Fungal Risk",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        _fungalRiskCard(),

        // ── ML Prediction card ────────────────────────────────────────────
        Card(
          color: Colors.white10,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "ML Prediction: $fungalRisk",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: fungalRisk == "High"
                        ? Colors.red
                        : fungalRisk == "Medium"
                        ? Colors.orange
                        : Colors.green,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Confidence: ${mlConfidence.toStringAsFixed(1)}%",
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Text(
                  suggestion,
                  style: const TextStyle(fontSize: 14, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),

        // ── Environment ───────────────────────────────────────────────────
        const SizedBox(height: 14),
        const Text(
          "Environment",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        _sensorCard(
          "Temperature",
          "${tempMerged.toStringAsFixed(1)} °C",
          color: Colors.indigo,
        ),
        _sensorCard(
          "Humidity",
          "${humMerged.toStringAsFixed(0)} %",
          color: Colors.blue,
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _statusBadgesRow() {
    Widget badge(String label, String status) {
      final c = _statusBadgeColor(status);
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: c.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.withOpacity(0.4)),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
              const SizedBox(height: 3),
              Text(
                status,
                style: TextStyle(
                  color: c,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        badge("Temp", tempStatus),
        const SizedBox(width: 8),
        badge("Humidity", humStatus),
        const SizedBox(width: 8),
        badge("Gas", gasStatus),
      ],
    );
  }

  Widget _fungalAlertBanner() {
    if (!isFungalHigh) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.85),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "High fungal risk for $selectedFood. "
              "Check humidity, airflow & temperature.",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStatCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            height: 38,
            width: 38,
            decoration: BoxDecoration(
              color: color.withOpacity(0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _relayStatusRow() {
    Widget chip(String label, bool on) {
      final c = on ? Colors.green : Colors.white54;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? Colors.green.withOpacity(0.18) : Colors.white10,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.withOpacity(0.35)),
        ),
        child: Text(
          label,
          style: TextStyle(fontWeight: FontWeight.bold, color: c, fontSize: 12),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip("FAN ${relay1 ? 'ON' : 'OFF'}", relay1),
        chip("AC ${relay2 ? 'ON' : 'OFF'}", relay2),
        chip("HEATER ${relay3 ? 'ON' : 'OFF'}", relay3),
      ],
    );
  }

  Widget _mainGasCO2Card() {
    final label = co2DangerLabel(eCO2);
    final c = co2DangerColor(label);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.withOpacity(0.8), c],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "CO₂ (Main • Estimated)",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            "${eCO2.toStringAsFixed(0)} ppm",
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: (eCO2 / 5000).clamp(0.0, 1.0),
              minHeight: 10,
              backgroundColor: Colors.black26,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Danger level: $label",
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          const Text(
            "Source: MQ135 (cross-sensitive). Values are approximate.",
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _gasDetailRow(
    String name,
    double value,
    double alertThreshold,
    String role,
    Color accentColor,
  ) {
    final bool overLimit = value >= alertThreshold;
    final Color rowColor = overLimit ? Colors.red : accentColor;
    final double fillRatio = alertThreshold > 0
        ? (value / (alertThreshold * 2)).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rowColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: overLimit ? Colors.red.withOpacity(0.5) : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: rowColor,
                    ),
                  ),
                  if (role.isNotEmpty)
                    Text(
                      role,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white38,
                      ),
                    ),
                ],
              ),
              Row(
                children: [
                  Text(
                    "${value.toStringAsFixed(1)} ppm",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: rowColor,
                    ),
                  ),
                  if (overLimit) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        "ALERT",
                        style: TextStyle(
                          color: Colors.red,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Stack(
            children: [
              Container(
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              FractionallySizedBox(
                widthFactor: fillRatio,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: rowColor.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            "Alert at: ${alertThreshold.toStringAsFixed(0)} ppm",
            style: const TextStyle(fontSize: 9, color: Colors.white30),
          ),
        ],
      ),
    );
  }

  Widget _fungalRiskCard() {
    final c = fungalRiskPercent >= 70
        ? Colors.red
        : fungalRiskPercent >= 40
        ? Colors.orange
        : Colors.green;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              color: c.withOpacity(0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.bug_report, color: c),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "$fungalRiskPercent% • $fungalLabel",
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  "Higher humidity and warmer temperature increases risk.",
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sensorCard(String title, String value, {Color? color}) {
    color ??= Colors.blueGrey;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.8), color],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(2, 2)),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  CONTROL TAB
  // ─────────────────────────────────────────────────────────────────────────
  Widget _controlTab({Key? key}) {
    return ListView(
      key: key,
      children: [
        const Text(
          "Control",
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _modeCard(),
        const SizedBox(height: 12),
        const Text(
          "Outputs",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),

        _relayCard(
          title: "Fan",
          subtitle: "Air circulation",
          icon: Icons.air,
          value: relay1,
          onChanged: autoMode
              ? null
              : (v) async {
                  setState(() => relay1 = v);
                  await _sendRelay(1, v);
                },
        ),
        _relayCard(
          title: "Cooler / AC",
          subtitle: "Cooling control",
          icon: Icons.ac_unit,
          value: relay2,
          onChanged: autoMode
              ? null
              : (v) async {
                  setState(() => relay2 = v);
                  await _sendRelay(2, v);
                },
        ),
        _relayCard(
          title: "Heater",
          subtitle: "Defrost / temp boost",
          icon: Icons.local_fire_department,
          value: relay3,
          onChanged: autoMode
              ? null
              : (v) async {
                  setState(() => relay3 = v);
                  await _sendRelay(3, v);
                },
        ),
        const SizedBox(height: 14),
        _hintCard(),
      ],
    );
  }

  Widget _modeCard() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white10,
        border: Border.all(
          color: autoMode
              ? Colors.green.withOpacity(0.4)
              : Colors.amber.withOpacity(0.4),
        ),
      ),
      child: Row(
        children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: autoMode
                  ? Colors.green.withOpacity(0.2)
                  : Colors.amber.withOpacity(0.2),
            ),
            child: Icon(
              autoMode ? Icons.auto_mode : Icons.handyman,
              size: 26,
              color: autoMode ? Colors.greenAccent : Colors.amberAccent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Mode",
                  style: TextStyle(fontSize: 14, color: Colors.white70),
                ),
                const SizedBox(height: 2),
                Text(
                  autoMode ? "AUTO" : "MANUAL",
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  autoMode
                      ? "System decides relay actions automatically"
                      : "You control relays manually",
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
          // FIX 3: Wait for ESP32 to confirm mode before flipping UI.
          //         Revert to old value if network call fails.
          Switch(
            value: autoMode,
            onChanged: (v) async {
              final success = await _sendMode(v);
              if (!mounted) return;
              if (success) {
                setState(() => autoMode = v);
              } else {
                setState(
                  () => _lastError = "Mode switch failed — check connection",
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _relayCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final enabled = onChanged != null;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled ? 1.0 : 0.55,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Colors.white10,
        ),
        child: Row(
          children: [
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: value ? Colors.green.withOpacity(0.2) : Colors.white12,
              ),
              child: Icon(
                icon,
                color: value ? Colors.greenAccent : Colors.white70,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  Widget _hintCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white10,
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: Colors.white70),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              "Tip: In AUTO mode, relays follow your safety rules. "
              "Switch to MANUAL for direct control.",
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  ANALYTICS TAB
  // ─────────────────────────────────────────────────────────────────────────
  Widget _analyticsTab({Key? key}) {
    List<double> temps = _historyReadings
        .map<double>((r) => (r['avg_temp'] ?? 0).toDouble())
        .toList();
    List<double> hums = _historyReadings
        .map<double>((r) => (r['avg_hum'] ?? 0).toDouble())
        .toList();
    List<double> gases = _historyReadings
        .map<double>((r) => (r['avg_gas'] ?? 0).toDouble())
        .toList();

    if (temps.isEmpty) temps = [tempMerged];
    if (hums.isEmpty) hums = [humMerged];
    if (gases.isEmpty) gases = [gasMerged];

    return ListView(
      key: key,
      children: [
        const Text(
          "Analytics",
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        _rangeChips(),
        const SizedBox(height: 10),

        if (_historyLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(30),
              child: CircularProgressIndicator(),
            ),
          )
        else ...[
          _chartCard(
            title: "Humidity Trend (%)",
            chart: _lineChart(hums, unit: "%"),
          ),
          _chartCard(
            title: "Temperature Trend (°C)",
            chart: _lineChart(temps, unit: "°C"),
          ),
          _chartCard(
            title: "Gas Trend (raw ADC)",
            chart: _lineChart(gases, unit: ""),
          ),
        ],

        const SizedBox(height: 8),
        _analyticsNoteCard(),
      ],
    );
  }

  Widget _rangeChips() {
    final items = ["Recent 10", "Last 20", "Last 30"];
    return Row(
      children: List.generate(items.length, (i) {
        final selected = _rangeIndex == i;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i == items.length - 1 ? 0 : 8),
            child: GestureDetector(
              onTap: () {
                setState(() => _rangeIndex = i);
                _loadHistory(_rangeToN(i));
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: selected ? Colors.white24 : Colors.white10,
                  border: Border.all(
                    color: selected ? Colors.white38 : Colors.transparent,
                  ),
                ),
                child: Center(
                  child: Text(
                    items[i],
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: selected ? Colors.white : Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _analyticsNoteCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white10,
      ),
      child: const Text(
        "Charts show live history from Flask /history API. "
        "Send readings from ESP32 to populate the graphs.",
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  Widget _chartCard({required String title, required Widget chart}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          SizedBox(height: 220, child: chart),
        ],
      ),
    );
  }

  Widget _lineChart(List<double> data, {String unit = ""}) {
    if (data.isEmpty) {
      return const Center(
        child: Text("No data", style: TextStyle(color: Colors.white54)),
      );
    }

    final spots = <FlSpot>[
      for (int i = 0; i < data.length; i++) FlSpot(i.toDouble(), data[i]),
    ];

    double minY = data.reduce(min);
    double maxY = data.reduce(max);
    final padding = (maxY - minY) == 0 ? 1.0 : (maxY - minY) * 0.15;
    minY -= padding;
    maxY += padding;

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(
          show: true,
          border: const Border(
            left: BorderSide(color: Colors.white24),
            bottom: BorderSide(color: Colors.white24),
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 42,
              interval: ((maxY - minY) / 4).abs() < 0.01
                  ? 1
                  : (maxY - minY) / 4,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(0),
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i % 2 != 0) return const SizedBox.shrink();
                return Text(
                  "t$i",
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchedSpots) => touchedSpots
                .map(
                  (s) => LineTooltipItem(
                    "${s.y.toStringAsFixed(1)}$unit",
                    const TextStyle(fontWeight: FontWeight.bold),
                  ),
                )
                .toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            barWidth: 3,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: true),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  ALERTS TAB
  // ─────────────────────────────────────────────────────────────────────────
  Widget _alertsTab({Key? key}) {
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Alerts",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _alerts.clear()),
              icon: const Icon(Icons.delete_outline),
              label: const Text("Clear"),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _alerts.isEmpty
              ? const Center(
                  child: Text(
                    "No alerts yet.",
                    style: TextStyle(color: Colors.white70),
                  ),
                )
              : ListView.builder(
                  itemCount: _alerts.length,
                  itemBuilder: (context, i) {
                    final a = _alerts[i];
                    final DateTime t = a["time"];
                    final String lv = a["level"];
                    final Color c = lv == "HIGH"
                        ? Colors.red
                        : lv == "MEDIUM"
                        ? Colors.orange
                        : Colors.green;

                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: c.withOpacity(0.35)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            height: 42,
                            width: 42,
                            decoration: BoxDecoration(
                              color: c.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(Icons.warning_amber_rounded, color: c),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a["title"],
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  a["message"],
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  "${t.hour.toString().padLeft(2, '0')}:"
                                  "${t.minute.toString().padLeft(2, '0')}"
                                  "  •  "
                                  "${t.day}/${t.month}/${t.year}",
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: c.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              lv,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: c,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
