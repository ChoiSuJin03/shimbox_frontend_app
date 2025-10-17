import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:collection';

class ApartmentBottomSheetGrouped extends StatelessWidget {
  final String aptName; // 예: 산타빌라
  final String? aptAddress; // 예: 경기도 광명시 ...
  final List<Map<String, String>> deliveries; // [{address, detail, dong?}, ...]
  final void Function(Map<String, String> item)? onTapItem;
  final void Function(Map<String, String> item)? onTapNavigate;

  const ApartmentBottomSheetGrouped({
    super.key,
    required this.aptName,
    required this.deliveries,
    this.aptAddress,
    this.onTapItem,
    this.onTapNavigate,
  });

  // ---------- Helpers ----------
  List<int> _extractDongNumbersAll(String s) {
    final set = <int>{};
    for (final m in RegExp(r'(\d+)\s*동').allMatches(s)) {
      final n = int.tryParse(m.group(1)!);
      if (n != null) set.add(n);
    }
    final list = set.toList()..sort();
    return list;
  }

  int? _extractDongNumberFirst(String s) {
    final m = RegExp(r'(\d+)\s*동').firstMatch(s);
    if (m != null) return int.tryParse(m.group(1)!);
    return null;
  }

  List<int> _collectDongNumbersFromDeliveries() {
    final s = <int>{};

    final fromAptName = _extractDongNumberFirst(aptName);
    if (fromAptName != null) s.add(fromAptName);

    for (final d in deliveries) {
      final explicitDong = (d['dong'] ?? '').trim();
      if (explicitDong.isNotEmpty) {
        final n = _extractDongNumberFirst(explicitDong);
        if (n != null) s.add(n);
        continue;
      }
      final addr = (d['address'] ?? '').trim();
      final detail =
          (d['detail'] ?? d['detailAddress'] ?? d['detail_address'] ?? '')
              .trim();
      final merged = '$addr $detail';
      s.addAll(_extractDongNumbersAll(merged));
    }
    final list = s.toList()..sort();
    return list;
  }

  String? _dongSummary() {
    final dongs = _collectDongNumbersFromDeliveries();
    if (dongs.isEmpty) return null;

    bool isContiguous = true;
    for (int i = 1; i < dongs.length; i++) {
      if (dongs[i] != dongs[i - 1] + 1) {
        isContiguous = false;
        break;
      }
    }

    if (isContiguous && dongs.length >= 3) {
      return '${dongs.first}–${dongs.last}동 (총 ${dongs.length}동)';
    } else {
      final listed = dongs.map((e) => '${e}동').join(' · ');
      return '$listed (총 ${dongs.length}동)';
    }
  }

  // ✅ dong 최종 보정: 키 없으면 detail/address/aptName에서 추출
  String _ensureDong(Map<String, String> d, String aptName) {
    String pickDong(String? s) {
      if (s == null) return '';
      final t = s.trim();
      if (t.isEmpty || t.toLowerCase() == 'null') return '';
      final m = RegExp(r'(\d+)\s*동').firstMatch(t);
      if (m != null) return '${m.group(1)}동';
      if (RegExp(r'^\d+$').hasMatch(t)) return '${t}동';
      return '';
    }

    final given = (d['dong'] ?? '').trim();
    if (given.isNotEmpty) return given;

    final addr = (d['address'] ?? '').trim();
    final detail =
        (d['detail'] ?? d['detailAddress'] ?? d['detail_address'] ?? '').trim();
    return pickDong(detail).isNotEmpty
        ? pickDong(detail)
        : (pickDong(addr).isNotEmpty ? pickDong(addr) : pickDong(aptName));
  }

  String _dongKeyForItem(Map<String, String> d) {
    final explicit = _ensureDong(d, aptName);
    if (explicit.isNotEmpty) return explicit;

    final addr = (d['address'] ?? '').trim();
    final detail =
        (d['detail'] ?? d['detailAddress'] ?? d['detail_address'] ?? '').trim();
    final merged = '$addr $detail';
    final n =
        _extractDongNumberFirst(merged) ??
        _extractDongNumberFirst(aptName) ??
        -1;
    return n > 0 ? '${n}동' : '동 미상';
  }

