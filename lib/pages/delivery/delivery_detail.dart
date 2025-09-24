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

// 리포/유틸/위젯
import 'package:shimbox_app/services/delivery_repository.dart';
import 'package:shimbox_app/utils/status_utils.dart';
import 'package:shimbox_app/utils/address_utils.dart';

class DeliveryDetailPage extends StatefulWidget {
  final Map<String, dynamic> area;
  const DeliveryDetailPage({super.key, required this.area});

  @override
  State<DeliveryDetailPage> createState() => _DeliveryDetailPageState();
}

class _DeliveryDetailPageState extends State<DeliveryDetailPage> {
  int? expandedIndex; // 도로명 섹션 펼침 인덱스

  // area별 product 순서대로 status (0:대기, 1:시작, 2:완료)
  List<List<int>> deliveryStatus = [];

  // [{ name:'기본주소 동', base:'기본주소', building:'동', total:n, units:[{unit, products:[]}, ...]}]
  List<Map<String, dynamic>> deliveryAreas = [];

  bool isLoading = true;

  final AlarmController alarmController = Get.find<AlarmController>();
  final _repo = DeliveryRepository();

  /// 도로명별 선택된 동 (Dropdown) 상태: key=road, value=dong
  final Map<String, String?> _selectedDongByRoad = {};

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, () async {
      final prefs = await SharedPreferences.getInstance();
      final savedToken = prefs.getString('token');
      localUser.UserData.token = savedToken;
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
    } catch (_) {
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

  // ---------- 주소 헬퍼 ----------
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

  /// deliveryAreas -> "도로명 → 동"으로 그룹핑
  /// [ { road, totals:{total,done,inProg}, dongs:[ { dong, indices:[areaIndex...], items:[item...] } ] } ]
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

      // 동 추출 (item 또는 units/products에서)
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

    // 정렬
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

  // ---------- status 접근 ----------
  int _safeStatus(int aIdx, int pos) {
    if (aIdx < 0 || aIdx >= deliveryStatus.length) return 0;
    final list = deliveryStatus[aIdx];
    if (pos < 0 || pos >= list.length) return 0;
    return list[pos];
  }

  void _setStatus(int aIdx, int pos, int v) {
    if (aIdx < 0 || aIdx >= deliveryStatus.length) return;
    final list = deliveryStatus[aIdx];
    if (pos < 0 || pos >= list.length) return;
    list[pos] = v;
  }

  String? _firstPhone(List<Map<String, dynamic>> prods) {
    for (final p in prods) {
      final v = (p['recipientPhone'] ?? '').toString().trim();
      if (v.isNotEmpty && v.toLowerCase() != 'null') return v;
    }
    return null;
  }

  Map<String, String>? _findActiveDeliveryInfo() {
    for (int a = 0; a < deliveryAreas.length; a++) {
      int cursor = 0;
      final units = (deliveryAreas[a]['units'] as List?) ?? [];
      for (final u in units) {
        final prods =
            ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
        for (int p = 0; p < prods.length; p++, cursor++) {
          if (_safeStatus(a, cursor) == 1) {
            final prod = prods[p];
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
                      final bool isAllDone =
                          (progressed == total && total > 0 && inProg == 0);

                      final dongs =
                          (rg['dongs'] as List).cast<Map<String, dynamic>>();
                      final dongNames =
                          dongs.map((d) => d['dong'] as String).toList();
                      // 현재 도로의 선택된 동
                      final selDong = _selectedDongByRoad.putIfAbsent(
                        roadName,
                        () => dongNames.isNotEmpty ? dongNames.first : null,
                      );

                      // 헤더(도로명)
                      Widget roadHeader() => GestureDetector(
                        onTap:
                            () => setState(
                              () =>
                                  expandedIndex =
                                      (expandedIndex == ri ? null : ri),
                            ),
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
                                            isAllDone
                                                ? const Color(0xFF555555)
                                                : Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      isAllDone
                                          ? '$total / $total건 완료'
                                          : '$progressed / $total건 진행 중',
                                      style: TextStyle(
                                        color:
                                            isAllDone
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
                                expandedIndex == ri
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                              ),
                            ],
                          ),
                        ),
                      );

                      final opened = expandedIndex == ri;

                      // 선택된 동의 데이터 찾기
                      Map<String, dynamic>? selectedDongBlock;
                      if (selDong != null) {
                        selectedDongBlock = dongs.firstWhere(
                          (d) => d['dong'] == selDong,
                          orElse:
                              () =>
                                  dongs.isNotEmpty
                                      ? dongs.first
                                      : <String, dynamic>{},
                        );
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          roadHeader(),

                          if (opened) ...[
                            // ===== 동 드롭다운 =====
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF7F7F7),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  const Text(
                                    '동 선택',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        isExpanded: true,
                                        value: _selectedDongByRoad[roadName],
                                        items:
                                            dongNames
                                                .map(
                                                  (name) => DropdownMenuItem(
                                                    value: name,
                                                    child: Text(
                                                      name,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                )
                                                .toList(),
                                        onChanged:
                                            (v) => setState(() {
                                              _selectedDongByRoad[roadName] = v;
                                            }),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),

                            // ===== 동 안의 아이템들(=여러 호 묶음) : 기존 카드 재사용 =====
                            if (selectedDongBlock != null &&
                                (selectedDongBlock['items'] as List)
                                    .isNotEmpty) ...[
                              for (
                                int k = 0;
                                k < (selectedDongBlock['items'] as List).length;
                                k++
                              ) ...[
                                _buildGroupedDropdownContent(
                                  (selectedDongBlock['indices'] as List)[k]
                                      as int,
                                  (selectedDongBlock['items'] as List)[k]
                                      as Map<String, dynamic>,
                                ),
                                const SizedBox(height: 8),
                                if (k <
                                    (selectedDongBlock['items'] as List)
                                            .length -
                                        1)
                                  Divider(color: Colors.grey[300], height: 1),
                                const SizedBox(height: 8),
                              ],
                            ] else
                              const Text(
                                '해당 동에 표시할 항목이 없습니다.',
                                style: TextStyle(color: Colors.grey),
                              ),
                          ],

                          const SizedBox(height: 12),
                        ],
                      );
                    },
                  ),
                ),
              ),
    );
  }

  /// 호(동/호) 섹션 + 버튼 1개(묶음 처리)  // 기존 로직 유지
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

        final statuses =
            myIndices.map((idx) => _safeStatus(areaIndex, idx)).toList();
        final agg = aggregateStatus(statuses); // 0/1/2

        final fullAddrLine1 = baseLine1;
        final fullAddrLine2 =
            '${[baseLine2, unitLabel].where((s) => s.isNotEmpty).join(' ')}';

        final String phone = (_firstPhone(prods) ?? '01012345678');
        final String navAddr =
            '${[baseLine1, baseLine2, unitLabel].where((s) => s.isNotEmpty).join(' ')}';

        final bool unitAllDone = (agg == 2);
        final Color addrTextColor =
            unitAllDone ? const Color(0xFFAAAAAA) : Colors.black87;
        final Color actionIconColor =
            unitAllDone ? const Color(0xFFAAAAAA) : const Color(0xFF61D5AB);

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
            return ElevatedButton(
              onPressed: () async {
                final idxToComplete = <int>[];
                final prodsToComplete = <Map<String, dynamic>>[];
                for (int i = 0; i < prods.length; i++) {
                  final st = _safeStatus(areaIndex, myIndices[i]);
                  if (st == 1) {
                    idxToComplete.add(myIndices[i]);
                    prodsToComplete.add(prods[i]);
                  }
                }
                if (prodsToComplete.isEmpty) return;

                final first = prodsToComplete.first;
                await showDialog(
                  context: context,
                  useRootNavigator: false,
                  builder:
                      (_) => PhotoCaptureModal(
                        phoneNumber: phone,
                        productId: first['productId'],
                        onSend: (image) async {
                          final url = await FirebaseUploader.uploadImage(
                            image,
                            folder: 'deliveries',
                          );
                          if (!mounted) return;
                          if (url == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Firebase 업로드 실패')),
                            );
                            return;
                          }

                          bool anyFailed = false;
                          for (int i = 0; i < prodsToComplete.length; i++) {
                            final p = prodsToComplete[i];

                            var ok = await ApiService.updateProductStatus(
                              p['productId'],
                              '배송완료',
                            );
                            if (!ok) {
                              final started =
                                  await ApiService.updateProductStatus(
                                    p['productId'],
                                    '배송시작',
                                  );
                              if (started) {
                                ok = await ApiService.updateProductStatus(
                                  p['productId'],
                                  '배송완료',
                                );
                              }
                            }
                            if (!ok) {
                              anyFailed = true;
                              continue;
                            }

                            await ApiService.sendDeliveryImage(
                              productId: p['productId'],
                              imageUrl: url,
                            );

                            final tel =
                                (p['recipientPhone'] ?? '').toString().trim();
                            if (tel.isNotEmpty && tel.toLowerCase() != 'null') {
                              final smsText = '배송이 완료되었습니다.\n사진 확인: $url';
                              final uri = Uri.parse(
                                'sms:$tel?body=${Uri.encodeComponent(smsText)}',
                              );
                              if (await canLaunchUrl(uri)) await launchUrl(uri);
                            }

                            _setStatus(areaIndex, idxToComplete[i], 2);
                          }

                          if (!mounted) return;
                          if (anyFailed) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('일부 건의 배송 완료 처리에 실패했습니다.'),
                              ),
                            );
                          }
                          setState(() {});
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
                for (int i = 0; i < prods.length; i++) {
                  if (_safeStatus(areaIndex, myIndices[i]) == 0) {
                    final ok = await ApiService.updateProductStatus(
                      prods[i]['productId'],
                      '배송시작',
                    );
                    if (ok) {
                      _setStatus(areaIndex, myIndices[i], 1);
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
                setState(() {});
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

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 헤더: 주소 두 줄 + '배송 건수' + 전화/내비
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
}
