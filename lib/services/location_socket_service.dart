// lib/services/location_socket_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimbox_app/models/test_user_data.dart' as localUser;
import 'package:shimbox_app/utils/api_service.dart';

// ✅ 건강 데이터 읽기용
import 'package:shimbox_app/pages/health/health_service.dart';

class LocationSocketService {
  LocationSocketService._();
  static final LocationSocketService instance = LocationSocketService._();

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  // 위치: 1분 주기 전송
  Timer? _locationPeriodicTimer;
  static const Duration _locationPeriodicInterval = Duration(minutes: 1);

  // 건강: 선택적 주기 전송 (HealthPage에서만 start/stop)
  Timer? _healthPeriodicTimer;
  Duration _healthPeriodicInterval = const Duration(seconds: 30);

  // 최신 위치/주소 캐시
  double? _latestLat;
  double? _latestLng;
  String? _latestAddress;

  // 홈 진입 시 즉시 1회 전송 예약 플래그(위치용)
  bool _pendingEnterSend = false;

  // 연결 정보
  String? _region;
  String? _token;
  Uri? _wsUri;

  // 연결 상태 플래그(채널 객체만으로는 부족)
  bool _opened = false;
  bool get isConnected => _opened && _ch != null;

  // 재연결 지수 백오프 (1s ~ 30s)
  int _retryMs = 1000;

  // ✅ 건강 데이터 소스
  final HealthService _health = HealthService();

  // ✅ 최신 피로도 캐시 (HealthPage에서 업데이트)
  double? _latestFatigueScore; // 0.0~1.0
  String? _latestFatigueLevel; // 좋음/보통/주의/위험 (서버표준은 "좋음/경고/위험" 사용)

  // ───────────────────────────────────────────
  // 외부에서 최신 피로도 값을 반영
  // ───────────────────────────────────────────
  void updateFatigue({required double score, required String level}) {
    _latestFatigueScore = score;
    _latestFatigueLevel = level;
  }

  // ───────────────────────────────────────────
  // 홈/메인에서 호출: "즉시 1회" 전송 예약 (위치)
  // ───────────────────────────────────────────
  void markHomeEntered() {
    _pendingEnterSend = true;
    _trySendEnterNow();
  }

