// lib/services/location_socket_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimbox_app/models/test_user_data.dart' as localUser;
import 'package:shimbox_app/utils/api_service.dart';

class LocationSocketService {
  LocationSocketService._();
  static final LocationSocketService instance = LocationSocketService._();

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  // 1분 주기 전송
  Timer? _periodicTimer;
  static const Duration _periodicInterval = Duration(minutes: 1);

  // 최신 위치/주소 캐시
  double? _latestLat;
  double? _latestLng;
  String? _latestAddress;

  // 홈 진입 시 즉시 1회 전송 예약 플래그
  bool _pendingEnterSend = false;

  String? _region;
  String? _token;
  Uri? _wsUri;

  bool get isConnected => _ch != null;

  /// 홈 화면에 들어왔을 때 호출: "즉시 1회"를 예약하고, 가능하면 즉시 전송
  void markHomeEntered() {
    _pendingEnterSend = true;
    _trySendEnterNow();
  }

  /// 컨트롤러가 최신 좌표/주소를 알려줄 때 호출
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

  /// 지금 가진 최신 좌표를 즉시 1회 전송
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

  /// 예약된 "홈 진입 1회" 전송을 조건 만족 시 실행
  void _trySendEnterNow() {
    if (!_pendingEnterSend) return;
    if (!isConnected) return;
    if (_latestLat == null || _latestLng == null) return;
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

    await _disposeChannel();
    try {
      _ch = WebSocketChannel.connect(_wsUri!);
      _sub = _ch!.stream.listen(
        (event) {
          // print('WS <- $event');
        },
        onDone: _scheduleReconnect,
        onError: (e, st) => _scheduleReconnect(),
        cancelOnError: true,
      );

      // keepalive ping (30초)
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        try {
          _ch?.sink.add(jsonEncode({'type': 'ping'}));
        } catch (_) {}
      });

      // 연결 직후: 홈 진입 1회 전송 예약이 있다면 바로 시도
      // (좌표가 이미 준비돼 있으면 즉시 전송됨)
      Future.microtask(_trySendEnterNow);

      // 1분 주기 전송 시작
      _periodicTimer?.cancel();
      _periodicTimer = Timer.periodic(_periodicInterval, (_) {
        sendLatestNow();
      });
    } catch (_) {
      _scheduleReconnect();
    }
  }

  Future<void> disconnect() async {
    _region = null;
    await _disposeChannel();
  }

  Future<void> _disposeChannel() async {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _pingTimer = null;

    _periodicTimer?.cancel();
    _periodicTimer = null;

    await _sub?.cancel();
    _sub = null;

    try {
      await _ch?.sink.close(ws_status.normalClosure);
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

  /// 실제 WS 전송
  void sendLocation({
    required double lat,
    required double lng,
    required DateTime capturedAtUtc,
    String? addressShort,
  }) {
    final ch = _ch;
    if (ch == null) return;

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
      // print("WS -> $msg");
    } catch (_) {}
  }
}
