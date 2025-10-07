import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimbox_app/controllers/bottom_nav_controller.dart';
import 'package:shimbox_app/utils/navigation_helper.dart';
import 'package:shimbox_app/pages/delivery/photo_capture_modal.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shimbox_app/utils/firebase_uploader.dart';
import '../../utils/api_service.dart';
import 'package:shimbox_app/models/test_user_data.dart' as localUser;

import 'package:shimbox_app/controllers/alarm_controller.dart';
import 'package:shimbox_app/models/alarm/alarm_item.dart';

// 리포/유틸
import 'package:shimbox_app/services/delivery_repository.dart';
import 'package:shimbox_app/utils/address_utils.dart';

// 현재 위치 좌표
import 'package:geolocator/geolocator.dart';

class DeliveryDetailPage extends StatefulWidget {
  final Map<String, dynamic> area;
  const DeliveryDetailPage({super.key, required this.area});

  @override
  State<DeliveryDetailPage> createState() => _DeliveryDetailPageState();
}

class _DeliveryDetailPageState extends State<DeliveryDetailPage> {
  // 펼침 상태를 인덱스 대신 "도로키"로 관리(정렬 변동에도 안전)
  String? expandedRoadKey;

  // 서버 원본 (UI에서 직접 사용 X)
  List<List<int>> deliveryStatus = [];
  List<Map<String, dynamic>> deliveryAreas = [];

  // ✅ 핵심: productId -> status(0:대기, 1:시작, 2:완료)
  final Map<int, int> _statusByPid = {};

  bool isLoading = true;

  final AlarmController alarmController = Get.find<AlarmController>();
  final _repo = DeliveryRepository();

