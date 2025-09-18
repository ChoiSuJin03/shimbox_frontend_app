import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';

import 'package:shimbox_app/controllers/location_controller.dart';

import './map_action_header.dart';

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

  final List<LatLng> waypoints = [
    LatLng(37.5083, 126.8665), // 경유지 1
    LatLng(37.5102, 126.8702), // 경유지 2
    LatLng(37.5130, 126.8732), // 경유지 3
    LatLng(37.5180, 126.8825), // 도착지 (맨 마지막)
  ];

  Set<Marker> markers = {};
  Set<Polyline> polylines = {};
  final String kakaoApiKey = '4faee1ecf5810b0685963cbb90ed9d48';

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
      _setMarkers(loc);
      // ✅ 초기 좌표를 LocationController에 반영 (주소 역지오코딩)
      await LocationController.to.setLatLng(loc);

      mapController?.animateCamera(CameraUpdate.newLatLngZoom(loc, 17));
    } catch (e) {
      print('❌ 초기화 실패: $e');
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
        _setMarkers(loc);
      });

      // ✅ 좌표 변경 시마다 LocationController 업데이트 → 홈 주소 실시간 반영
      await LocationController.to.setLatLng(loc);

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

  void _setMarkers(LatLng start) {
    setState(() {
      markers.clear();
      markers.add(
        Marker(
          markerId: const MarkerId('start'),
          position: start,
          infoWindow: const InfoWindow(title: '현재 위치'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        ),
      );

      for (int i = 0; i < waypoints.length; i++) {
        markers.add(
          Marker(
            markerId: MarkerId('waypoint$i'),
            position: waypoints[i],
            infoWindow: InfoWindow(
              title: i == waypoints.length - 1 ? '도착지' : '경유지 ${i + 1}',
            ),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              i == waypoints.length - 1
                  ? BitmapDescriptor.hueGreen
                  : BitmapDescriptor.hueRed,
            ),
          ),
        );
      }
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
    final end = waypoints.last;
    final mids = waypoints.sublist(0, waypoints.length - 1);

    /// ✅ 가까운 순서로 경유지 재정렬 적용
    final best = _greedyRoute(start, mids);

    final origin = '${start.longitude},${start.latitude}';
    final destination = '${end.longitude},${end.latitude}';
    final waypointsStr = best
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
      } else {
        print('❌ 경로 요청 실패: ${response.body}');
      }
    } catch (e) {
      print('❌ 경로 요청 중 예외 발생: $e');
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
          MapActionHeader(
            onCurrentLocationPressed: () async {
              print('📍 위치 버튼 클릭됨');
              try {
                final controller = await _controllerCompleter.future;

                Position? last = await Geolocator.getLastKnownPosition();
                LatLng loc;
                if (last != null) {
                  loc = LatLng(last.latitude, last.longitude);
                } else {
                  loc = await _fetchCurrentLocation();
                }

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
                // ✅ 수동 위치 이동 시에도 공유 컨트롤러 갱신
                await LocationController.to.setLatLng(loc);
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
              }
            },
          ),
        ],
      ),
    );
  }
}
