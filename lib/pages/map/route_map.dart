import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import './map_action_header.dart';

// ✅ 디비 API (DeliveryDetailPage에서 쓰던 것과 동일한 서비스 사용)
import 'package:shimbox_app/utils/api_service.dart';

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

  // ✅ 가까운 9개 좌표(라벨 포함)
  List<_Stop> _nearestStopsWithLabel = [];
  // 경로 계산/카메라 바운즈용 (좌표만)
  List<LatLng> get _nearestStops =>
      _nearestStopsWithLabel.map((e) => e.point).toList();

  Set<Marker> markers = {};
  Set<Polyline> polylines = {};
  final String kakaoApiKey = 'a4ba47d483e2d8f8681d6c36474ff4fd';

  bool _isUserInteracting = false;
  double? _lastBearing;
  Timer? _bearingUpdateTimer;

  bool _loadingStops = false; // 지오코딩/선별 중 로딩 상태

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    await _initializeMap();
    // ✅ 현재 위치를 확보한 뒤 DB 주소 로드
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

  // =========================
  // 초기화 & 현재 위치
  // =========================
  Future<void> _initializeMap() async {
    try {
      final loc = await _fetchCurrentLocation();
      if (!mounted) return;
      currentLocation = loc;
      _refreshMarkers(); // 현재위치 마커만 먼저
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
        // 현재 위치만 갱신 (기존 스톱 마커는 유지)
        _refreshMarkers(keepStops: true);
      });
      if (!_isUserInteracting) {
        mapController?.animateCamera(CameraUpdate.newLatLng(loc));
      }
    });

    _compassSubscription = FlutterCompass.events?.listen((event) async {
      final heading = event.heading;
      if (heading == null || currentLocation == null || mapController == null)
        return;
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

  // =========================
  // DB → 주소 → 좌표(카카오) → 가까운 9개
  // =========================
  Future<void> _loadNearest9StopsFromDB() async {
    if (currentLocation == null) {
      currentLocation = await _fetchCurrentLocation();
    }
    setState(() => _loadingStops = true);

    try {
      final data = await ApiService.fetchDeliverySummary();

      // 1) 주소 목록 (라벨 포함). 동/호가 다르면 같은 좌표라도 각각 표시하고 싶으니 '중복 제거'는 하지 않음.
      final List<Map<String, String>> rawAddresses = [];
      for (final area in data) {
        final String base = (area['shippingLocation'] ?? '') as String;
        final List groups = (area['groups'] as List?) ?? [];
        for (final g in groups) {
          final String detail = (g['detailAddress'] ?? '') as String;
          final full = [
            base,
            detail,
          ].where((s) => s.trim().isNotEmpty).join(' ');
          if (full.trim().isNotEmpty) {
            rawAddresses.add({'full': full.trim(), 'base': base.trim()});
          }
        }
      }
      if (rawAddresses.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('표시할 주소가 없습니다.')));
        }
        setState(() => _loadingStops = false);
        return;
      }

      // 2) 지오코딩(실패 시 base로 재시도) + 거리 계산 → 가까운 9개 유지
      final List<_StopWithDistance> best9 = [];
      for (final a in rawAddresses) {
        final full = a['full']!;
        final base = a['base']!;
        final pos = await _geocodeWithFallback(full, base);
        if (pos == null) continue;

        final d = Geolocator.distanceBetween(
          currentLocation!.latitude,
          currentLocation!.longitude,
          pos.latitude,
          pos.longitude,
        );

        final stop = _Stop(full, pos);
        best9.add(_StopWithDistance(stop, d));
        best9.sort((x, y) => x.distance.compareTo(y.distance));
        if (best9.length > 9) best9.removeLast();
      }

      if (!mounted) return;

      // 3) 같은 좌표끼리 겹치지 않도록 지터 부여
      final Map<String, int> dupCount = {}; // "lat,lng" → 등장 횟수
      final List<_Stop> finalStops = [];
      for (final e in best9) {
        final p = e.stop.point;
        final key =
            '${p.latitude.toStringAsFixed(7)},${p.longitude.toStringAsFixed(7)}';
        final countSoFar = (dupCount[key] ?? 0);
        dupCount[key] = countSoFar + 1;
        final jittered = _jitterIfDuplicated(p, countSoFar);
        finalStops.add(_Stop(e.stop.label, jittered));
      }

      setState(() {
        _nearestStopsWithLabel = finalStops;
        _loadingStops = false;
      });

      _refreshMarkers();

      // 카메라 바운즈
      if (_nearestStops.isNotEmpty && mapController != null) {
        final all = [currentLocation!, ..._nearestStops];
        final bounds = _boundsFromLatLngList(all);
        await mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 60),
        );
      }
    } catch (e) {
      print('❌ 주소 로드/지오코딩 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('주소를 불러오거나 좌표화 중 오류가 발생했습니다.')),
        );
      }
      setState(() => _loadingStops = false);
    }
  }

  /// 카카오 로컬 주소검색 (full)
  Future<LatLng?> _geocodeAddress(String address) async {
    try {
      final uri = Uri.parse(
        'https://dapi.kakao.com/v2/local/search/address.json?query=${Uri.encodeComponent(address)}',
      );
      final res = await http.get(
        uri,
        headers: {'Authorization': 'KakaoAK $kakaoApiKey'},
      );
      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        final docs = (body['documents'] as List?) ?? [];
        if (docs.isNotEmpty) {
          final first = docs.first;
          final y = double.tryParse(first['y']?.toString() ?? '');
          final x = double.tryParse(first['x']?.toString() ?? '');
          if (x != null && y != null) return LatLng(y, x);
        }
      } else {
        print('❌ 지오코딩 실패(${res.statusCode}): ${res.body}');
      }
    } catch (e) {
      print('❌ 지오코딩 예외: $e');
    }
    return null;
  }

  /// detail 포함 full 주소로 실패하면 base 주소로 재시도
  Future<LatLng?> _geocodeWithFallback(String full, String base) async {
    final p1 = await _geocodeAddress(full);
    if (p1 != null) return p1;
    if (full.trim() != base.trim()) {
      final p2 = await _geocodeAddress(base);
      if (p2 != null) return p2;
    }
    return null;
  }

  /// 중복 좌표가 겹쳐 안 보일 때를 대비해 아주 작은 오프셋(1~3m)을 줘서 겹침 해소
  LatLng _jitterIfDuplicated(LatLng p, int dupIndex) {
    if (dupIndex == 0) return p;
    // 약 1~3m 정도의 미세 오프셋 (위/경도 1e-5는 대략 1m 내외)
    final dLat = 0.00001 * (dupIndex % 3);
    final dLng = 0.00001 * ((dupIndex ~/ 3) % 3);
    return LatLng(p.latitude + dLat, p.longitude + dLng);
  }

  // =========================
  // 마커/경로
  // =========================
  void _refreshMarkers({bool keepStops = false}) {
    final Set<Marker> ms = keepStops ? {...markers} : <Marker>{};

    // 현재위치 마커 새로고침
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
      // 스톱 마커 전체 갱신
      ms.removeWhere((m) => m.markerId.value.startsWith('stop_'));
      for (int i = 0; i < _nearestStopsWithLabel.length; i++) {
        final s = _nearestStopsWithLabel[i];
        ms.add(
          Marker(
            markerId: MarkerId('stop_$i'),
            position: s.point,
            infoWindow: InfoWindow(
              title: s.label, // ✅ 실제 주소 라벨 노출
              snippet: '경유 ${i + 1}', // 필요 없으면 제거 가능
            ),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
          ),
        );
      }
    }

    setState(() {
      markers = ms;
    });
  }

  List<LatLng> _greedyRoute(LatLng start, List<LatLng> mids) {
    final List<LatLng> route = [];
    final List<bool> visited = List.filled(mids.length, false);
    LatLng current = start;

    for (int i = 0; i < mids.length; i++) {
      double minDist = double.infinity;
      int minIdx = -1;
      for (int j = 0; j < mids.length; j++) {
        if (visited[j]) continue;
        final dist = Geolocator.distanceBetween(
          current.latitude,
          current.longitude,
          mids[j].latitude,
          mids[j].longitude,
        );
        if (dist < minDist) {
          minDist = dist;
          minIdx = j;
        }
      }
      visited[minIdx] = true;
      route.add(mids[minIdx]);
      current = mids[minIdx];
    }

    return route;
  }

  Future<void> _drawRouteFrom(LatLng start) async {
    if (_nearestStops.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('표시된 주소지가 없습니다. 새로고침 해주세요.')),
      );
      return;
    }

    final ordered = _greedyRoute(start, _nearestStops);
    final end = ordered.last;
    final mids = ordered.sublist(0, max(0, ordered.length - 1));

    final origin = '${start.longitude},${start.latitude}';
    final destination = '${end.longitude},${end.latitude}';
    final waypointsStr = mids
        .map((e) => '${e.longitude},${e.latitude}')
        .join('|');

    final url =
        'https://apis-navi.kakaomobility.com/v1/directions?origin=$origin&destination=$destination'
        '${waypointsStr.isNotEmpty ? '&waypoints=$waypointsStr' : ''}';

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'KakaoAK $kakaoApiKey'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] == null || data['routes'].isEmpty) return;

        final List sections = data['routes'][0]['sections'];
        List<LatLng> coords = [];

        for (var section in sections) {
          for (var road in section['roads']) {
            final vertexes = road['vertexes'];
            for (int i = 0; i < vertexes.length; i += 2) {
              coords.add(LatLng(vertexes[i + 1], vertexes[i]));
            }
          }
        }

        if (!mounted) return;
        setState(() {
          polylines = {
            Polyline(
              polylineId: const PolylineId('route'),
              color: Colors.deepPurple,
              width: 6,
              jointType: JointType.round,
              patterns: [PatternItem.dot, PatternItem.gap(10)],
              endCap: Cap.roundCap,
              startCap: Cap.roundCap,
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
        print('❌ 경로 요청 실패: ${response.body}');
      }
    } catch (e) {
      print('❌ 경로 요청 중 예외 발생: $e');
    }
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

  // =========================
  // UI
  // =========================
  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF2D5FFF); // ✅ 아이콘과 통일된 파란색

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
            onCameraMoveStarted: () {
              _isUserInteracting = true;
            },
          ),

          // 상단 액션 (현재 위치 / 경로 그리기 등)
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
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('위치를 가져올 수 없습니다. 권한을 확인하세요.')),
                  );
                }
              }
            },
            onDrawRoutePressed: () {
              if (currentLocation != null) {
                _drawRouteFrom(currentLocation!);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('현재 위치를 먼저 가져오는 중입니다.')),
                );
              }
            },
          ),

          // ✅ 지오코딩/선별 로딩 덮개
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

      // ✅ 파란색 “주소 새로고침” 버튼 (아이콘/텍스트 흰색)
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

// =========================
// 내부 모델
// =========================

class _Stop {
  final String label; // InfoWindow에 표시할 실제 주소 문자열
  final LatLng point;
  _Stop(this.label, this.point);
}

class _StopWithDistance {
  final _Stop stop;
  final double distance;
  _StopWithDistance(this.stop, this.distance);
}
