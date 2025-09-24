// models/map/map_poi.dart
import 'package:google_maps_flutter/google_maps_flutter.dart';

enum POIType { address, complex, building }

class MapPOI {
  final String id; // 주소/단지/동 식별자
  final double lat;
  final double lng;
  final String label; // 마커 타이틀(도로명/단지명/동명)
  final POIType type;
  final String? complexId; // building이면 소속 단지 ID, complex면 자기 자신 ID일 수도
  final int? buildingCount; // complex일 때 동 개수(선택)

  MapPOI({
    required this.id,
    required this.lat,
    required this.lng,
    required this.label,
    required this.type,
    this.complexId,
    this.buildingCount,
  });

  LatLng get latLng => LatLng(lat, lng);

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  factory MapPOI.fromJson(Map<String, dynamic> j) {
    // 서버 필드명이 latitude/longitude/lon로 올 수도 있으니 유연 파싱
    final lat = j['lat'] ?? j['latitude'];
    final lng = j['lng'] ?? j['lon'] ?? j['longitude'];

    final rawType = (j['type'] ?? 'address').toString().toLowerCase();
    final t = switch (rawType) {
      'address' => POIType.address,
      'complex' => POIType.complex,
      'building' => POIType.building,
      _ => POIType.address,
    };

    return MapPOI(
      id: (j['id'] ?? j['poiId'] ?? '').toString(),
      lat: _toDouble(lat),
      lng: _toDouble(lng),
      label: (j['label'] ?? j['name'] ?? '').toString(),
      type: t,
      complexId: j['complexId']?.toString(),
      buildingCount:
          (j['buildingCount'] is String)
              ? int.tryParse(j['buildingCount'])
              : j['buildingCount'],
    );
  }
}
