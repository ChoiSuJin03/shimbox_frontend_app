// lib/controllers/global_location_bootstrap.dart
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng
import 'package:shared_preferences/shared_preferences.dart'; // ★ ADDED
import 'package:shimbox_app/controllers/location_controller.dart';
import 'package:shimbox_app/services/location_socket_service.dart';

class GlobalLocationBootstrap {
  GlobalLocationBootstrap._();
  static final instance = GlobalLocationBootstrap._();

  Timer? _tick;
  bool _started = false;

  static const String _regionHint = '구로구동양미래대';

  Future<void> start() async {
    if (_started) return;
    _started = true;

    // ★ ADDED: 캐시된 좌표를 즉시 복구 → 화면/WS에 바로 사용
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble('last_lat');
      final lng = prefs.getDouble('last_lng');
      final addr = prefs.getString('last_addr_short');
      if (lat != null && lng != null) {
        await LocationController.to.setLatLng(
          LatLng(lat, lng),
          updateAddress: false,
        );
        LocationSocketService.instance.updateLatestPosition(
          lat: lat,
          lng: lng,
          addressShort: addr,
        );
        LocationSocketService.instance.sendLatestNow();
      }
    } catch (_) {}

    await _ensurePermission();

    // 주소 포함 1회 강제 갱신
    await _refreshOnce(updateAddress: true);

    // ★ CHANGED: 지역 미확정이어도 먼저 '전국'으로 즉시 연결 후, 확정 시 재연결
    await _connectWsByCurrentRegion();

    // 빠른 전송 2회
    await _sendLastKnownFast();
    await _sendCurrentFast();

    // 주기 송신
    _tick = Timer.periodic(const Duration(seconds: 20), (_) async {
      await _sendCurrentFast(); // 즉시 송신 시도(짧은 타임리밋)
      unawaited(_refreshOnce(updateAddress: true));

      if (LocationSocketService.instance.isConnected) {
        LocationSocketService.instance.sendLatestNow();
      } else {
        await _connectWsByCurrentRegion();
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

  Future<void> _refreshOnce({required bool updateAddress}) async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      final p = await Geolocator.getCurrentPosition();
      await LocationController.to.setLatLng(
        LatLng(p.latitude, p.longitude),
        updateAddress: updateAddress,
      );
    } catch (_) {}
  }

  Future<void> _sendLastKnownFast() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        await LocationController.to.setLatLng(
          LatLng(last.latitude, last.longitude),
          updateAddress: false,
        );
        LocationSocketService.instance.sendLatestNow();
      }
    } catch (_) {}
  }

  Future<void> _sendCurrentFast() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
        timeLimit: const Duration(milliseconds: 300), // ★ CHANGED: 300ms
      );
      await LocationController.to.setLatLng(
        LatLng(p.latitude, p.longitude),
        updateAddress: false,
      );
      LocationSocketService.instance.sendLatestNow();
    } catch (_) {
      // 실패해도 캐시/lastKnown로 이미 화면은 채워짐
    }
  }

  String _extractGu(String? s) {
    if (s == null) return '';
    final t = s.trim();
    final m = RegExp(r'([가-힣A-Za-z]+구)').firstMatch(t);
    return m != null ? m.group(1)! : '';
  }

  Future<void> _connectWsByCurrentRegion() async {
    // ★ ADDED: 일단 즉시 '전국' 룸으로 붙기(빈 화면 방지)
    if (!LocationSocketService.instance.isConnected) {
      await LocationSocketService.instance.connect(region: '전국');
    }

    // 이후 짧게 기다려 구를 얻고, 확정되면 재연결
    final region = await _resolveGuWithWait(
      maxWait: const Duration(milliseconds: 1200),
    );
    String finalRegion = region ?? '';

    if (finalRegion.isEmpty) {
      final hintGu = _extractGu(_regionHint);
      if (hintGu.isNotEmpty) finalRegion = hintGu;
    }
    if (finalRegion.isEmpty) {
      finalRegion = '전국';
    }

    // 같은 region이면 서버가 무시, 다르면 재연결
    await LocationSocketService.instance.connect(region: finalRegion);
  }

  Future<String?> _resolveGuWithWait({required Duration maxWait}) async {
    final start = DateTime.now();
    while (true) {
      final short = LocationController.to.currentShortAddress.value;
      final gu = _extractGu(short);
      if (gu.isNotEmpty) return gu;

      if (DateTime.now().difference(start) >= maxWait) {
        return null;
      }
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }
}
