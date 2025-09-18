// lib/controllers/location_controller.dart
import 'dart:async';
import 'dart:convert';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class LocationController extends GetxController {
  static LocationController get to => Get.find<LocationController>();

  /// 상태
  final Rx<LatLng?> currentLatLng = Rx<LatLng?>(null);

  /// 예: "서울특별시 성북구" / "경기도 성남시 분당구"
  final RxString currentShortAddress = ''.obs;

  /// Kakao REST API Key (로컬/역지오코딩 용) — 실제 서비스에선 서버 프록시 권장
  final String _kakaoApiKey = 'a4ba47d483e2d8f8681d6c36474ff4fd';

  StreamSubscription<Position>? _posSub;

  /// 역지오코딩 호출 빈도 조절용 (좌표 변화가 작으면 스킵)
  LatLng? _lastGeocodedLatLng;
  static const double _minMoveMetersForGeocode = 30; // 30m 이상 이동 시에만 역지오코딩

  /// 연속 호출 방지용 타이머 (디바운스)
  Timer? _reverseDebounce;

  @override
  void onReady() {
    super.onReady();
    // 앱 구동 시 단 1회 시작
    startTracking();
  }

  @override
  void onClose() {
    _posSub?.cancel();
    _reverseDebounce?.cancel();
    super.onClose();
  }

  /// 위치 추적 시작 (권한/서비스 체크 포함)
  Future<void> startTracking({bool requestPermissionIfNeeded = true}) async {
    // 1) 위치 서비스 켜짐 여부
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      print('❌ [Location] 위치 서비스가 꺼져 있습니다.');
      currentShortAddress.value = ''; // UI는 "위치 확인 중..."일 수 있음
      return;
    }

    // 2) 권한 체크/요청
    var perm = await Geolocator.checkPermission();
    if ((perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) &&
        requestPermissionIfNeeded) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      print('❌ [Location] 권한 거부 상태: $perm');
      currentShortAddress.value = '';
      return;
    }

    // 3) 최초 1회 현재 위치
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 8),
      );
      final latlng = LatLng(pos.latitude, pos.longitude);
      currentLatLng.value = latlng;
      _scheduleReverseGeocode(latlng); // 디바운스 적용
    } catch (e) {
      print('❌ [Location] 현재 위치 조회 실패: $e');
      // 주소 비움 → 홈은 "위치 확인 중..." 유지
    }

    // 4) 스트림 구독 (10m 변위)
    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      final latlng = LatLng(pos.latitude, pos.longitude);
      currentLatLng.value = latlng;
      _scheduleReverseGeocode(latlng); // 이동 시 역지오코딩 (디바운스/거리 임계)
    });
  }

  /// 외부(MapPage 등)에서 좌표를 직접 반영할 때 사용
  Future<void> setLatLng(LatLng latlng, {bool updateAddress = true}) async {
    currentLatLng.value = latlng;
    if (updateAddress) {
      _scheduleReverseGeocode(latlng);
    }
  }

  /// 역지오코딩 호출 스케줄링(디바운스 + 이동 거리 임계)
  void _scheduleReverseGeocode(LatLng latlng) {
    // 이동거리 체크 (너무 자주 호출 방지)
    if (_lastGeocodedLatLng != null) {
      final d = Geolocator.distanceBetween(
        _lastGeocodedLatLng!.latitude,
        _lastGeocodedLatLng!.longitude,
        latlng.latitude,
        latlng.longitude,
      );
      if (d < _minMoveMetersForGeocode) {
        // 30m 미만 이동이면 스킵
        return;
      }
    }

    _reverseDebounce?.cancel();
    _reverseDebounce = Timer(const Duration(milliseconds: 400), () {
      _updateShortAddressBy(latlng);
    });
  }

  /// Kakao Local: 좌표 → 행정동(시/구/동)
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
        print('❌ [Kakao Local] 실패 status=${res.statusCode} body=${res.body}');
        // 실패 시 비움 (UI는 "위치 확인 중...")
        currentShortAddress.value = '';
        return;
      }

      final data = json.decode(res.body);
      final docs = (data['documents'] as List?) ?? [];
      if (docs.isEmpty) {
        print('❌ [Kakao Local] documents가 비었습니다. body=${res.body}');
        currentShortAddress.value = '';
        return;
      }

      // region_type == 'H'(행정동)이 있으면 우선 사용, 없으면 첫 항목
      final admin = docs.firstWhere(
        (e) => e['region_type'] == 'H',
        orElse: () => docs.first,
      );

      final r1 = admin['region_1depth_name'] ?? '';
      final r2 = admin['region_2depth_name'] ?? '';
      // 필요 시 r3도 사용 가능
      // final r3 = admin['region_3depth_name'] ?? '';

      final short = '$r1 $r2'.trim();
      currentShortAddress.value = short;
      print('✅ [Kakao Local] 주소 업데이트: $short');
    } catch (e) {
      print('❌ [Kakao Local] 예외: $e');
      currentShortAddress.value = '';
    }
  }
}