  /// 도로명별 현재 선택된 동 (버튼 선택 상태)
  /// ⚠️ road 이름만 쓰면 충돌하므로 "road#index" 키로 보관
  final Map<String, String?> _selectedDongByRoadKey = {};

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, () async {
      final prefs = await SharedPreferences.getInstance();
      final savedToken = prefs.getString('token');
      localUser.UserData.token = savedToken;
      await _ensureLocationPermission();
      await fetchData();
    });
  }

  // ---------- 데이터 로드 ----------
  Future<void> fetchData() async {
    try {
      final res = await _repo.fetchAreas();
      if (!mounted) return;

      setState(() {
        deliveryAreas = res.deliveryAreas;
        deliveryStatus = res.deliveryStatus;
        isLoading = false;
      });

      // ✅ pid -> status 매핑
      _statusByPid.clear();
      for (int a = 0; a < deliveryAreas.length; a++) {
        final units = (deliveryAreas[a]['units'] as List?) ?? [];
        final areaStatuses =
            (a < deliveryStatus.length) ? deliveryStatus[a] : const <int>[];
        int flat = 0;
        for (final u in units) {
          final prods =
              ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
          for (final p in prods) {
            final pid = int.tryParse(p['productId'].toString()) ?? -1;
            if (pid > 0) {
              final st = (flat < areaStatuses.length) ? areaStatuses[flat] : 0;
              _statusByPid[pid] = st;
            }
            flat++;
          }
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

  /// 선택/펼침 상태를 보존한 채로 서버 재조회
  Future<void> _refreshPreserveState() async {
    final prevExpandedKey = expandedRoadKey;
    final prevSelected = Map<String, String?>.from(_selectedDongByRoadKey);
    await fetchData();
    if (!mounted) return;
    setState(() {
      expandedRoadKey = prevExpandedKey;
      _selectedDongByRoadKey
        ..clear()
        ..addAll(prevSelected);
    });
  }

  // ---------- 주소/텍스트 헬퍼 ----------
  String extractRoadName(String? raw) {
    if (raw == null) return '';
    final s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return '';
    final parts = s.split(' ');
    if (parts.length < 3) return s;
    final candidates = parts.sublist(2);
    final suffix = ['로', '길', '대로', '번길'];
    for (final token in candidates) {
      if (suffix.any((suf) => token.endsWith(suf))) return token;
    }
    return candidates.isNotEmpty ? candidates.first : s;
  }

  String extractDong(dynamic item, [dynamic unitOrProd]) {
    String? dong =
        (item is Map
                ? (item['building'] ?? item['dong'] ?? item['buildingDong'])
                : null)
            ?.toString();
    if ((dong == null || dong.isEmpty) && unitOrProd is Map) {
      dong = (unitOrProd['dong'] ?? unitOrProd['buildingDong'])?.toString();
    }
    return (dong == null || dong.isEmpty) ? '미지정동' : dong;
  }

  String? _makeAddressShort(String? full) {
    if (full == null) return null;
    final t = full.trim();
    if (t.isEmpty) return null;
    // 예: "서울시 성북구 정릉로 402" -> "성북구 정릉로"
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length >= 3) {
      return '${parts[1]} ${parts[2]}';
    }
    return t;
  }

  String? _extractRegionFromProd(Map<String, dynamic> prod) {
    final r =
        (prod['dong'] ?? prod['buildingDong'] ?? prod['region'])?.toString();
    if (r == null) return null;
    final t = r.trim();
    if (t.isEmpty || t.toLowerCase() == 'null') return null;
    return t;
  }

  /// deliveryAreas -> "도로명 → 동" 그룹
  List<Map<String, dynamic>> groupByRoadThenDong() {
    final Map<String, Map<String, dynamic>> roadMap = {};

    for (int i = 0; i < deliveryAreas.length; i++) {
      final item = deliveryAreas[i];
      final base = (item['base'] ?? item['name'] ?? '') as String;
      final road = extractRoadName(base);

      final roadSlot = roadMap.putIfAbsent(road, () {
        return {
          'road': road,
          'totals': {'total': 0, 'done': 0, 'inProg': 0},
          'dongs': <String, Map<String, dynamic>>{},
        };
      });

      final List<int> areaStatuses =
          (i < deliveryStatus.length) ? deliveryStatus[i] : const <int>[];
      final int total = (item['total'] as int? ?? 0);
      final int done = areaStatuses.where((s) => s == 2).length;
      final int inProg = areaStatuses.where((s) => s == 1).length;

      (roadSlot['totals'] as Map)['total'] =
          ((roadSlot['totals'] as Map)['total'] as int) + total;
      (roadSlot['totals'] as Map)['done'] =
          ((roadSlot['totals'] as Map)['done'] as int) + done;
      (roadSlot['totals'] as Map)['inProg'] =
          ((roadSlot['totals'] as Map)['inProg'] as int) + inProg;

      // 동 추출
      final units = (item['units'] as List?) ?? [];
      String dongAtItem = extractDong(item);
      if (dongAtItem == '미지정동' && units.isNotEmpty) {
        final u0 = units.first as Map<String, dynamic>;
        final prods =
            ((u0['products'] as List?) ?? []).cast<Map<String, dynamic>>();
        if (prods.isNotEmpty) dongAtItem = extractDong(item, prods.first);
      }

      final dongsMap = roadSlot['dongs'] as Map<String, Map<String, dynamic>>;
      final dongSlot = dongsMap.putIfAbsent(dongAtItem, () {
        return {
          'dong': dongAtItem,
          'indices': <int>[],
          'items': <Map<String, dynamic>>[],
        };
      });
      (dongSlot['indices'] as List<int>).add(i);
      (dongSlot['items'] as List<Map<String, dynamic>>).add(item);
    }

    final roadList =
        roadMap.values.map((r) {
            final dongs =
                (r['dongs'] as Map<String, Map<String, dynamic>>).values
                    .toList()
                  ..sort(
                    (a, b) =>
                        (a['dong'] as String).compareTo(b['dong'] as String),
                  );
            return {'road': r['road'], 'totals': r['totals'], 'dongs': dongs};
          }).toList()
          ..sort(
            (a, b) => (a['road'] as String).compareTo(b['road'] as String),
          );

    return roadList;
  }

  // ---------- status 접근/갱신 ----------
  int _getStatusByPid(int productId) => _statusByPid[productId] ?? 0;
  void _setStatusByPidLocal(int productId, int v) {
    _statusByPid[productId] = v;
  }

  int _safeStatusByPid(int _, int productId) => _getStatusByPid(productId);
  void _setStatusByPid(int _, int productId, int v) =>
      _setStatusByPidLocal(productId, v);

  String? _firstPhone(List<Map<String, dynamic>> prods) {
    for (final p in prods) {
      final v = (p['recipientPhone'] ?? '').toString().trim();
      if (v.isNotEmpty && v.toLowerCase() != 'null') return v;
    }
    return null;
  }

  Map<String, String>? _findActiveDeliveryInfo() {
    for (int a = 0; a < deliveryAreas.length; a++) {
      final units = (deliveryAreas[a]['units'] as List?) ?? [];
      for (final u in units) {
        final prods =
            ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
        for (final prod in prods) {
          final pid = int.tryParse(prod['productId'].toString()) ?? -1;
          if (pid > 0 && _safeStatusByPid(a, pid) == 1) {
            final addr = '${prod['address']} ${prod['detailAddress']}';
            final name = '${prod['recipientName']}';
            return {'address': addr, 'name': name};
          }
        }
      }
    }
    return null;
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    const colorDoneBg = Color(0xFFF4F4F4);
    const colorDoneFg = Color(0xFF4FC99D);
    const colorProgBg = Color(0xFF4FC99D);
    const colorProgFg = Colors.white;
    const colorIdleBg = Color(0xFFF4F4F4);
    const colorIdleFg = Colors.black;

    final roadGroups = groupByRoadThenDong();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.area['name']} 배달 건',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.only(left: 37),
          child: Center(
            child: GestureDetector(
              onTap: () => Get.find<BottomNavController>().changeBottomNav(0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: SvgPicture.asset(
                  'assets/images/home/back.svg',
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
      ),
      body:
          isLoading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                onRefresh: fetchData,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 36,
                    vertical: 16,
                  ),
                  child: ListView.builder(
                    itemCount: roadGroups.length,
                    itemBuilder: (context, ri) {
                      final rg = roadGroups[ri];
                      final roadName = (rg['road'] as String?) ?? '';
                      final totals = (rg['totals'] as Map);
                      final int total = (totals['total'] as int?) ?? 0;
                      final int done = (totals['done'] as int?) ?? 0;
                      final int inProg = (totals['inProg'] as int?) ?? 0;
                      final int progressed = done + inProg;

                      final dongs =
                          (rg['dongs'] as List).cast<Map<String, dynamic>>();

                      // 🔑 roadKey(이름 충돌/정렬 변화에 안전)
                      final roadKey =
                          'road:${roadName.isEmpty ? '기타' : roadName}#$ri';

                      // 헤더(도로명)
                      Widget roadHeader() => GestureDetector(
                        onTap:
                            () => setState(() {
                              expandedRoadKey =
                                  (expandedRoadKey == roadKey) ? null : roadKey;
                            }),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color:
                                      progressed == 0
                                          ? const Color(0xFFF4F4F4)
                                          : const Color(0xFF61D5AB),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Center(
                                  child: SvgPicture.asset(
                                    'assets/images/home/marker.svg',
                                    width: 24,
                                    height: 24,
                                    color:
                                        progressed == 0
                                            ? const Color(0xFF61D5AB)
                                            : Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      roadName.isEmpty ? '기타' : roadName,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                        color:
                                            (progressed == total &&
                                                    total > 0 &&
                                                    inProg == 0)
                                                ? const Color(0xFF555555)
                                                : Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      (progressed == total &&
                                              total > 0 &&
                                              inProg == 0)
                                          ? '$total / $total건 완료'
                                          : '$progressed / $total건 진행 중',
                                      style: TextStyle(
                                        color:
                                            (progressed == total &&
                                                    total > 0 &&
                                                    inProg == 0)
                                                ? const Color(0xFF888888)
                                                : const Color(0xFF2D5FFF),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                expandedRoadKey == roadKey
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                              ),
                            ],
                          ),
                        ),
                      );

                      final opened = expandedRoadKey == roadKey;

                      // 현재 선택된 동 (버튼 토글용) — roadKey 별도 보관
                      final dongNames =
                          dongs
                              .map((d) => (d['dong'] as String?) ?? '미지정동')
                              .toList();
                      _selectedDongByRoadKey.putIfAbsent(
                        roadKey,
                        () => dongNames.isNotEmpty ? dongNames.first : null,
                      );
                      final selectedDongName = _selectedDongByRoadKey[roadKey];

                      // 🔑 road 단위 subtree에 Key 부여
                      return KeyedSubtree(
                        key: ValueKey(roadKey),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            roadHeader(),
                            if (opened) ...[
                              // 동 버튼(칩)들
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 8,
                                  bottom: 10,
                                ),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final d in dongs) ...[
                                      Builder(
                                        builder: (_) {
                                          final name =
                                              (d['dong'] as String?) ?? '미지정동';
                                          final areaIdxs =
                                              ((d['indices'] as List?) ?? [])
                                                  .cast<int>();

                                          // ✅ 집계는 로컬 상태(_statusByPid) 기준
                                          final prog = _calcDongProgressWithPid(
                                            areaIdxs,
                                          );
                                          final t = (prog['total'] ?? 0);
                                          final dn = (prog['done'] ?? 0);
                                          final ip = (prog['inProg'] ?? 0);

                                          final bool isDone =
                                              (t > 0 && dn == t);
                                          final bool isIdle =
                                              (dn == 0 && ip == 0);
                                          final bool isInProg =
                                              !isDone && !isIdle;

                                          final bg =
                                              isDone
                                                  ? colorDoneBg
                                                  : (isInProg
                                                      ? colorProgBg
                                                      : colorIdleBg);
                                          final fg =
                                              isDone
                                                  ? colorDoneFg
                                                  : (isInProg
                                                      ? colorProgFg
                                                      : colorIdleFg);

                                          final bool isSelected =
                                              (selectedDongName == name);

                                          return GestureDetector(
                                            onTap: () {
                                              setState(() {
                                                _selectedDongByRoadKey[roadKey] =
                                                    name;
                                              });
                                            },
                                            child: AnimatedContainer(
                                              duration: const Duration(
                                                milliseconds: 150,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 11,
                                                    vertical: 5,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: bg,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                border: Border.all(
                                                  color:
                                                      isSelected
                                                          ? const Color(
                                                            0xFF2D5FFF,
                                                          )
                                                          : Colors.transparent,
                                                  width: isSelected ? 1.2 : 0,
                                                ),
                                              ),
                                              child: Text(
                                                name,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                  color: fg,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                              ),

                              // 선택된 동의 주소 목록
                              if (selectedDongName != null) ...[
                                Builder(
                                  builder: (_) {
                                    final Map<String, dynamic>?
                                    selectedDongBlock = dongs.firstWhere(
                                      (d) =>
                                          ((d['dong'] as String?) ?? '미지정동') ==
                                          selectedDongName,
                                      orElse: () => <String, dynamic>{},
                                    );
                                    if (selectedDongBlock == null ||
                                        (selectedDongBlock['items'] as List?) ==
                                            null ||
                                        (selectedDongBlock['items'] as List)
                                            .isEmpty) {
                                      return const Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        child: Text(
                                          '해당 동에 표시할 항목이 없습니다.',
                                          style: TextStyle(
                                            color: Colors.grey,
                                            fontSize: 12,
                                          ),
                                        ),
                                      );
                                    }

                                    final items =
                                        ((selectedDongBlock['items'] as List))
                                            .cast<Map<String, dynamic>>();
                                    final indices =
                                        ((selectedDongBlock['indices'] as List))
                                            .cast<int>();

                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        for (
                                          int k = 0;
                                          k < items.length;
                                          k++
                                        ) ...[
                                          _buildGroupedDropdownContent(
                                            indices[k],
                                            items[k],
                                          ),
                                          const SizedBox(height: 8),
                                          if (k < items.length - 1)
                                            Divider(
                                              color: Colors.grey[300],
                                              height: 1,
                                            ),
                                          const SizedBox(height: 8),
                                        ],
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ],
                            const SizedBox(height: 12),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
    );
  }

  // ---------- 동 상태 계산(로컬 pid 기준으로 일관 집계) ----------
  Map<String, int> _calcDongProgressWithPid(List<int> areaIndexes) {
    int total = 0;
    int done = 0;
    int inProg = 0;

    for (final aIdx in areaIndexes) {
      if (aIdx < 0 || aIdx >= deliveryAreas.length) continue;

      final units = (deliveryAreas[aIdx]['units'] as List?) ?? [];
      for (final u in units) {
        final prods =
            ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
        for (final p in prods) {
          final pid = int.tryParse(p['productId'].toString()) ?? -1;
          if (pid <= 0) continue;
          total += 1;
          final st = _getStatusByPid(pid);
          if (st == 2) {
            done += 1;
          } else if (st == 1) {
            inProg += 1;
          }
        }
      }
    }
    return {'total': total, 'done': done, 'inProg': inProg};
  }

  /// 호(동/호) 섹션 + 버튼 1개(묶음 처리)
  Widget _buildGroupedDropdownContent(
    int areaIndex,
    Map<String, dynamic> item,
  ) {
    final base = (item['base'] ?? '') as String;
    final units = (item['units'] as List?) ?? [];
    int cursor = 0;

    final split = splitAddressForTwoLines(base);
    final baseLine1 = split['line1'] ?? base;
    final baseLine2 = split['line2'] ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(units.length, (ui) {
        final u = units[ui] as Map<String, dynamic>;
        final unitLabel = (u['unit'] ?? '') as String;
        final prods =
            ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
        final count = prods.length;

        final start = cursor;
        final myIndices = List.generate(count, (k) => start + k);
        cursor += count;

        // ✅ 동 이름 추출 (item 기준, 없으면 첫 상품에서 보정)
        String dong = extractDong(item);
        if ((dong.isEmpty || dong == '미지정동') && prods.isNotEmpty) {
          dong = extractDong(item, prods.first);
        }

        // productId 목록
        final prodIds =
            prods
                .map((p) => int.tryParse(p['productId'].toString()) ?? -1)
                .where((pid) => pid > 0)
                .toList();

        // 상태 계산(혼합=진행중) — 로컬 pid 기준
        final statuses =
            prodIds.map((pid) => _safeStatusByPid(areaIndex, pid)).toList();
        final int total = statuses.length;
        final int done = statuses.where((s) => s == 2).length;
        final int started = statuses.where((s) => s == 1).length;
        final int agg =
            (total > 0 && done == total)
                ? 2
                : ((done == 0 && started == 0) ? 0 : 1);

        final fullAddrLine1 = baseLine1;

        // ✅ 동(dong)을 주소 라인2에 포함
        final fullAddrLine2 = [
          baseLine2,
          (dong != '미지정동') ? dong : null, // '미지정동'은 표시 생략
          unitLabel,
        ].where((s) => s != null && s!.isNotEmpty).join(' ');

        final String phone = (_firstPhone(prods) ?? '01012345678');

        // ✅ 내비 주소에도 동 포함
        final String navAddr = [
          baseLine1,
          baseLine2,
          (dong != '미지정동') ? dong : null,
          unitLabel,
        ].where((s) => s != null && s!.isNotEmpty).join(' ');

        final bool unitAllDone = (agg == 2);
        final Color addrTextColor =
            unitAllDone ? const Color(0xFFAAAAAA) : Colors.black87;
        final Color actionIconColor =
            unitAllDone ? const Color(0xFFAAAAAA) : const Color(0xFF61D5AB);

        // 🔑 유닛 subtree에 Key 부여 (재사용 버그 방지)
        final unitKey =
            'unit:${base}|${item['building'] ?? ''}|$unitLabel|$areaIndex|$ui';

        Widget buildUnitButton() {
          if (agg == 2) {
            return OutlinedButton(
              onPressed: null,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFAAAAAA),
                disabledForegroundColor: const Color(0xFFAAAAAA),
                side: const BorderSide(color: Color(0xFFAAAAAA)),
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                backgroundColor: Colors.white,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SvgPicture.asset(
                    'assets/images/delivery/complete.svg',
                    width: 20,
                    height: 20,
                    color: const Color(0xFFAAAAAA),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '배송 완료',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFAAAAAA),
                    ),
                  ),
                ],
              ),
            );
          } else if (agg == 1) {
            // 진행중(사진 찍고 저장 + 완료)
            return ElevatedButton(
              onPressed: () async {
                final prodsToProcess = List<Map<String, dynamic>>.from(prods);
                if (prodsToProcess.isEmpty) return;

                await showDialog(
                  context: context,
                  useRootNavigator: false,
                  builder:
                      (_) => PhotoCaptureModal(
                        phoneNumber: phone,
                        productId:
                            int.tryParse(
                              prodsToProcess.first['productId'].toString(),
                            ) ??
                            -1,
                        onSend: (File image) async {
                          // 0) Firebase 업로드
                          final url = await FirebaseUploader.uploadImage(
                            image,
                            folder: 'deliveries',
                          );
                          if (!mounted) return;
                          if (url == null || url.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Firebase 업로드 실패')),
                            );
                            return;
                          }

                          // 좌표
                          final pos = await _safeGetPosition();
                          final double? lat = pos?.latitude;
                          final double? lng = pos?.longitude;

                          bool anyFailed = false;
                          bool anySucceeded = false;

                          // 단일 product 저장/완료
                          Future<bool> _persistImageForProduct(
                            int pid,
                            Map<String, dynamic> p,
                            String url,
                          ) async {
                            final location =
                                '${p['address'] ?? ''} ${p['detailAddress'] ?? ''}'
                                    .trim();
                            final addressShort = _makeAddressShort(
                              p['address']?.toString(),
                            );
                            final region = _extractRegionFromProd(p);

                            // 시작(메타) — 실패해도 계속
                            await ApiService.updateProductStatus(
                              pid,
                              '배송시작',
                              location: location,
                              addressShort: addressShort,
                              region: region,
                              latitude: lat,
                              longitude: lng,
                            );

                            // 이미지 URL 저장
                            final saved = await ApiService.sendDeliveryImage(
                              productId: pid,
                              imageUrl: url,
                            );
                            if (!saved) return false;

                            // 완료(메타)
                            await ApiService.updateProductStatus(
                              pid,
                              '배송완료',
                              location: location,
                              addressShort: addressShort,
                              region: region,
                              latitude: lat,
                              longitude: lng,
                            );
                            return true;
                          }

                          for (final p in prodsToProcess) {
                            final int pid =
                                int.tryParse(p['productId'].toString()) ?? -1;
                            if (pid <= 0) {
                              anyFailed = true;
                              continue;
                            }

                            final ok = await _persistImageForProduct(
                              pid,
                              p,
                              url,
                            );
                            if (ok) {
                              _setStatusByPid(areaIndex, pid, 2); // 로컬 완료
                              anySucceeded = true;

                              // (선택) 고객 SMS
                              final tel =
                                  (p['recipientPhone'] ?? '').toString().trim();
                              if (tel.isNotEmpty &&
                                  tel.toLowerCase() != 'null') {
                                final smsText = '배송이 완료되었습니다.\n사진 확인: $url';
                                final uri = Uri.parse(
                                  'sms:$tel?body=${Uri.encodeComponent(smsText)}',
                                );
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(uri);
                                }
                              }
                            } else {
                              anyFailed = true;
                            }
                          }

                          if (!mounted) return;

                          if (anySucceeded) setState(() {}); // 버튼/색 즉시 반영
                          if (anyFailed) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('일부 건의 이미지 저장/상태 처리에 실패했습니다.'),
                              ),
                            );
                          }

                          // 최신 상태 동기화
                          await _refreshPreserveState();
                        },
                      ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF61D5AB),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: const Text(
                '배송 도착',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            );
          } else {
            // 대기(배송 시작)
            return OutlinedButton(
              onPressed: () async {
                final active = _findActiveDeliveryInfo();
                if (active != null) {
                  final activeAddr = active['address'] ?? '';
                  alarmController.addAlarm(
                    AlarmItem(title: '배송완료를 눌렀는지 확인해주세요', subtitle: activeAddr),
                  );
                  await showDialog(
                    context: context,
                    builder:
                        (dialogContext) => _activeWarnDialog(
                          dialogContext,
                          activeAddress: activeAddr,
                        ),
                  );
                  return;
                }

                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder:
                      (_) => const Center(child: CircularProgressIndicator()),
                );

                bool anyFailed = false;
                bool anySucceeded = false;

                // 좌표
                final pos = await _safeGetPosition();
                final double? lat = pos?.latitude;
                final double? lng = pos?.longitude;

                for (final p in prods) {
                  final int pid = int.tryParse(p['productId'].toString()) ?? -1;
                  if (pid <= 0) {
                    anyFailed = true;
                    continue;
                  }

                  final location =
                      '${p['address'] ?? ''} ${p['detailAddress'] ?? ''}'
                          .trim();
                  final addressShort = _makeAddressShort(
                    p['address']?.toString(),
                  );
                  final region = _extractRegionFromProd(p);

                  if (_safeStatusByPid(areaIndex, pid) == 0) {
                    final ok = await ApiService.updateProductStatus(
                      pid,
                      '배송시작',
                      location: location,
                      addressShort: addressShort,
                      region: region,
                      latitude: lat,
                      longitude: lng,
                    );
                    if (ok) {
                      _setStatusByPid(areaIndex, pid, 1); // 로컬 즉시 반영
                      anySucceeded = true;
                    } else {
                      anyFailed = true;
                    }
                  }
                }

                if (!mounted) return;
                Navigator.of(context).pop();

                if (anyFailed) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('일부 건의 배송 시작 처리에 실패했습니다.')),
                  );
                }
                if (anySucceeded) setState(() {}); // 버튼 전환

                await _refreshPreserveState(); // 서버 기준 동기화
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF61D5AB),
                side: const BorderSide(color: Color(0xFF61D5AB)),
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: const Text(
                '배송 시작',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            );
          }
        }

        return KeyedSubtree(
          key: ValueKey(unitKey),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 헤더: 주소 두 줄 + '배송 건수' + 전화/내비 + 버튼
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fullAddrLine1,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: addrTextColor,
                          ),
                        ),
                        Text(
                          fullAddrLine2,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: addrTextColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '배송 건수 : $count건',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color:
                                unitAllDone
                                    ? const Color(0xFF888888)
                                    : const Color(0xFF2D5FFF),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () async {
                          final uri = Uri.parse('tel:$phone');
                          if (await canLaunchUrl(uri)) await launchUrl(uri);
                        },
                        child: SvgPicture.asset(
                          'assets/images/delivery/phone.svg',
                          width: 20,
                          height: 20,
                          color: actionIconColor,
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => startNaviToAddressWithNaver(navAddr),
                        child: SvgPicture.asset(
                          'assets/images/delivery/nav.svg',
                          width: 20,
                          height: 20,
                          color: actionIconColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              buildUnitButton(),
              const SizedBox(height: 24),
              if (ui < units.length - 1)
                Divider(color: Colors.grey[300], height: 1),
              const SizedBox(height: 12),
            ],
          ),
        );
      }),
    );
  }

  // 진행 중 경고 다이얼로그
  Widget _activeWarnDialog(
    BuildContext dialogContext, {
    required String activeAddress,
  }) {
    const double dialogWidth = 360;
    const double contentHeight = 145;
    final hasAddr = activeAddress.trim().isNotEmpty;

    final split = splitAddressForTwoLines(activeAddress);
    final line1 = split['line1'] ?? activeAddress;
    final line2 = split['line2'] ?? '';

    return Center(
      child: SizedBox(
        width: dialogWidth,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          backgroundColor: Colors.white,
          elevation: 6,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          titlePadding: const EdgeInsets.fromLTRB(27, 30, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(27, 13, 24, 20),
          title: SizedBox(
            height: 35,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SvgPicture.asset(
                    'assets/images/icons/warning.svg',
                    width: 35,
                    height: 34,
                    theme: const SvgTheme(currentColor: Color(0xFFEE404C)),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: -15,
                  child: IconButton(
                    icon: const Icon(
                      Icons.close,
                      size: 22,
                      color: Color(0xFF777777),
                    ),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ],
            ),
          ),
          content: SizedBox(
            height: contentHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '다른 주소에서 이미 배송을 시작했습니다',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextSpan(
                        text: '\n이전 건에서 "배송 도착"을 먼저 눌러 주세요.\n',
                        style: TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ],
                  ),
                ),
                if (hasAddr) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '[ 진행 중 배송지 ]',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color.fromARGB(255, 63, 63, 63),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    line1,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF777777),
                    ),
                  ),
                  if (line2.isNotEmpty)
                    Text(
                      line2,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF777777),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ====== 위치 권한/좌표 헬퍼 ======
  Future<void> _ensureLocationPermission() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
    } catch (_) {}
  }

  Future<Position?> _safeGetPosition() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) return null;
      }
      if (perm == LocationPermission.deniedForever) return null;
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  // ====== 추가 끝 ======
}
