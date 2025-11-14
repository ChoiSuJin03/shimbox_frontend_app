import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimbox_app/models/test_user_data.dart' as localUser;
import 'package:shimbox_app/utils/api_service.dart';
import 'package:shimbox_app/pages/health/health_service.dart';

class LocationSocketService {
  LocationSocketService._();
  static final LocationSocketService instance = LocationSocketService._();

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  Timer? _locationPeriodicTimer;
  static const Duration _locationPeriodicInterval = Duration(minutes: 1);

  Timer? _healthPeriodicTimer;
  Duration _healthPeriodicInterval = const Duration(seconds: 30);

  double? _latestLat;
  double? _latestLng;
  String? _latestAddress;

  bool _pendingEnterSend = false;

  String? _region;
  String? _token;
  Uri? _wsUri;

  bool _opened = false;
  bool get isConnected => _opened && _ch != null;

  int _retryMs = 1000;

  final HealthService _health = HealthService();

  double? _latestFatigueScore;
  String? _latestFatigueLevel;

  /// ✅ 캐시된 driverId (driverId 누락 시 fallback)
  int? _lastDriverIdHint;

  void updateFatigue({required double score, required String level}) {
    _latestFatigueScore = score;
    _latestFatigueLevel = level;
  }

  void markHomeEntered() {
    _pendingEnterSend = true;
    _trySendEnterNow();
  }

