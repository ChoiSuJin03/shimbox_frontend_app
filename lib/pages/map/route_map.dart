import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';

import 'package:shimbox_app/controllers/location_controller.dart';
import 'package:shimbox_app/utils/api_service.dart';
import 'package:shimbox_app/models/map/map_poi.dart';

import 'map_action_header.dart';

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

  // 서버에서 받아오는 후보 목록
  List<MapPOI> nearestCandidates = []; // address/complex 섞임(Top-9)
  List<MapPOI> buildingsDrilldown = []; // complex 클릭 후 동 목록
  bool inBuildingMode = false;

  Set<Marker> markers = {};
  Set<Polyline> polylines = {};

  // ✅ 카카오 API 키 입력
  final String kakaoApiKey = 'KAKAO_REST_API_KEY';

  bool _isUserInteracting = false;
  Timer? _interactionTimer;
  double? _lastBearing;
  Timer? _bearingUpdateTimer;

  @override
  void initState() {
    super.initState();
    _initializeMap().then((_) => _startTracking());
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();
    _interactionTimer?.cancel();
    _bearingUpdateTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializeMap() async {
    try {
      final loc = await _fetchCurrentLocation();
      if (!mounted) return;
      currentLocation = loc;

      await LocationController.to.setLatLng(loc);

      await _loadNearestFromServer(loc);
      _renderMarkers();

      mapController?.animateCamera(CameraUpdate.newLatLngZoom(loc, 17));
    } catch (e) {
      debugPrint('❌ 초기화 실패: $e');
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

  Future<void> _startTracking() async {
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((position) async {
      final loc = LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      currentLocation = loc;

      await LocationController.to.setLatLng(loc);
      await _loadNearestFromServer(loc);
      _renderMarkers();

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

  // ---------- 서버 호출 ----------
  Future<void> _loadNearestFromServer(LatLng loc) async {
    try {
      final pois = await ApiService.fetchNearestPOIs(
        lat: loc.latitude,
        lng: loc.longitude,
        limit: 9,
      );
      debugPrint('🛰 nearest fetched: ${pois.length}개');
      setState(() {
        nearestCandidates = pois;
        inBuildingMode = false;
        buildingsDrilldown = [];
      });
    } catch (e) {
      debugPrint('❌ nearest fetch error: $e');
      // ApiService가 폴백을 반환하므로 여기선 추가 처리 불필요
      final fb = await ApiService.fetchNearestPOIs(
        lat: loc.latitude,
        lng: loc.longitude,
        limit: 9,
      );
      setState(() {
        nearestCandidates = fb;
        inBuildingMode = false;
        buildingsDrilldown = [];
      });
    }
  }

  // ---------- 마커 렌더 ----------
  void _renderMarkers() {
    final Set<Marker> next = {};

    if (currentLocation != null) {
      next.add(
        Marker(
          markerId: const MarkerId('me'),
          position: currentLocation!,
          infoWindow: const InfoWindow(title: '현재 위치'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        ),
      );
    }

    final list = inBuildingMode ? buildingsDrilldown : nearestCandidates;
    debugPrint(
      '🧭 marker render: ${list.length}개, mode=${inBuildingMode ? 'building' : 'nearest'}',
    );

    for (final p in list) {
      final hue = switch (p.type) {
        POIType.address => BitmapDescriptor.hueRed,
        POIType.complex => BitmapDescriptor.hueAzure,
        POIType.building => BitmapDescriptor.hueOrange,
      };

      final snippet =
          (p.type == POIType.complex && p.buildingCount != null)
              ? '동 ${p.buildingCount}개'
              : p.type.name;

      next.add(
        Marker(
          markerId: MarkerId('poi_${p.id}'),
          position: p.latLng,
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          infoWindow: InfoWindow(
            title: p.label.isEmpty ? '(이름없음)' : p.label,
            snippet: snippet,
          ),
          onTap: () async {
            if (p.type == POIType.complex) {
              try {
                final blds = await ApiService.fetchBuildingsOfComplex(p.id);
                debugPrint('🏢 complex ${p.id} buildings: ${blds.length}');
                setState(() {
                  inBuildingMode = true;
                  buildingsDrilldown = blds;
                });
                _renderMarkers();
              } catch (e) {
                debugPrint('❌ buildings fetch error: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('동 목록을 불러오지 못했습니다')),
                  );
                }
              }
            }
          },
        ),
      );
    }

    setState(() => markers = next);

    // 첫 아이템 보이게 카메라 스냅
    if (list.isNotEmpty && mapController != null) {
      mapController!.animateCamera(CameraUpdate.newLatLng(list.first.latLng));
    }
  }

  // ---------- 경로 최적화 ----------
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

  List<LatLng> _twoOpt(List<LatLng> route) {
    bool improved = true;
    List<LatLng> best = List.from(route);

    double dist(List<LatLng> r) {
      double sum = 0;
      for (int i = 0; i < r.length - 1; i++) {
        sum += Geolocator.distanceBetween(
          r[i].latitude,
          r[i].longitude,
          r[i + 1].latitude,
          r[i + 1].longitude,
        );
      }
      return sum;
    }

    double bestDist = dist(best);

    while (improved) {
      improved = false;
      for (int i = 1; i < best.length - 2; i++) {
        for (int k = i + 1; k < best.length - 1; k++) {
          final newRoute = [
            ...best.sublist(0, i),
            ...best.sublist(i, k + 1).reversed,
            ...best.sublist(k + 1),
          ];
          final d = dist(newRoute);
          if (d + 1e-6 < bestDist) {
            best = newRoute;
            bestDist = d;
            improved = true;
          }
        }
      }
    }
    return best;
  }

  Future<void> _drawOptimizedFrom(LatLng start) async {
    // 현재 모드에서 사용할 최대 9개 포인트 수집
    final base = inBuildingMode ? buildingsDrilldown : nearestCandidates;
    if (base.isEmpty) return;

    final points = base.take(9).map((e) => e.latLng).toList();

    // Greedy + 2-opt
    final greedy = _greedyRoute(start, points);
    final improved = _twoOpt([start, ...greedy]);
    final ordered = improved.sublist(1); // start 제외
    final end = ordered.last;
    final mids = ordered.sublist(0, ordered.length - 1);

    await _drawRouteUsingKakao(start: start, end: end, mids: mids);
  }

  Future<void> _drawRouteUsingKakao({
    required LatLng start,
    required LatLng end,
    required List<LatLng> mids,
  }) async {
    final origin = '${start.longitude},${start.latitude}';
    final destination = '${end.longitude},${end.latitude}';
    final waypointsStr = mids
        .map((e) => '${e.longitude},${e.latitude}')
        .join('|');

    final url =
        'https://apis-navi.kakaomobility.com/v1/directions'
        '?origin=$origin&destination=$destination'
        '${mids.isNotEmpty ? '&waypoints=$waypointsStr' : ''}';

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
      } else {
        debugPrint('❌ 경로 요청 실패: ${response.body}');
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('경로 요청 실패')));
        }
      }
    } catch (e) {
      debugPrint('❌ 경로 요청 예외: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
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
              _controllerCompleter.complete(controller);
              if (currentLocation != null) {
                mapController!.animateCamera(
                  CameraUpdate.newLatLngZoom(currentLocation!, 17),
                );
              }
            },
            onCameraMoveStarted: () {
              _isUserInteracting = true;
              _interactionTimer?.cancel();
            },
          ),

          // 상단 헤더(현재위치 / 최적경로 / 뒤로)
          MapActionHeader(
            onCurrentLocationPressed: () async {
              try {
                final controller = await _controllerCompleter.future;
                Position? last = await Geolocator.getLastKnownPosition();
                LatLng loc =
                    (last != null)
                        ? LatLng(last.latitude, last.longitude)
                        : await _fetchCurrentLocation();

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

                currentLocation = loc;
                await LocationController.to.setLatLng(loc);
                await _loadNearestFromServer(loc);
                _renderMarkers();
              } catch (e) {
                debugPrint('❌ 위치 이동 실패: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('위치를 가져올 수 없습니다. 권한을 확인하세요.')),
                  );
                }
              }
            },
            onDrawRoutePressed: () {
              if (currentLocation != null) {
                _drawOptimizedFrom(currentLocation!);
              }
            },
            onBackPressed:
                inBuildingMode
                    ? () {
                      setState(() {
                        inBuildingMode = false;
                        buildingsDrilldown = [];
                      });
                      _renderMarkers();
                    }
                    : null,
          ),
        ],
      ),
    );
  }
}
