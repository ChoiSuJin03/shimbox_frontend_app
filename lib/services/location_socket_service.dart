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

  String? _region;
  String? _token;
  Uri? _wsUri;

  bool get isConnected => _ch != null;

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
          // 서버 응답 확인용 로그
          // print('WS <- $event');
        },
        onDone: _scheduleReconnect,
        onError: (e, st) => _scheduleReconnect(),
        cancelOnError: true,
      );

      // keepalive
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        try {
          _ch?.sink.add(jsonEncode({'type': 'ping'}));
        } catch (_) {}
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

  /// 위치 전송
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
