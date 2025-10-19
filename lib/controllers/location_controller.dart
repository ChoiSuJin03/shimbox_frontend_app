// lib/controllers/location_controller.dart
import 'dart:async';
import 'dart:convert';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import 'package:shimbox_app/services/location_socket_service.dart';

class LocationController extends GetxController {
  static LocationController get to => Get.find<LocationController>();

  final Rx<LatLng?> currentLatLng = Rx<LatLng?>(null);
  final RxString currentShortAddress = ''.obs;

  // ✅ 전체 주소 노출용 필드 (추가)
  final RxString currentFullAddress = ''.obs;

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
      // ✅ 전체 주소도 초기화
      currentFullAddress.value = '';
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
      // ✅ 전체 주소도 초기화
      currentFullAddress.value = '';
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

      // 초기 좌표/주소 등록 (전송은 서비스의 예약 로직이 담당)
      LocationSocketService.instance.updateLatestPosition(
        lat: pos.latitude,
        lng: pos.longitude,
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

      // 주기 전송은 서비스가 담당 → 최신 좌표만 갱신
      LocationSocketService.instance.updateLatestPosition(
        lat: pos.latitude,
        lng: pos.longitude,
        addressShort: currentShortAddress.value,
      );
    });
  }

  Future<void> setLatLng(LatLng latlng, {bool updateAddress = true}) async {
    currentLatLng.value = latlng;
    if (updateAddress) {
      _scheduleReverseGeocode(latlng);
    }

    LocationSocketService.instance.updateLatestPosition(
      lat: latlng.latitude,
      lng: latlng.longitude,
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
      // ✅ 기존: 축약 주소 업데이트
      _updateShortAddressBy(latlng);
      // ✅ 추가: 전체 주소 업데이트
      _updateFullAddressBy(latlng);
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

      final pos = currentLatLng.value;
      if (pos != null) {
        LocationSocketService.instance.updateLatestPosition(
          lat: pos.latitude,
          lng: pos.longitude,
          addressShort: short,
        );
      }
    } catch (e) {
      print('❌ [Kakao Local] 예외: $e');
      currentShortAddress.value = '';
    }
  }

  // ✅ 추가: 전체 주소 업데이트 (coord2address 사용)
  Future<void> _updateFullAddressBy(LatLng latlng) async {
    try {
      final url =
          'https://dapi.kakao.com/v2/local/geo/coord2address.json'
          '?x=${latlng.longitude}&y=${latlng.latitude}';

      final res = await http
          .get(
            Uri.parse(url),
            headers: {'Authorization': 'KakaoAK $_kakaoApiKey'},
          )
          .timeout(const Duration(seconds: 6));

      if (res.statusCode != 200) {
        print('❌ [Kakao Local] (full) 실패 status=${res.statusCode}');
        currentFullAddress.value = '';
        return;
      }

      final data = json.decode(res.body);
      final docs = (data['documents'] as List?) ?? [];
      if (docs.isEmpty) {
        print('❌ [Kakao Local] (full) documents 없음');
        currentFullAddress.value = '';
        return;
      }

      // 도로명 주소가 있으면 우선 사용, 없으면 지번 주소 사용
      final road = docs.first['road_address'];
      final addr = docs.first['address'];

      String full = '';
      if (road != null) {
        // 예: 경기도 광명시 광명동 오리로 1250-0 101동 101호
        final r1 = road['region_1depth_name'] ?? '';
        final r2 = road['region_2depth_name'] ?? '';
        final r3 = road['region_3depth_name'] ?? '';
        final roadName = road['road_name'] ?? '';
        final mainNo = road['main_building_no'] ?? '';
        final subNo =
            (road['sub_building_no'] ?? '').toString().isNotEmpty
                ? '-${road['sub_building_no']}'
                : '';
        final building = (road['building_name'] ?? '').toString().trim();
        final zone = (road['zone_no'] ?? '').toString().trim();

        // building/zone 존재 시 괄호로 보조 정보 덧붙임
        final extra = [
          building.isNotEmpty ? building : null,
          zone.isNotEmpty ? zone : null,
        ].whereType<String>().join(', ');

        full =
            '$r1 $r2 $r3 $roadName $mainNo$subNo${extra.isNotEmpty ? ' ($extra)' : ''}'
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
      } else if (addr != null) {
        final r1 = addr['region_1depth_name'] ?? '';
        final r2 = addr['region_2depth_name'] ?? '';
        final r3 = addr['region_3depth_name'] ?? '';
        final mNo = (addr['main_address_no'] ?? '').toString();
        final sNo = (addr['sub_address_no'] ?? '').toString();
        final detail = sNo.isNotEmpty ? '$mNo-$sNo' : mNo;

        full = '$r1 $r2 $r3 $detail'.replaceAll(RegExp(r'\s+'), ' ').trim();
      }

      currentFullAddress.value = full;
      print('✅ [Kakao Local] 전체 주소 업데이트: $full');
    } catch (e) {
      print('❌ [Kakao Local] (full) 예외: $e');
      currentFullAddress.value = '';
    }
  }
}
