import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';

import 'map_action_header.dart';
import 'package:shimbox_app/utils/api_service.dart';

// 아파트 모달
import 'bottom_sheet.dart';

class MapPage extends StatefulWidget {
  const MapPage({Key? key}) : super(key: key);

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  GoogleMapController? mapController;
  final Completer<GoogleMapController> _controllerCompleter = Completer();
  LatLng? currentLocation;

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;

  List<_Stop> _nearestStopsWithLabel = []; // 가까운 9개 후보 (라벨 포함)
  List<LatLng> get _nearestStops =>
      _nearestStopsWithLabel.map((e) => e.point).toList();

  Set<Marker> markers = {};
  Set<Polyline> polylines = {};

  bool _isUserInteracting = false;
  double? _lastBearing;
  Timer? _bearingUpdateTimer;

  bool _loadingStops = false;

  // 주소별(단지/도로명) → 상세목록(detailAddress들)
  Map<String, List<Map<String, String>>> apartmentGroups = {};

  // ==== Config ====
  static const _kakaoRestKey = 'a4ba47d483e2d8f8681d6c36474ff4fd';
  static const _googleApiKey = 'AIzaSyDcaQDrzTPJQ1bT2feHqyyo-LA_ijEXHCs';

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    await _initializeMap();
    await _loadNearest9StopsFromDB();
    _startTracking();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();
    _bearingUpdateTimer?.cancel();
    super.dispose();
  }

  // 초기화 & 현재 위치
  Future<void> _initializeMap() async {
    try {
      final loc = await _fetchCurrentLocation();
      if (!mounted) return;
      currentLocation = loc;
      _refreshMarkers();
      mapController?.animateCamera(CameraUpdate.newLatLngZoom(loc, 17));
    } catch (e) {
      print('❌ 초기화 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('현재 위치를 가져올 수 없습니다. 권한을 확인하세요.')),
        );
      }
    }
  }

  Future<LatLng> _fetchCurrentLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('위치 권한 거부됨');
      }
    }
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.best,
    );
    return LatLng(position.latitude, position.longitude);
  }

  void _startTracking() {
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((position) {
      final loc = LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      setState(() {
        currentLocation = loc;
        _refreshMarkers(keepStops: true);
      });
      if (!_isUserInteracting) {
        mapController?.animateCamera(CameraUpdate.newLatLng(loc));
      }
    });

    _compassSubscription = FlutterCompass.events?.listen((event) async {
      final heading = event.heading;
      if (heading == null || currentLocation == null || mapController == null) {
        return;
      }
      if (_isUserInteracting || !mounted) return;
      if (_lastBearing != null && (heading - _lastBearing!).abs() < 3) return;
      _lastBearing = heading;

      if (_bearingUpdateTimer?.isActive ?? false) return;
      _bearingUpdateTimer = Timer(const Duration(milliseconds: 300), () async {
        if (!mounted) return;
        final zoom = await mapController!.getZoomLevel();
        if (!mounted) return;
        mapController!.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: currentLocation!,
              zoom: zoom,
              bearing: heading,
              tilt: 0,
            ),
          ),
        );
      });
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // DB → 주소 → 좌표 → 가까운 9개
  // ─────────────────────────────────────────────────────────────────────────────
  Future<void> _loadNearest9StopsFromDB() async {
    if (currentLocation == null) {
      currentLocation = await _fetchCurrentLocation();
    }
    setState(() => _loadingStops = true);

    try {
      final data = await ApiService.fetchDeliverySummary();
      print('📦 DB rows: ${data.length}');
      final List<_StopWithDistance> bestList = [];
      apartmentGroups.clear();
      polylines = {}; // 새로고침할 때 기존 경로 제거

      // 두 형태 모두 지원: A) shippingLocation+groups[], B) address+detailAddress
      int parsedRows = 0;
      for (final row in data) {
        if (row is! Map) continue;

        // 1) 필드 추출 (대소문자/스네이크/카멜 다 시도)
        final base = _firstNonEmpty(row, const [
          'shippingLocation',
          'shipping_location',
          'address',
          'baseAddress',
          'shippingAddress',
        ]);
        final detail = _firstNonEmpty(row, const [
          'detailAddress',
          'detail_address',
          'detail',
          'subAddress',
        ]);

        if (base.isEmpty) continue; // 주소가 정말 없는 row

        // 2) 지오코딩은 base만 (동/호 제외)
        LatLng? pos = await _geocodeAddress(base);
        if (pos == null) {
          // 폴백: 키워드 검색으로도 한 번 더 시도
          pos = await _geocodeByKeyword(base);
        }
        if (pos == null) {
          print('⚠️ 지오코딩 실패 -> skip: "$base" (detail="$detail")');
          continue;
        }

        // 3) 거리 계산 + 후보 추가
        final d = Geolocator.distanceBetween(
          currentLocation!.latitude,
          currentLocation!.longitude,
          pos.latitude,
          pos.longitude,
        );
        bestList.add(_StopWithDistance(_Stop(base, pos), d));

        // 4) 모달용 상세 목록 저장
        apartmentGroups.putIfAbsent(base, () => []);
        apartmentGroups[base]!.add({'address': base, 'detail': detail});

        parsedRows++;
      }

      print('✅ parsedRows=$parsedRows, geocoded=${bestList.length}');

      // 가까운 순 정렬 후 Top 9만 유지
      bestList.sort((a, b) => a.distance.compareTo(b.distance));
      final finalStops =
          bestList
              .take(9)
              .map((e) => _Stop(e.stop.label, e.stop.point))
              .toList();

      if (!mounted) return;
      setState(() {
        _nearestStopsWithLabel = finalStops;
        _loadingStops = false;
      });

      _refreshMarkers();
      print('📍 경유지(Top9) 개수: ${_nearestStopsWithLabel.length}');

      if (_nearestStops.isNotEmpty && mapController != null) {
        final all = [currentLocation!, ..._nearestStops];
        final bounds = _boundsFromLatLngList(all);
        await mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 60),
        );
      }

      // 주소 불러온 직후 최적경로 자동 그리기
      if (currentLocation != null && _nearestStops.isNotEmpty) {
        await _drawGoogleOptimizedRoute(currentLocation!);
      }

      if (_nearestStopsWithLabel.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('표시할 주소가 없습니다. (DB 응답/지오코딩 확인)')),
        );
      }
    } catch (e) {
      print('❌ 주소 로드 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('주소 로드/좌표화 중 오류 발생')));
      }
      setState(() => _loadingStops = false);
    }
  }

  // row에서 첫 번째로 비어있지 않은 문자열 찾기
  String _firstNonEmpty(Map row, List<String> keys) {
    for (final k in keys) {
      if (row.containsKey(k)) {
        final v = row[k]?.toString().trim() ?? '';
        if (v.isNotEmpty) return v;
      }
    }
    return '';
  }

  // 주소 지오코딩 (정식 주소)
  Future<LatLng?> _geocodeAddress(String address) async {
    try {
      final url = Uri.parse(
        'https://dapi.kakao.com/v2/local/search/address.json?query=${Uri.encodeComponent(address)}',
      );
      final res = await http.get(
        url,
        headers: {'Authorization': 'KakaoAK $_kakaoRestKey'},
      );

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final docs = (body['documents'] as List?) ?? [];
        if (docs.isNotEmpty) {
          final x = double.tryParse(docs[0]['x'].toString());
          final y = double.tryParse(docs[0]['y'].toString());
          if (x != null && y != null) {
            return LatLng(y, x);
          }
        }
      } else {
        print('❌ Kakao address geocode fail: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      print('❌ Kakao address geocode error: $e');
    }
    return null;
  }

  // 키워드 검색 폴백 (주소 문자열이 애매할 때 근처 장소 좌표 반환)
  Future<LatLng?> _geocodeByKeyword(String keyword) async {
    try {
      final url = Uri.parse(
        'https://dapi.kakao.com/v2/local/search/keyword.json?query=${Uri.encodeComponent(keyword)}',
      );
      final res = await http.get(
        url,
        headers: {'Authorization': 'KakaoAK $_kakaoRestKey'},
      );

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final docs = (body['documents'] as List?) ?? [];
        if (docs.isNotEmpty) {
          final x = double.tryParse(docs[0]['x'].toString());
          final y = double.tryParse(docs[0]['y'].toString());
          if (x != null && y != null) {
            return LatLng(y, x);
          }
        }
      } else {
        print('❌ Kakao keyword geocode fail: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      print('❌ Kakao keyword geocode error: $e');
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // 구글 Directions 최적경로
  // ─────────────────────────────────────────────────────────────────────────────
  Future<void> _drawGoogleOptimizedRoute(LatLng start) async {
    if (_nearestStops.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('표시된 주소가 없습니다. 새로고침 해주세요.')));
      return;
    }

    final limitedStops = _nearestStops.take(9).toList();
    final end = limitedStops.last;
    final waypoints = limitedStops.sublist(0, max(0, limitedStops.length - 1));

    final origin = '${start.latitude},${start.longitude}';
    final destination = '${end.latitude},${end.longitude}';

    final waypointsStr =
        waypoints.isEmpty
            ? ''
            : '&waypoints=optimize:true|' +
                waypoints.map((e) => '${e.latitude},${e.longitude}').join('|');

    // 교통 반영을 원하면 departure_time=now & mode=driving 추가
    final url =
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=$origin'
        '&destination=$destination'
        '$waypointsStr'
        '&mode=driving&departure_time=now'
        '&key=$_googleApiKey';

    try {
      final res = await http.get(Uri.parse(url));
      print('🛰️ Directions statusCode: ${res.statusCode}');
      if (res.statusCode == 200) {
        final data = json.decode(res.body);

        // 실패 케이스도 잡아서 보여주기
        if (data['status'] != 'OK') {
          final msg =
              (data['error_message'] ?? data['status'] ?? 'UNKNOWN').toString();
          print('❌ Directions NOT OK: $msg');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Google Directions 오류: $msg')),
            );
          }
          return;
        }

        if (data['routes'] == null || (data['routes'] as List).isEmpty) {
          print('❌ Directions OK but no routes');
          return;
        }

        final points = data['routes'][0]['overview_polyline']['points'];
        final coords = _decodePolyline(points);

        if (!mounted) return;
        setState(() {
          polylines = {
            Polyline(
              polylineId: const PolylineId('google_route'),
              color: Colors.blueAccent,
              width: 6,
              points: coords,
            ),
          };
        });

        if (coords.isNotEmpty && mapController != null) {
          final bounds = _boundsFromLatLngList(coords);
          await mapController!.animateCamera(
            CameraUpdate.newLatLngBounds(bounds, 60),
          );
        }
      } else {
        final head =
            res.body.length > 300 ? res.body.substring(0, 300) : res.body;
        print('❌ Directions HTTP fail: ${res.statusCode} $head');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Directions HTTP 오류: ${res.statusCode}')),
          );
        }
      }
    } catch (e) {
      print('❌ Directions 예외: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Directions 요청 중 예외 발생')));
      }
    }
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      poly.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return poly;
  }

  // 마커
  void _refreshMarkers({bool keepStops = false}) {
    final Set<Marker> ms = keepStops ? {...markers} : <Marker>{};

    ms.removeWhere((m) => m.markerId.value == 'start');
    if (currentLocation != null) {
      ms.add(
        Marker(
          markerId: const MarkerId('start'),
          position: currentLocation!,
          infoWindow: const InfoWindow(title: '현재 위치'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        ),
      );
    }

    if (!keepStops) {
      ms.removeWhere((m) => m.markerId.value.startsWith('stop_'));
      for (int i = 0; i < _nearestStopsWithLabel.length; i++) {
        final s = _nearestStopsWithLabel[i];
        ms.add(
          Marker(
            markerId: MarkerId('stop_$i'),
            position: s.point,
            infoWindow: InfoWindow(title: s.label, snippet: '경유 ${i + 1}'),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            onTap: () {
              final deliveries = apartmentGroups[s.label] ?? [];
              _showApartmentDialog(s.label, deliveries);
            },
          ),
        );
      }
    }

    setState(() => markers = ms);
  }

  void _showApartmentDialog(
    String aptName,
    List<Map<String, String>> deliveries,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder:
          (ctx) =>
              ApartmentBottomSheet(aptName: aptName, deliveries: deliveries),
    );
  }

  LatLngBounds _boundsFromLatLngList(List<LatLng> list) {
    double minLat = list.first.latitude, maxLat = list.first.latitude;
    double minLng = list.first.longitude, maxLng = list.first.longitude;
    for (final p in list) {
      minLat = min(minLat, p.latitude);
      maxLat = max(maxLat, p.latitude);
      minLng = min(minLng, p.longitude);
      maxLng = max(maxLng, p.longitude);
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF2D5FFF);

    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: LatLng(37.5077, 126.8644),
              zoom: 15,
            ),
            myLocationEnabled: true,
            markers: markers,
            polylines: polylines,
            onMapCreated: (controller) {
              mapController = controller;
              if (!_controllerCompleter.isCompleted) {
                _controllerCompleter.complete(controller);
              }
              if (currentLocation != null) {
                mapController!.animateCamera(
                  CameraUpdate.newLatLngZoom(currentLocation!, 17),
                );
              }
            },
            onCameraMoveStarted: () => _isUserInteracting = true,
          ),

          MapActionHeader(
            onCurrentLocationPressed: () async {
              try {
                final controller = await _controllerCompleter.future;
                Position? last = await Geolocator.getLastKnownPosition();
                LatLng loc =
                    (last != null)
                        ? LatLng(last.latitude, last.longitude)
                        : await _fetchCurrentLocation();
                if (!mounted) return;

                final zoom = await controller.getZoomLevel();
                controller.animateCamera(
                  CameraUpdate.newCameraPosition(
                    CameraPosition(
                      target: loc,
                      zoom: zoom,
                      bearing: 0,
                      tilt: 0,
                    ),
                  ),
                );
                setState(() => currentLocation = loc);
                _refreshMarkers(keepStops: true);
              } catch (e) {
                print('❌ 위치 이동 실패: $e');
              }
            },
            onDrawRoutePressed: () {
              if (currentLocation != null) {
                _drawGoogleOptimizedRoute(currentLocation!);
              }
            },
          ),

          if (_loadingStops)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black26,
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loadNearest9StopsFromDB,
        backgroundColor: blue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.refresh),
        label: const Text('주소 새로고침'),
      ),
    );
  }
}

// 내부 모델
class _Stop {
  final String label;
  final LatLng point;
  _Stop(this.label, this.point);
}

class _StopWithDistance {
  final _Stop stop;
  final double distance;
  _StopWithDistance(this.stop, this.distance);
}