  void updateLatestPosition({
    required double lat,
    required double lng,
    String? addressShort,
  }) {
    _latestLat = lat;
    _latestLng = lng;
    if (addressShort != null && addressShort.isNotEmpty) {
      _latestAddress = addressShort;
    }

    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('last_lat', lat);
        await prefs.setDouble('last_lng', lng);
        if (_latestAddress != null && _latestAddress!.isNotEmpty) {
          await prefs.setString('last_addr_short', _latestAddress!);
        }
      } catch (_) {}
    }());

    _trySendEnterNow();
  }

  void sendLatestNow() {
    if (_ch == null) return;
    if (_latestLat == null || _latestLng == null) return;
    sendLocation(
      lat: _latestLat!,
      lng: _latestLng!,
      capturedAtUtc: DateTime.now().toUtc(),
      addressShort: _latestAddress,
    );
  }

  void _trySendEnterNow() {
    if (!_pendingEnterSend) return;
    if (!isConnected) {
      print('[WS][LOC] _trySendEnterNow: not connected yet');
      return;
    }
    if (_latestLat == null || _latestLng == null) {
      print('[WS][LOC] _trySendEnterNow: no coords yet');
      return;
    }
    print('[WS][LOC] _trySendEnterNow -> sendLatestNow()');
    sendLatestNow();
    _pendingEnterSend = false;
  }

  Uri _buildWsUri({required String token, required String region}) {
    final httpUri = Uri.parse(ApiService.baseUrl);
    final isSecure = httpUri.scheme == 'https';
    final scheme = isSecure ? 'wss' : 'ws';
    final host = httpUri.host;
    final port = httpUri.hasPort ? httpUri.port : (isSecure ? 443 : 80);
    return Uri(
      scheme: scheme,
      host: host,
      port: port,
      path: '/ws/location',
      queryParameters: {'token': token, 'as': 'mobile', 'region': region},
    );
  }

  Future<String?> _getToken() async {
    if ((localUser.UserData.token ?? '').isNotEmpty) {
      return localUser.UserData.token;
    }
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString('token');
    return (t != null && t.isNotEmpty) ? t : null;
  }

  Future<void> connect({required String region}) async {
    _region = region;
    _token = await _getToken();
    if (_token == null || _token!.isEmpty) return;

    _wsUri = _buildWsUri(token: _token!, region: region);
    print('[WS] connecting to ${_wsUri.toString()}');

    await _disposeChannel();
    try {
      _ch = WebSocketChannel.connect(_wsUri!);
      print('[WS] connected (channel created)');

      _opened = true;
      _retryMs = 1000;

      _sub = _ch!.stream.listen(
        (event) {},
        onDone: _scheduleReconnect,
        onError: (e, st) {
          print('[WS] error: $e');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        try {
          _ch?.sink.add(jsonEncode({'type': 'ping'}));
        } catch (_) {}
      });

      Future.microtask(_trySendEnterNow);

      _locationPeriodicTimer?.cancel();
      _locationPeriodicTimer = Timer.periodic(
        _locationPeriodicInterval,
        (_) => sendLatestNow(),
      );
    } catch (e) {
      print('[WS] connect failed: $e');
      _scheduleReconnect();
    }
  }

  Future<void> disconnect() async {
    _region = null;
    await _disposeChannel();
  }

  Future<void> _disposeChannel() async {
    print('[WS] _disposeChannel()');
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _pingTimer = null;
    _locationPeriodicTimer?.cancel();
    _healthPeriodicTimer?.cancel();
    _healthPeriodicTimer = null;
    await _sub?.cancel();
    _sub = null;

    try {
      await _ch?.sink.close(ws_status.normalClosure);
      print('[WS] sink closed (normalClosure)');
    } catch (_) {}
    _ch = null;
    _opened = false;
  }

  void _scheduleReconnect() {
    if (_region == null) return;
    _opened = false;
    _reconnectTimer?.cancel();
    final delay = Duration(milliseconds: _retryMs);
    print('[WS] reconnect in ${delay.inMilliseconds}ms');
    _reconnectTimer = Timer(delay, () async => await connect(region: _region!));
    _retryMs = (_retryMs * 2).clamp(1000, 30000);
  }

  // --------------------------
  // ✅ 공통 신원 필드 (driverId 캐시 포함)
  // --------------------------
  Map<String, dynamic> _identityFields() {
    final driverId = localUser.UserData.driverId;
    final driverName = localUser.UserData.name;
    final region = _region;

    if (driverId != null) _lastDriverIdHint = driverId;

    return {
      if (driverId != null) 'driverId': driverId,
      if (driverId != null) 'userId': driverId, // ★ userId = driverId로 함께 전송
      if (driverName != null && driverName.isNotEmpty) 'driverName': driverName,
      if (region != null && region.isNotEmpty) 'region': region,
      if (_token != null && _token!.isNotEmpty) 'token': _token,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> _withDriverIdFallback(Map<String, dynamic> base) {
    final hasDriver = base.containsKey('driverId') && base['driverId'] != null;
    if (!hasDriver && _lastDriverIdHint != null) {
      base['driverId'] = _lastDriverIdHint;
      print(
        '[HEALTH-WS] ⚠️ driverId missing → fallback to cached driverId=${_lastDriverIdHint}',
      );
    }
    return base;
  }

  // --------------------------
  // 위치 전송
  // --------------------------
  void sendLocation({
    required double lat,
    required double lng,
    required DateTime capturedAtUtc,
    String? addressShort,
  }) {
    final ch = _ch;
    if (ch == null) return;

    final payload = {
      ..._identityFields(),
      'lat': lat,
      'lng': lng,
      'capturedAt': capturedAtUtc.toIso8601String(),
      if (addressShort != null && addressShort.isNotEmpty)
        'addressShort': addressShort,
    };

    try {
      final msg = {'type': 'location', 'payload': payload};
      ch.sink.add(jsonEncode(msg));
      print('[WS][LOC] => $msg');
    } catch (e) {
      print('[WS][LOC] send failed: $e');
    }
  }

  // --------------------------
  // ✅ 건강/피로도 전송
  // --------------------------
  DateTime? _lastHealthSentAt;
  bool _healthInFlight = false;
  Duration _healthMinGap = const Duration(seconds: 3);

  Future<void> sendHealthNow() async {
    final ch = _ch;
    if (ch == null) return;

    final now = DateTime.now();
    if (_lastHealthSentAt != null &&
        now.difference(_lastHealthSentAt!) < _healthMinGap) {
      print('[HEALTH-WS] throttled');
      return;
    }
    if (_healthInFlight) {
      print('[HEALTH-WS] skip (in-flight)');
      return;
    }

    _healthInFlight = true;
    try {
      final steps = await _health.getTodaySteps();
      final hr = await _health.getCurrentHeartRate();

      final payload = _withDriverIdFallback({
        ..._identityFields(),
        'heartRate': hr,
        'step': steps,
        if (_latestFatigueScore != null) 'score': _latestFatigueScore,
        if (_latestFatigueLevel != null) 'level': _latestFatigueLevel,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
      });

      final msg = {'type': 'health', 'payload': payload};
      ch.sink.add(jsonEncode(msg));
      print('[HEALTH-WS] ✅ sent ${jsonEncode(msg)}');

      if (payload['driverId'] != null) {
        _lastDriverIdHint = payload['driverId'] as int?;
      }

      _lastHealthSentAt = DateTime.now();
    } catch (e) {
      print('[HEALTH-WS] send failed: $e');
    } finally {
      _healthInFlight = false;
    }
  }

  void startHealthPeriodic({Duration interval = const Duration(seconds: 30)}) {
    _healthPeriodicInterval = interval;
    _healthPeriodicTimer?.cancel();
    _healthPeriodicTimer = Timer.periodic(
      _healthPeriodicInterval,
      (_) => sendHealthNow(),
    );
    print(
      '[HEALTH-WS] start periodic every ${_healthPeriodicInterval.inSeconds}s',
    );
  }

  void stopHealthPeriodic() {
    _healthPeriodicTimer?.cancel();
    _healthPeriodicTimer = null;
  }

  // --------------------------
  // ✅ 낙상 이벤트 전송 (driverId 자동 보강)
  // --------------------------
  Future<void> sendHealthFall({
    required bool isDetected,
    DateTime? capturedAtUtc,
  }) async {
    final ch = _ch;
    if (ch == null) return;

    try {
      final steps = await _health.getTodaySteps();
      final hr = await _health.getCurrentHeartRate();

      var payload = {
        ..._identityFields(),
        'heartRate': hr,
        'step': steps,
        if (_latestFatigueScore != null) 'score': _latestFatigueScore,
        if (_latestFatigueLevel != null) 'level': _latestFatigueLevel,
        'isFallDetected': isDetected,
        'capturedAt':
            (capturedAtUtc ?? DateTime.now().toUtc()).toIso8601String(),
      };

      payload = _withDriverIdFallback(payload);

      final msg = {'type': 'health', 'payload': payload};
      ch.sink.add(jsonEncode(msg));
      print('[HEALTH-WS][FALL] ✅ sent ${jsonEncode(msg)}');

      if (payload['driverId'] != null) {
        _lastDriverIdHint = payload['driverId'] as int?;
      }
    } catch (e) {
      print('[HEALTH-WS][FALL] send failed: $e');
    }
  }
}
