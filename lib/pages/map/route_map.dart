// lib/pages/map/map_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';

import 'widgets/map_action_header.dart';
import 'package:shimbox_app/utils/api_service.dart';
import 'widgets/bottom_sheet.dart';

// SVG 숫자/라벨 마커
import 'widgets/numbered_marker_icon.dart';

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

  // 방문 순서 결과 저장
  List<_Stop> _orderedStops = [];
  Map<LatLng, int> _orderIndex = {}; // point -> 1-based index

  List<_Stop> _nearestStopsWithLabel = []; // 가까운 후보 (라벨 포함)
  List<LatLng> get _nearestStops =>
      _nearestStopsWithLabel.map((e) => e.point).toList();

  Set<Marker> markers = {};
  Set<Polyline> polylines = {};

  bool _isUserInteracting = false;
  double? _lastBearing;
  Timer? _bearingUpdateTimer;

  bool _loadingStops = false;

  Map<String, List<Map<String, String>>> apartmentGroups = {};

  // ==== Config ====
  static const _kakaoRestKey = 'a4ba47d483e2d8f8681d6c36474ff4fd';

  // SVG 경로 (출발: 파랑, 경유지: 빨강)
  static const _pinBlue = 'assets/images/map/pin_blue.svg';
  static const _pinRed = 'assets/images/map/pin_red.svg';

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
      await _refreshMarkers(); // 초기 마커 반영
      mapController?.animateCamera(CameraUpdate.newLatLngZoom(loc, 17));
    } catch (e) {
      debugPrint('❌ 초기화 실패: $e');
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
    ).listen((position) async {
      final loc = LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      setState(() {
        currentLocation = loc;
      });
      await _refreshMarkers(keepStops: true);
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
      debugPrint('📦 DB rows: ${data.length}');
      final List<_StopWithDistance> bestList = [];
      apartmentGroups.clear();
      polylines = {}; // 새로고침 시 기존 경로 제거

      int parsedRows = 0;
      for (final row in data) {
        if (row is! Map) continue;

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

        if (base.isEmpty) continue;

        LatLng? pos = await _geocodeAddress(base);
        if (pos == null) pos = await _geocodeByKeyword(base);
        if (pos == null) {
          debugPrint('⚠️ 지오코딩 실패 -> skip: "$base" (detail="$detail")');
          continue;
        }

        final d = Geolocator.distanceBetween(
          currentLocation!.latitude,
          currentLocation!.longitude,
          pos.latitude,
          pos.longitude,
        );
        bestList.add(_StopWithDistance(_Stop(base, pos), d));

        apartmentGroups.putIfAbsent(base, () => []);
        apartmentGroups[base]!.add({'address': base, 'detail': detail});
        parsedRows++;
      }

      debugPrint('✅ parsedRows=$parsedRows, geocoded=${bestList.length}');

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

      await _refreshMarkers();
      debugPrint('📍 경유지(Top9) 개수: ${_nearestStopsWithLabel.length}');

      if (_nearestStops.isNotEmpty && mapController != null) {
        final all = [currentLocation!, ..._nearestStops];
        final bounds = _boundsFromLatLngList(all);
        await mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 60),
        );
      }

      // 주소 불러온 직후: 방문 순서 최적화 + 카카오 경로
      if (currentLocation != null && _nearestStops.isNotEmpty) {
        await _drawOptimizedKakaoRoute(currentLocation!);
      }

      if (_nearestStopsWithLabel.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('표시할 주소가 없습니다. (DB 응답/지오코딩 확인)')),
        );
      }
    } catch (e) {
      debugPrint('❌ 주소 로드 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('주소 로드/좌표화 중 오류 발생')));
      }
      setState(() => _loadingStops = false);
    }
  }

  String _firstNonEmpty(Map row, List<String> keys) {
    for (final k in keys) {
      if (row.containsKey(k)) {
        final v = row[k]?.toString().trim() ?? '';
        if (v.isNotEmpty) return v;
      }
    }
    return '';
  }

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
          if (x != null && y != null) return LatLng(y, x);
        }
      } else {
        debugPrint(
          '❌ Kakao address geocode fail: ${res.statusCode} ${res.body}',
        );
      }
    } catch (e) {
      debugPrint('❌ Kakao address geocode error: $e');
    }
    return null;
  }

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
          if (x != null && y != null) return LatLng(y, x);
        }
      } else {
        debugPrint(
          '❌ Kakao keyword geocode fail: ${res.statusCode} ${res.body}',
        );
      }
    } catch (e) {
      debugPrint('❌ Kakao keyword geocode error: $e');
    }
    return null;
  }

  // ───────── 휴리스틱 (Nearest Neighbor + 2-opt) ─────────
  double _haversine(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = (b.latitude - a.latitude) * (pi / 180.0);
    final dLon = (b.longitude - a.longitude) * (pi / 180.0);
    final la1 = a.latitude * (pi / 180.0);
    final la2 = b.latitude * (pi / 180.0);
    final h =
        sin(dLat / 2) * sin(dLat / 2) +
        sin(dLon / 2) * sin(dLon / 2) * cos(la1) * cos(la2);
    return 2 * R * atan2(sqrt(h), sqrt(1 - h));
  }

  List<LatLng> _nearestNeighborOrder(LatLng start, List<LatLng> points) {
    final unvis = List<LatLng>.from(points);
    final route = <LatLng>[];
    var cur = start;
    while (unvis.isNotEmpty) {
      unvis.sort((a, b) => _haversine(cur, a).compareTo(_haversine(cur, b)));
      final next = unvis.removeAt(0);
      route.add(next);
      cur = next;
    }
    return route;
  }

  List<LatLng> _twoOptImprove(
    LatLng start,
    List<LatLng> route, {
    int maxIter = 2000,
  }) {
    double total(List<LatLng> r) {
      var sum = _haversine(start, r.first);
      for (var i = 0; i < r.length - 1; i++) sum += _haversine(r[i], r[i + 1]);
      return sum;
    }

    var best = List<LatLng>.from(route);
    var bestCost = total(best);
    var iter = 0;
    var improved = true;

    while (improved && iter < maxIter) {
      improved = false;
      for (int i = 0; i < best.length - 1; i++) {
        for (int k = i + 1; k < best.length; k++) {
          final candidate = [
            ...best.sublist(0, i),
            ...best.sublist(i, k + 1).reversed,
            ...best.sublist(k + 1),
          ];
          final c = total(candidate);
          if (c + 1e-6 < bestCost) {
            best = candidate;
            bestCost = c;
            improved = true;
          }
          if (++iter >= maxIter) break;
        }
        if (iter >= maxIter) break;
      }
    }
    return best;
  }

  List<LatLng> _optimizeStops(LatLng start, List<LatLng> stops) {
    if (stops.isEmpty) return stops;
    final nn = _nearestNeighborOrder(start, stops);
    return _twoOptImprove(start, nn);
  }

  // ───────── Kakao Directions → 구글맵 폴리라인 ─────────
  Future<bool> _drawKakaoDrivingRoute({
    required LatLng origin,
    required LatLng destination,
    required List<LatLng> waypoints,
  }) async {
    try {
      String fmt(LatLng p) => '${p.longitude},${p.latitude}'; // lng,lat

      final params = <String, String>{
        'origin': fmt(origin),
        'destination': fmt(destination),
        if (waypoints.isNotEmpty) 'waypoints': waypoints.map(fmt).join('|'),
        'priority': 'RECOMMEND',
      };

      final uri = Uri.https(
        'apis-navi.kakaomobility.com',
        '/v1/directions',
        params,
      );
      final res = await http.get(
        uri,
        headers: {'Authorization': 'KakaoAK $_kakaoRestKey'},
      );

      if (res.statusCode != 200) {
        debugPrint('❌ Kakao dir HTTP ${res.statusCode} ${res.body}');
        return false;
      }

      final data = jsonDecode(res.body);
      final routes = (data['routes'] as List?) ?? [];
      if (routes.isEmpty) return false;

      final sections = (routes[0]['sections'] as List?) ?? [];
      final coords = <LatLng>[];
      for (final sec in sections) {
        final roads = (sec['roads'] as List?) ?? [];
        for (final r in roads) {
          final vertexes = (r['vertexes'] as List?)?.cast<num>() ?? [];
          for (int i = 0; i + 1 < vertexes.length; i += 2) {
            final lng = vertexes[i].toDouble();
            final lat = vertexes[i + 1].toDouble();
            coords.add(LatLng(lat, lng));
          }
        }
      }

      if (coords.isEmpty) return false;

      setState(() {
        polylines = {
          Polyline(
            polylineId: const PolylineId('kakao_route'),
            color: Colors.blueAccent,
            width: 3,
            points: coords,
          ),
        };
      });
      return true;
    } catch (e) {
      debugPrint('❌ Kakao dir exception: $e');
      return false;
    }
  }

  // ───────── 현재 위치 + 경유지 → 휴리스틱 → 카카오 경로 ─────────
  Future<void> _drawOptimizedKakaoRoute(LatLng start) async {
    if (_nearestStops.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('표시된 주소가 없습니다. 새로고침 해주세요.')));
      return;
    }

    var stops = _nearestStops
        .where((p) => _haversine(start, p) > 3.0)
        .toList(growable: false);
    final orderedPoints = _optimizeStops(start, stops);

    // _nearestStopsWithLabel과 매칭해 정렬된 _orderedStops 구성
    final orderedStops = <_Stop>[];
    final used = <int>{};
    for (final p in orderedPoints) {
      for (int i = 0; i < _nearestStopsWithLabel.length; i++) {
        if (used.contains(i)) continue;
        final s = _nearestStopsWithLabel[i];
        if ((s.point.latitude - p.latitude).abs() < 1e-8 &&
            (s.point.longitude - p.longitude).abs() < 1e-8) {
          orderedStops.add(s);
          used.add(i);
          break;
        }
      }
    }

    // 방문 순서 인덱스 만들기
    final indexMap = <LatLng, int>{};
    for (int i = 0; i < orderedStops.length; i++) {
      indexMap[orderedStops[i].point] = i + 1;
    }

    if (mounted) {
      setState(() {
        _orderedStops = orderedStops;
        _orderIndex = indexMap;
      });
    }

    final destination = orderedPoints.isNotEmpty ? orderedPoints.last : start;
    final waypoints =
        orderedPoints.length > 1
            ? orderedPoints.sublist(0, orderedPoints.length - 1)
            : <LatLng>[];

    final ok = await _drawKakaoDrivingRoute(
      origin: start,
      destination: destination,
      waypoints: waypoints,
    );

    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('경로를 찾지 못했습니다. 좌표/키 설정을 확인하세요.')),
      );
    }

    await _refreshMarkers(keepStops: false);
  }

  // ───────── 마커 (SVG 핀 + 숫자/라벨) ─────────
  Future<void> _refreshMarkers({bool keepStops = false}) async {
    final Set<Marker> ms = keepStops ? {...markers} : <Marker>{};

    // 시작 마커: 파란 핀에 'S'
    ms.removeWhere((m) => m.markerId.value == 'start');
    if (currentLocation != null) {
      final startIcon = await NumberedMarkerIcon.startFromSvg(
        context: context, // ★ 추가
        svgAssetPath: _pinBlue,
        targetWidth: 35,
        fontScale: 0.6,
        centerYFactor: 0.42,
      );

      ms.add(
        Marker(
          markerId: const MarkerId('start'),
          position: currentLocation!,
          icon: startIcon,
          anchor: const Offset(0.5, 1.0),
          consumeTapEvents: true,
          onTap: () {},
        ),
      );
    }

    if (!keepStops) {
      ms.removeWhere((m) => m.markerId.value.startsWith('stop_'));

      for (int i = 0; i < _nearestStopsWithLabel.length; i++) {
        final s = _nearestStopsWithLabel[i];
        final n = _orderIndex[s.point] ?? (i + 1); // 방문 순서 번호 or fallback

        final icon = await NumberedMarkerIcon.numberFromSvg(
          context: context, // ★ 추가
          number: n,
          svgAssetPath: _pinRed,
          targetWidth: 35,
          fontScale: 0.6,
          centerYFactor: 0.42,
        );

        ms.add(
          Marker(
            markerId: MarkerId('stop_$i'),
            position: s.point,
            icon: icon,
            anchor: const Offset(0.5, 1.0),
            consumeTapEvents: true,
            onTap: () {
              final deliveries = apartmentGroups[s.label] ?? [];
              _showApartmentDialog(s.label, deliveries);
            },
          ),
        );
      }
    }

    if (!mounted) return;
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
                await _refreshMarkers(keepStops: true);
              } catch (e) {
                debugPrint('❌ 위치 이동 실패: $e');
              }
            },
            onDrawRoutePressed: () {
              if (currentLocation != null) {
                _drawOptimizedKakaoRoute(currentLocation!);
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
        label: const Text('경로 새로고침'),
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
