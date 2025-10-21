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

  bool get isConnected => _ch != null;

  // ✅ 건강 데이터 소스
  final HealthService _health = HealthService();

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
    if (!_pendingEnterSend) {
      // ignore
      // print('[WS][LOC] _trySendEnterNow: no pending');
      return;
    }
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

      _sub = _ch!.stream.listen(
        (event) {
          // 서버로부터의 수신이 필요하면 여기서 처리
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

      // ✅ 건강: 자동 주기 전송은 기본 OFF.
      // 필요하면 HealthPage에서 startHealthPeriodic() 호출해서 켜세요.
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
  }

  void _scheduleReconnect() {
    if (_region == null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      connect(region: _region!);
    });
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
        'captured_at': capturedAtUtc.toIso8601String(),
        if (addressShort != null && addressShort.isNotEmpty)
          'address_short': addressShort,
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
  // ✅ 건강 전송 (스로틀 포함)
  // ───────────────────────────────────────────

  DateTime? _lastHealthSentAt;
  bool _healthInFlight = false;
  Duration _healthMinGap = const Duration(seconds: 3); // 최소 간격

  /// 건강 데이터 즉시 1회 전송 (심박/걸음수)
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

    // 중복 실행 방지 (겹쳐 호출될 때)
    if (_healthInFlight) {
      print('[HEALTH-WS] skip (in-flight)');
      return;
    }

    print('[HEALTH-WS] try send (connected=${_ch != null})');

    _healthInFlight = true;
    try {
      final steps = await _health.getTodaySteps();
      final hr = await _health.getCurrentHeartRate();

      final msg = {
        'type': 'health',
        'payload': {
          'heartRate': hr,
          'step': steps,
          // 기사 -> 서버 형식은 snake_case
          'recorded_at': DateTime.now().toUtc().toIso8601String(),
        },
      };

      ch.sink.add(jsonEncode(msg));
      print('[HEALTH-WS] => $msg');

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
