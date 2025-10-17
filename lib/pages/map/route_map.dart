// lib/pages/map/map_page_full.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_compass/flutter_compass.dart';

import 'widgets/map_action_header.dart';
import 'package:shimbox_app/utils/api_service.dart';
import 'widgets/numbered_marker_icon.dart';
import 'widgets/bottom_sheet.dart';

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

  // 방문 순서
  List<_Stop> _orderedStops = [];
  Map<LatLng, int> _orderIndex = {};

  List<_Stop> _nearestStopsWithLabel = [];
  List<LatLng> get _nearestStops =>
      _nearestStopsWithLabel.map((e) => e.point).toList();

  Set<Marker> markers = {};
  Set<Polyline> polylines = {};

  bool _isUserInteracting = false;
  double? _lastBearing;
  Timer? _bearingUpdateTimer;

  bool _loadingStops = false;

  // 문자열 키 → 같은 키로 모은 목록(보조)
  Map<String, List<Map<String, String>>> apartmentGroups = {};

  // 좌표 반경 검색용 풀목록
  final List<_GeoRow> _geoRows = [];

  static const _kakaoRestKey = 'a4ba47d483e2d8f8681d6c36474ff4fd';
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

  String _normalizeKey(String s) =>
      s
          .replaceAll(RegExp(r'[\r\n]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

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

  Future<void> _initializeMap() async {
    try {
      final loc = await _fetchCurrentLocation();
      if (!mounted) return;
      currentLocation = loc;
      await _refreshMarkers();
      mapController?.animateCamera(CameraUpdate.newLatLngZoom(loc, 17));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('현재 위치 권한을 확인해주세요.')));
      }
    }
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
      setState(() => currentLocation = loc);
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

  // ─────────────────────────────────────────
  // 상세 문자열 안전 추출 + 동/호 파서
  // ─────────────────────────────────────────

  String _safeDetailFromRow(Map row) {
    String pick(Object? v) => (v?.toString() ?? '').trim();
    // 서버가 어떤 키로 내려줘도 잡히도록 후보를 넓게
    const keys = [
      'detail',
      'detailAddress',
      'detail_address',
      'subAddress',
      // 혹시 다른 이름으로 내려오는 케이스들(없으면 무시)
      'dongHo',
      'dong_ho',
      'addrDetail',
      'buildingInfo',
    ];
    for (final k in keys) {
      if (!row.containsKey(k)) continue;
      final v = pick(row[k]);
      if (v.isNotEmpty && v.toLowerCase() != 'null') return v;
    }
    return '';
  }

  String? _pickDongFromText(String? s) {
    if (s == null) return null;
    final t = s.trim();
    if (t.isEmpty || t.toLowerCase() == 'null') return null;
    final m = RegExp(r'(\d+)\s*동').firstMatch(t);
    if (m != null) return '${m.group(1)}동';
    if (RegExp(r'^\d+$').hasMatch(t)) return '${t}동';
    return null;
  }

  String? _pickHoFromText(String? s) {
    if (s == null) return null;
    final t = s.trim();
    if (t.isEmpty || t.toLowerCase() == 'null') return null;
    final m = RegExp(r'(\d+)\s*호').firstMatch(t);
    if (m != null) return '${m.group(1)}호';
    return null;
  }

  // 행에서 dong 추출 (명시 필드 → detail → base)
  String? _pickDongFromRow(Map row, String base, String detail) {
    final keys = ['dong', 'buildingDong', 'building', 'aptDong', '동'];
    for (final k in keys) {
      final raw = row[k]?.toString().trim();
      if (raw != null && raw.isNotEmpty && raw.toLowerCase() != 'null') {
        if (RegExp(r'^\d+$').hasMatch(raw)) return '${raw}동';
        final m = RegExp(r'(\d+)\s*동').firstMatch(raw);
        if (m != null) return '${m.group(1)}동';
        return raw;
      }
    }
    return _pickDongFromText(detail) ?? _pickDongFromText(base);
  }

  Future<void> _loadNearest9StopsFromDB() async {
    if (currentLocation == null)
      currentLocation = await _fetchCurrentLocation();
    setState(() => _loadingStops = true);

    try {
      final data = await ApiService.fetchDeliverySummary();

      final List<_StopWithDistance> bestList = [];
      apartmentGroups.clear();
      _geoRows.clear();
      polylines = {};

      for (final row in data) {
        if (row is! Map) continue;

        // base address
        final rawBase = _firstNonEmpty(row, const [
          'shippingLocation',
          'shipping_location',
          'address',
          'baseAddress',
          'shippingAddress',
        ]);
        final base = _normalizeKey(rawBase);

        // 상세(동/호가 함께 들어있는 문자열일 수도 있음)
        final detail = _safeDetailFromRow(row);

        if (base.isEmpty) continue;

        // 좌표
        LatLng? pos = await _geocodeAddress(base);
        pos ??= await _geocodeByKeyword(base);
        if (pos == null) continue;

        // 근접도
        final d = Geolocator.distanceBetween(
          currentLocation!.latitude,
          currentLocation!.longitude,
          pos.latitude,
          pos.longitude,
        );
        bestList.add(_StopWithDistance(_Stop(base, pos), d));

        // 동/호 파싱
        final dong = _pickDongFromRow(row, base, detail);
        final ho = _pickHoFromText(detail);

        // 보조 그룹(문자열 키)
        apartmentGroups.putIfAbsent(base, () => []);
        apartmentGroups[base]!.add({
          'address': base,
          'detail': detail, // 원문 상세(표시용)
          if (dong != null) 'dong': dong,
          if (ho != null) 'ho': ho,
        });

        // 좌표 풀목록
        _geoRows.add(
          _GeoRow(
            base: base,
            pos: pos,
            payload: {
              'address': base,
              'detail': detail,
              if (dong != null) 'dong': dong,
              if (ho != null) 'ho': ho,
            },
          ),
        );
      }

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

      if (_nearestStops.isNotEmpty && mapController != null) {
        final all = [currentLocation!, ..._nearestStops];
        final bounds = _boundsFromLatLngList(all);
        await mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 60),
        );
      }

      if (currentLocation != null && _nearestStops.isNotEmpty) {
        await _drawOptimizedKakaoRoute(currentLocation!);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('주소 로드/좌표화 중 오류 발생')));
      }
      setState(() => _loadingStops = false);
    }
  }

  // "null" 문자열도 무시
  String _firstNonEmpty(Map row, List<String> keys) {
    for (final k in keys) {
      if (!row.containsKey(k)) continue;
      final v = (row[k]?.toString() ?? '').trim();
      if (v.isNotEmpty && v.toLowerCase() != 'null') return v;
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
        final docs = (jsonDecode(res.body)['documents'] as List?) ?? [];
        if (docs.isNotEmpty) {
          final x = double.tryParse(docs[0]['x'].toString());
          final y = double.tryParse(docs[0]['y'].toString());
          if (x != null && y != null) return LatLng(y, x);
        }
      }
    } catch (_) {}
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
        final docs = (jsonDecode(res.body)['documents'] as List?) ?? [];
        if (docs.isNotEmpty) {
          final x = double.tryParse(docs[0]['x'].toString());
          final y = double.tryParse(docs[0]['y'].toString());
          if (x != null && y != null) return LatLng(y, x);
        }
      }
    } catch (_) {}
    return null;
  }

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
      for (var i = 0; i < r.length - 1; i++) {
        sum += _haversine(r[i], r[i + 1]);
      }
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

  Future<bool> _drawKakaoDrivingRoute({
    required LatLng origin,
    required LatLng destination,
    required List<LatLng> waypoints,
  }) async {
    try {
      String fmt(LatLng p) => '${p.longitude},${p.latitude}';
      final uri = Uri.https('apis-navi.kakaomobility.com', '/v1/directions', {
        'origin': fmt(origin),
        'destination': fmt(destination),
        if (waypoints.isNotEmpty) 'waypoints': waypoints.map(fmt).join('|'),
        'priority': 'RECOMMEND',
      });
      final res = await http.get(
        uri,
        headers: {'Authorization': 'KakaoAK $_kakaoRestKey'},
      );
      if (res.statusCode != 200) return false;

      final data = jsonDecode(res.body);
      final routes = (data['routes'] as List?) ?? [];
      if (routes.isEmpty) return false;

      final sections = (routes[0]['sections'] as List?) ?? [];
      final coords = <LatLng>[];
      for (final sec in sections) {
        final roads = (sec['roads'] as List?) ?? [];
        for (final r in roads) {
          final v = (r['vertexes'] as List?)?.cast<num>() ?? [];
          for (int i = 0; i + 1 < v.length; i += 2) {
            coords.add(LatLng(v[i + 1].toDouble(), v[i].toDouble()));
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
    } catch (_) {
      return false;
    }
  }

  Future<void> _drawOptimizedKakaoRoute(LatLng start) async {
    if (_nearestStops.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('표시된 주소가 없습니다. 새로고침 해주세요.')));
      return;
    }

    final stops = _nearestStops
        .where((p) => _haversine(start, p) > 3.0)
        .toList(growable: false);
    final orderedPoints = _optimizeStops(start, stops);

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

  Future<void> _refreshMarkers({bool keepStops = false}) async {
    final Set<Marker> ms = keepStops ? {...markers} : <Marker>{};

    ms.removeWhere((m) => m.markerId.value == 'start');
    if (currentLocation != null) {
      final startIcon = await NumberedMarkerIcon.startFromSvg(
        context: context,
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
        final n = _orderIndex[s.point] ?? (i + 1);

        final icon = await NumberedMarkerIcon.numberFromSvg(
          context: context,
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
            onTap: () => _showApartmentDialog(s.label, s.point),
          ),
        );
      }
    }

    if (!mounted) return;
    setState(() => markers = ms);
  }

  // 좌표 반경으로 모아 모달에 전달
  void _showApartmentDialog(String aptName, LatLng tappedPos) {
    const radiusMeter = 120.0;
    final near = <Map<String, String>>[];

    for (final r in _geoRows) {
      final dist = Geolocator.distanceBetween(
        tappedPos.latitude,
        tappedPos.longitude,
        r.pos.latitude,
        r.pos.longitude,
      );
      if (dist <= radiusMeter) {
        final m = Map<String, String>.from(r.payload);

        // 상세가 비어 있으면 보강 시도(다른 키까지 검사)
        if ((m['detail'] ?? '').trim().isEmpty) {
          final d2 = _safeDetailFromRow(r.payload);
          if (d2.isNotEmpty) m['detail'] = d2;
        }

        // 동/호 보강
        if ((m['dong'] ?? '').trim().isEmpty) {
          m['dong'] =
              _pickDongFromText(m['detail']) ??
              _pickDongFromText(m['address']) ??
              _pickDongFromText(aptName) ??
              '';
        }
        if ((m['ho'] ?? '').trim().isEmpty) {
          m['ho'] = _pickHoFromText(m['detail']) ?? '';
        }

        near.add(m);
      }
    }

    // 같은 문자열 키 그룹도 합치기
    final key = _normalizeKey(aptName);
    final direct = apartmentGroups[key] ?? const <Map<String, String>>[];
    for (final d in direct) {
      if (!near.contains(d)) near.add(d);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder:
          (ctx) => ApartmentBottomSheetGrouped(
            aptName: aptName,
            aptAddress: aptName,
            deliveries: near,
            onTapItem: (item) => debugPrint('🖱️ item: $item'),
            onTapNavigate: (item) => debugPrint('🧭 navigate: $item'),
          ),
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
              if (currentLocation != null)
                _drawOptimizedKakaoRoute(currentLocation!);
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

// 지오 행(모달 반경 검색용)
class _GeoRow {
  final String base;
  final LatLng pos;
  final Map<String, String> payload;
  _GeoRow({required this.base, required this.pos, required this.payload});
}