  // 컨트롤러가 최신 좌표/주소를 알려줄 때 호출
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
    _trySendEnterNow(); // 좌표가 갱신되면, 예약된 1회 전송을 시도
  }

  // 지금 가진 최신 좌표를 즉시 1회 전송
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

  // 예약된 "홈 진입 1회" 전송을 조건 만족 시 실행
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

  // ───────────────────────────────────────────
  // 연결
  // ───────────────────────────────────────────
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
      // 서버 가이드: 기사(mobile)는 반드시 region 필요
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

      // 채널 생성 성공 → 일단 열린 상태로 간주, 백오프 리셋
      _opened = true;
      _retryMs = 1000;

      _sub = _ch!.stream.listen(
        (event) {
          // 서버 수신 처리 필요 시 사용
          // print('[WS] <= $event');
        },
        onDone: _scheduleReconnect,
        onError: (e, st) {
          print('[WS] error: $e');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      // keepalive ping (30초)
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        try {
          _ch?.sink.add(jsonEncode({'type': 'ping'}));
        } catch (_) {}
      });

      // 위치: 연결 직후 예약된 1회 전송 수행
      Future.microtask(_trySendEnterNow);

      // 위치: 1분 주기 전송 시작
      _locationPeriodicTimer?.cancel();
      _locationPeriodicTimer = Timer.periodic(_locationPeriodicInterval, (_) {
        sendLatestNow();
      });

      // 건강 자동 전송은 HealthPage에서 on/off
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
    _locationPeriodicTimer = null;

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
    _reconnectTimer = Timer(delay, () async {
      await connect(region: _region!);
    });
    _retryMs = (_retryMs * 2).clamp(1000, 30000);
  }

  // ───────────────────────────────────────────
  // 위치 전송
  // ───────────────────────────────────────────
  void sendLocation({
    required double lat,
    required double lng,
    required DateTime capturedAtUtc,
    String? addressShort,
  }) {
    final ch = _ch;
    if (ch == null) return;

    print('[WS][LOC] try send (connected=${_ch != null}) lat=$lat lng=$lng');

    final msg = {
      'type': 'location',
      'payload': {
        'lat': lat,
        'lng': lng,
        // ✅ 키 통일 (camelCase)
        'capturedAt': capturedAtUtc.toIso8601String(),
        if (addressShort != null && addressShort.isNotEmpty)
          'addressShort': addressShort,
      },
    };

    try {
      ch.sink.add(jsonEncode(msg));
      print('[WS][LOC] => $msg');
    } catch (e) {
      print('[WS][LOC] send failed: $e');
    }
  }

  // ───────────────────────────────────────────
  // ✅ 건강 전송 (스로틀 포함) — score/level/capturedAt로 통일
  // ───────────────────────────────────────────

  DateTime? _lastHealthSentAt;
  bool _healthInFlight = false;
  Duration _healthMinGap = const Duration(seconds: 3); // 최소 간격

  /// 건강 데이터 즉시 1회 전송 (심박/걸음수/피로도)
  Future<void> sendHealthNow() async {
    final ch = _ch;
    if (ch == null) return;

    // 최소 간격 보장 (스로틀)
    final now = DateTime.now();
    if (_lastHealthSentAt != null &&
        now.difference(_lastHealthSentAt!) < _healthMinGap) {
      print('[HEALTH-WS] throttled (min gap ${_healthMinGap.inSeconds}s)');
      return;
    }

    // 중복 실행 방지
    if (_healthInFlight) {
      print('[HEALTH-WS] skip (in-flight)');
      return;
    }

    print('[HEALTH-WS] try send (connected=${_ch != null})');

    _healthInFlight = true;
    try {
      final steps = await _health.getTodaySteps();
      final hr = await _health.getCurrentHeartRate();

      // ✅ 웹/서버 스키마와 키 통일 (camelCase)
      final msg = {
        'type': 'health',
        'payload': {
          'heartRate': hr,
          'step': steps,
          if (_latestFatigueScore != null) 'score': _latestFatigueScore,
          if (_latestFatigueLevel != null) 'level': _latestFatigueLevel,
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
        },
      };

      ch.sink.add(jsonEncode(msg));
      // ▼ 성공 로그: 전체 JSON + 별도 fatigue 로그
      print('[HEALTH-WS] => ${jsonEncode(msg)}');
      if (_latestFatigueScore != null && _latestFatigueLevel != null) {
        print(
          '[HEALTH-WS] fatigue score: ${_latestFatigueScore!.toStringAsFixed(3)}, fatigue level: $_latestFatigueLevel',
        );
      }

      _lastHealthSentAt = DateTime.now();
    } catch (e) {
      print('[HEALTH-WS] send failed: $e');
    } finally {
      _healthInFlight = false;
    }
  }

  /// (선택) 건강 데이터 주기 전송 시작 — HealthPage에서만 켜세요.
  void startHealthPeriodic({Duration interval = const Duration(seconds: 30)}) {
    _healthPeriodicInterval = interval;
    _healthPeriodicTimer?.cancel();
    _healthPeriodicTimer = Timer.periodic(_healthPeriodicInterval, (_) {
      sendHealthNow();
    });
    print(
      '[HEALTH-WS] start periodic every ${_healthPeriodicInterval.inSeconds}s',
    );
  }

  /// (선택) 건강 데이터 주기 전송 중지
  void stopHealthPeriodic() {
    if (_healthPeriodicTimer != null) {
      print('[HEALTH-WS] stop periodic');
    }
    _healthPeriodicTimer?.cancel();
    _healthPeriodicTimer = null;
  }
}
