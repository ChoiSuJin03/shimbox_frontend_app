// lib/controllers/location_controller.dart
import 'dart:async';
import 'dart:convert';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

// 추가: WebSocket 전송 서비스
import 'package:shimbox_app/services/location_socket_service.dart';

class LocationController extends GetxController {
  static LocationController get to => Get.find<LocationController>();

  final Rx<LatLng?> currentLatLng = Rx<LatLng?>(null);
  final RxString currentShortAddress = ''.obs;

  final String _kakaoApiKey = 'a4ba47d483e2d8f8681d6c36474ff4fd';

  StreamSubscription<Position>? _posSub;
  LatLng? _lastGeocodedLatLng;
  static const double _minMoveMetersForGeocode = 30;
  Timer? _reverseDebounce;

  @override
  void onReady() {
    super.onReady();
    startTracking();
  }

  @override
  void onClose() {
    _posSub?.cancel();
    _reverseDebounce?.cancel();
    super.onClose();
  }

  Future<void> startTracking({bool requestPermissionIfNeeded = true}) async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      print('❌ [Location] 위치 서비스 꺼짐');
      currentShortAddress.value = '';
      return;
    }

    var perm = await Geolocator.checkPermission();
    if ((perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) &&
        requestPermissionIfNeeded) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      print('❌ [Location] 권한 거부: $perm');
      currentShortAddress.value = '';
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 8),
      );
      final latlng = LatLng(pos.latitude, pos.longitude);
      currentLatLng.value = latlng;
      _scheduleReverseGeocode(latlng);

      // 최초 위치도 전송
      LocationSocketService.instance.sendLocation(
        lat: pos.latitude,
        lng: pos.longitude,
        capturedAtUtc: DateTime.now().toUtc(),
        addressShort: currentShortAddress.value,
      );
    } catch (e) {
      print('❌ [Location] 현재 위치 조회 실패: $e');
    }

    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      final latlng = LatLng(pos.latitude, pos.longitude);
      currentLatLng.value = latlng;
      _scheduleReverseGeocode(latlng);

      // 주기적 위치 전송
      LocationSocketService.instance.sendLocation(
        lat: pos.latitude,
        lng: pos.longitude,
        capturedAtUtc: DateTime.now().toUtc(),
        addressShort: currentShortAddress.value,
      );
    });
  }

  Future<void> setLatLng(LatLng latlng, {bool updateAddress = true}) async {
    currentLatLng.value = latlng;
    if (updateAddress) {
      _scheduleReverseGeocode(latlng);
    }

    // 수동 설정 시도 시에도 전송
    LocationSocketService.instance.sendLocation(
      lat: latlng.latitude,
      lng: latlng.longitude,
      capturedAtUtc: DateTime.now().toUtc(),
      addressShort: currentShortAddress.value,
    );
  }

  void _scheduleReverseGeocode(LatLng latlng) {
    if (_lastGeocodedLatLng != null) {
      final d = Geolocator.distanceBetween(
        _lastGeocodedLatLng!.latitude,
        _lastGeocodedLatLng!.longitude,
        latlng.latitude,
        latlng.longitude,
      );
      if (d < _minMoveMetersForGeocode) {
        return;
      }
    }

    _reverseDebounce?.cancel();
    _reverseDebounce = Timer(const Duration(milliseconds: 400), () {
      _updateShortAddressBy(latlng);
    });
  }

  Future<void> _updateShortAddressBy(LatLng latlng) async {
    _lastGeocodedLatLng = latlng;

    try {
      final url =
          'https://dapi.kakao.com/v2/local/geo/coord2regioncode.json'
          '?x=${latlng.longitude}&y=${latlng.latitude}';

      final res = await http
          .get(
            Uri.parse(url),
            headers: {'Authorization': 'KakaoAK $_kakaoApiKey'},
          )
          .timeout(const Duration(seconds: 6));

      if (res.statusCode != 200) {
        print('❌ [Kakao Local] 실패 status=${res.statusCode}');
        currentShortAddress.value = '';
        return;
      }

      final data = json.decode(res.body);
      final docs = (data['documents'] as List?) ?? [];
      if (docs.isEmpty) {
        print('❌ [Kakao Local] documents 없음');
        currentShortAddress.value = '';
        return;
      }

      final admin = docs.firstWhere(
        (e) => e['region_type'] == 'H',
        orElse: () => docs.first,
      );

      final r1 = admin['region_1depth_name'] ?? '';
      final r2 = admin['region_2depth_name'] ?? '';
      final short = '$r1 $r2'.trim();

      currentShortAddress.value = short;
      print('✅ [Kakao Local] 주소 업데이트: $short');

      // 주소 갱신 시에도 WS 전송
      final pos = currentLatLng.value;
      if (pos != null) {
        LocationSocketService.instance.sendLocation(
          lat: pos.latitude,
          lng: pos.longitude,
          capturedAtUtc: DateTime.now().toUtc(),
          addressShort: short,
        );
      }
    } catch (e) {
      print('❌ [Kakao Local] 예외: $e');
      currentShortAddress.value = '';
    }
  }
}