  LinkedHashMap<String, List<Map<String, String>>> _groupByDong() {
    final map = <String, List<Map<String, String>>>{};
    for (final d in deliveries) {
      final key = _dongKeyForItem(d);
      map.putIfAbsent(key, () => []).add(d);
    }

    final keys =
        map.keys.toList()..sort((a, b) {
          int parseDong(String k) =>
              RegExp(r'^(\d+)동$').hasMatch(k)
                  ? int.parse(RegExp(r'^(\d+)동$').firstMatch(k)!.group(1)!)
                  : 1 << 30;
          final da = parseDong(a);
          final db = parseDong(b);
          if (da != db) return da.compareTo(db);
          return a.compareTo(b);
        });

    final ordered = LinkedHashMap<String, List<Map<String, String>>>();
    for (final k in keys) {
      ordered[k] =
          map[k]!..sort((x, y) {
            final dx =
                (x['detail'] ?? x['detailAddress'] ?? x['detail_address'] ?? '')
                    .trim();
            final dy =
                (y['detail'] ?? y['detailAddress'] ?? y['detail_address'] ?? '')
                    .trim();
            return dx.compareTo(dy);
          });
    }
    return ordered;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dongText = _dongSummary();
    final grouped = _groupByDong();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (_, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: Material(
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(100),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SvgPicture.asset(
                        'assets/images/home/marker.svg',
                        width: 22,
                        height: 22,
                        colorFilter: const ColorFilter.mode(
                          Color(0xFF2D5FFF),
                          BlendMode.srcIn,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              aptName,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: Colors.black,
                              ),
                            ),
                            if (dongText != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  dongText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF2D5FFF),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            if (aptAddress != null && aptAddress!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  aptAddress!,
                                  maxLines: 2,
                                  softWrap: true,
                                  overflow: TextOverflow.fade,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.black54,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.black54),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFEDEDED)),

                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: grouped.length,
                    itemBuilder: (context, sectionIndex) {
                      final dongKey = grouped.keys.elementAt(sectionIndex);
                      final items = grouped[dongKey]!;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                            color: const Color(0xFFF8F9FB),
                            child: Row(
                              children: [
                                Text(
                                  dongKey,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '· ${items.length}건',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.black45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFFEDEDED)),

                          ...List.generate(items.length, (index) {
                            final d = items[index];
                            final road = (d['address'] ?? '').trim();

                            // ✅ detail 최종: detail > detailAddress > detail_address
                            final unit =
                                ((d['detail'] ??
                                            d['detailAddress'] ??
                                            d['detail_address'] ??
                                            '')
                                        as String)
                                    .trim();

                            // ✅ dong 최종 보정
                            final dong = _ensureDong(d, aptName);

                            final parts =
                                road
                                    .split(RegExp(r'[\r\n]+'))
                                    .where((s) => s.trim().isNotEmpty)
                                    .toList();

                            final subLine =
                                [
                                  if (dong.isNotEmpty && dong != '동 미상') dong,
                                  if (parts.isNotEmpty) parts.last,
                                ].join(' ').trim();

                            return InkWell(
                              onTap: () => onTapItem?.call(d),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            unit.isEmpty ? '-' : unit,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          if (subLine.isNotEmpty)
                                            Text(
                                              subLine,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: Colors.black54,
                                                    height: 1.2,
                                                  ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    InkWell(
                                      onTap: () => onTapNavigate?.call(d),
                                      child: SvgPicture.asset(
                                        'assets/images/home/marker.svg',
                                        width: 20,
                                        height: 20,
                                        colorFilter: const ColorFilter.mode(
                                          Colors.green,
                                          BlendMode.srcIn,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                          const Divider(height: 8, color: Colors.transparent),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
