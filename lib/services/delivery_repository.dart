/// - 기존 fetchData()의 데이터 파싱/그룹핑/정렬만 담당.

import '../utils/address_utils.dart';
import '../utils/status_utils.dart';
import '../utils/api_service.dart'; // 상대경로: pages가 아니라 services 기준!

class DeliveryRepositoryResult {
  final List<Map<String, dynamic>>
  deliveryAreas; // [{name, base, building, total, units: [...]}, ...]
  final List<List<int>> deliveryStatus; // area별 status 일렬화
  DeliveryRepositoryResult({
    required this.deliveryAreas,
    required this.deliveryStatus,
  });
}

class DeliveryRepository {
  Future<DeliveryRepositoryResult> fetchAreas() async {
    final data = await ApiService.fetchDeliverySummary();

    final List<Map<String, dynamic>> result = [];
    final List<List<int>> statusAllAreas = [];

    for (final area in data) {
      final String base = (area['shippingLocation'] ?? '') as String;
      final List groups = (area['groups'] as List?) ?? [];

      // building → unit → products[]
      final Map<String, Map<String, List<Map<String, dynamic>>>> grouped = {};

      for (final g in groups) {
        final String detail = (g['detailAddress'] ?? '') as String;
        final List products = (g['products'] as List?) ?? [];
        final sp = splitDetail(detail);
        final String building = sp['building'] ?? '';
        final String unit =
            (sp['unit']?.isNotEmpty == true) ? sp['unit']! : detail;
        if (building.isEmpty) continue;

        grouped.putIfAbsent(building, () => {});
        grouped[building]!.putIfAbsent(unit, () => []);

        for (final p in products) {
          grouped[building]![unit]!.add(Map<String, dynamic>.from(p as Map));
        }
      }

      // building 단위 아이템 구성
      grouped.forEach((building, unitMap) {
        final units =
            unitMap.entries
                .map((e) => {'unit': e.key, 'products': e.value})
                .toList()
              ..sort((a, b) {
                final au = a['unit'] as String;
                final bu = b['unit'] as String;
                final an = RegExp(r'\d+').firstMatch(au)?.group(0);
                final bn = RegExp(r'\d+').firstMatch(bu)?.group(0);
                if (an != null && bn != null) {
                  return int.parse(an).compareTo(int.parse(bn));
                }
                return au.compareTo(bu);
              });

        final List<int> statuses = [];
        for (final u in units) {
          final plist =
              ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
          for (final prod in plist) {
            final s = statusToInt((prod['shippingStatus'] ?? '') as String);
            statuses.add(s);
          }
        }

        result.add({
          'name': '$base $building',
          'base': base,
          'building': building,
          'units': units,
          'total': units.fold<int>(
            0,
            (sum, u) => sum + (((u['products'] as List?) ?? []).length),
          ),
        });
        statusAllAreas.add(statuses);
      });
    }

    result.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return DeliveryRepositoryResult(
      deliveryAreas: result,
      deliveryStatus: statusAllAreas,
    );
  }
}
