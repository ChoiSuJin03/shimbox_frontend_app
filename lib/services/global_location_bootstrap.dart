import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng
import 'package:shimbox_app/controllers/location_controller.dart';
import 'package:shimbox_app/services/location_socket_service.dart';

class GlobalLocationBootstrap {
  GlobalLocationBootstrap._();
  static final instance = GlobalLocationBootstrap._();

  Timer? _tick;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    // 1) 권한 확보 + 현재 위치 1회 갱신
    await _ensurePermission();
    await _refreshOnce(); // 현재 좌표/주소 채워넣기

    // ✅ 연결 직후 즉시 1회 전송 예약 (홈에 안가도 첫 위치 전송)
    LocationSocketService.instance.markHomeEntered();

    // 2) 지역으로 WS 연결 (홈에 안 가도)
    await _connectWsByCurrentRegion();

    // 3) 주기적으로 현재 위치 갱신 + 소켓으로 전송
    _tick = Timer.periodic(const Duration(seconds: 20), (_) async {
      await _refreshOnce();
      if (LocationSocketService.instance.isConnected) {
        LocationSocketService.instance.sendLatestNow();
      } else {
        await _connectWsByCurrentRegion(); // 끊겨 있으면 재연결
      }
    });
  }

  Future<void> stop() async {
    _tick?.cancel();
    _tick = null;
    _started = false;
  }

  Future<void> _ensurePermission() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
    } catch (_) {}
  }

  Future<void> _refreshOnce() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      final p = await Geolocator.getCurrentPosition();
      // LocationController에는 updateByLatLng가 없으므로 setLatLng 사용
      await LocationController.to.setLatLng(
        LatLng(p.latitude, p.longitude),
        updateAddress: true, // 축약/전체 주소를 컨트롤러에서 갱신
      );
    } catch (_) {}
  }

  String _extractGu(String? s) {
    if (s == null) return '';
    final t = s.trim();
    final m = RegExp(r'([가-힣A-Za-z]+구)').firstMatch(t);
    return m != null ? m.group(1)! : '';
  }

  Future<void> _connectWsByCurrentRegion() async {
    // 현재 요약 주소에서 '구' 추출 → 지역 룸 접속
    final short = LocationController.to.currentShortAddress.value;
    var region = _extractGu(short);
    if (region.isEmpty) {
      // 마지막 fallback
      region = '성북구';
    }
    await LocationSocketService.instance.connect(region: region);
  }
}
