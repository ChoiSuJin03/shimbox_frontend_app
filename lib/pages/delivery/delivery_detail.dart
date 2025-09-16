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
import 'package:shimbox_app/models/alarm_item.dart';

class DeliveryDetailPage extends StatefulWidget {
  final Map<String, dynamic> area;
  const DeliveryDetailPage({super.key, required this.area});

  @override
  State<DeliveryDetailPage> createState() => _DeliveryDetailPageState();
}

class _DeliveryDetailPageState extends State<DeliveryDetailPage> {
  int? expandedIndex;

  /// area별 product 순서대로 status (0:대기, 1:시작, 2:완료)
  List<List<int>> deliveryStatus = [];

  /// 화면 데이터:
  /// [{ name:'기본주소 동', base:'기본주소', building:'동', total:n,
  ///    units:[{unit:'1002호', products:[...]}, ...] }]
  List<Map<String, dynamic>> deliveryAreas = [];

  bool isLoading = true;

  final AlarmController alarmController = Get.find<AlarmController>();

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

  // ---------- utils ----------

  /// "206동 1009호" → {'building':'206동','unit':'1009호'}
  Map<String, String> _splitDetail(String? detail) {
    final raw = (detail ?? '').trim();
    if (raw.isEmpty) return {'building': '', 'unit': ''};
    final parts = raw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final building = parts.isNotEmpty ? parts[0] : '';
    final unit = parts.length > 1 ? parts[1] : '';
    return {'building': building, 'unit': unit};
  }

  int _statusToInt(String status) {
    switch (status) {
      case '배송시작':
        return 1;
      case '배송완료':
        return 2;
      default:
        return 0;
    }
  }

  /// status 안전 읽기
  int _safeStatus(int aIdx, int pos) {
    if (aIdx < 0 || aIdx >= deliveryStatus.length) return 0;
    final list = deliveryStatus[aIdx];
    if (pos < 0 || pos >= list.length) return 0;
    return list[pos];
  }

  /// status 안전 쓰기
  void _setStatus(int aIdx, int pos, int v) {
    if (aIdx < 0 || aIdx >= deliveryStatus.length) return;
    final list = deliveryStatus[aIdx];
    if (pos < 0 || pos >= list.length) return;
    list[pos] = v;
  }

  /// 여러 건 상태 집계: 모두 완료=2, 하나라도 진행=1, 전부 대기=0
  int _aggregateStatus(List<int> statuses) {
    if (statuses.isEmpty) return 0;
    if (statuses.every((s) => s == 2)) return 2;
    if (statuses.any((s) => s == 1)) return 1;
    return 0;
  }

  /// 진행 중(=1) 개수
  int _countInProgress(List<int> statuses) =>
      statuses.where((s) => s == 1).length;

  /// 모두 완료 여부
  bool _allDone(List<int> statuses) =>
      statuses.isNotEmpty && statuses.every((s) => s == 2);

  /// 아직 시작 안 함(전부 0) 여부
  bool _allWaiting(List<int> statuses) =>
      statuses.isNotEmpty && statuses.every((s) => s == 0);

  /// 첫 유효 전화번호
  String? _firstPhone(List<Map<String, dynamic>> prods) {
    for (final p in prods) {
      final v = (p['recipientPhone'] ?? '').toString().trim();
      if (v.isNotEmpty && v.toLowerCase() != 'null') return v;
    }
    return null;
  }

  /// 다른 주소에서 이미 시작된 건(1) 찾아서 안내용 정보 반환
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

  /// 주소를 2줄로 쪼갬: “…구/군/시” 까지를 1줄, 나머지를 2줄
  Map<String, String> _splitAddressForTwoLines(String base) {
    final b = base.trim();
    final patterns = [
      RegExp(r'^(.+?구)\s*(.*)$'),
      RegExp(r'^(.+?군)\s*(.*)$'),
      RegExp(r'^(.+?시)\s*(.*)$'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(b);
      if (m != null) {
        return {'line1': m.group(1) ?? b, 'line2': m.group(2) ?? ''};
      }
    }
    return {'line1': b, 'line2': ''};
  }

  // ---------- data ----------

  Future<void> fetchData() async {
    try {
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
          final sp = _splitDetail(detail);
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

          final total = units.fold<int>(
            0,
            (sum, u) => sum + (((u['products'] as List?) ?? []).length),
          );

          // status 일렬화
          final List<int> statuses = [];
          for (final u in units) {
            final plist =
                ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
            for (final prod in plist) {
              final s = _statusToInt((prod['shippingStatus'] ?? '') as String);
              statuses.add(s);
            }
          }

          result.add({
            'name': '$base $building',
            'base': base,
            'building': building,
            'total': total,
            'units': units,
          });
          statusAllAreas.add(statuses);
        });
      }

      result.sort(
        (a, b) => (a['name'] as String).compareTo(b['name'] as String),
      );

      if (!mounted) return;
      setState(() {
        deliveryAreas = result;
        deliveryStatus = statusAllAreas;
        isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
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
                    itemCount: deliveryAreas.length,
                    itemBuilder: (context, index) {
                      final item = deliveryAreas[index];
                      final isExpanded = expandedIndex == index;

                      final List<int> areaStatuses =
                          (index < deliveryStatus.length)
                              ? deliveryStatus[index]
                              : const <int>[];
                      final int total = (item['total'] as int? ?? 0);

                      // 진행 수/완료 수
                      final int doneCount =
                          areaStatuses.where((s) => s == 2).length;
                      final int inProgressCount =
                          areaStatuses.where((s) => s == 1).length;
                      final int progressed = doneCount + inProgressCount;
                      final bool isAllDone =
                          progressed == total &&
                          total > 0 &&
                          inProgressCount == 0;

                      // 마커 색상 3단계
                      Color markerBg;
                      Color markerIcon;
                      if (progressed == 0) {
                        // 전부 대기
                        markerBg = const Color(0xFFF4F4F4);
                        markerIcon = const Color(0xFF61D5AB);
                      } else if (isAllDone) {
                        // 전부 완료
                        markerBg = const Color(0xFFF4F4F4);
                        markerIcon = const Color(0xFF6D6D6D);
                      } else {
                        // 일부 진행 중
                        markerBg = const Color(0xFF61D5AB);
                        markerIcon = Colors.white;
                      }

                      // 타이틀 줄바꿈
                      final splitForHeader = _splitAddressForTwoLines(
                        item['name'] as String,
                      );
                      final headerL1 =
                          splitForHeader['line1'] ?? '${item['name']}';
                      final headerL2 = splitForHeader['line2'] ?? '';

                      // 상태 문구
                      late String statusText;
                      late Color statusColor;
                      if (isAllDone) {
                        statusText = '$total / $total건 완료';
                        statusColor = const Color(0xFF888888);
                      } else if (progressed > 0) {
                        statusText = '$progressed / $total건 진행 중';
                        statusColor = const Color(0xFF2D5FFF);
                      } else {
                        statusText = '0 / $total건 미완료';
                        statusColor = const Color(0xFF888888);
                      }

                      // 완료 시 제목/부제 회색
                      final Color headerTextColor =
                          isAllDone ? const Color(0xFF555555) : Colors.black87;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap:
                                () => setState(
                                  () =>
                                      expandedIndex = isExpanded ? null : index,
                                ),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 마커
                                  Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: markerBg,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Center(
                                      child: SvgPicture.asset(
                                        'assets/images/home/marker.svg',
                                        width: 24,
                                        height: 24,
                                        color: markerIcon,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  // 텍스트 블록
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                headerL1 +
                                                    (isAllDone
                                                        ? ' (배송완료)'
                                                        : ''),
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16,
                                                  color: headerTextColor,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (headerL2.isNotEmpty)
                                          Text(
                                            headerL2,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                              color: headerTextColor,
                                            ),
                                          ),
                                        const SizedBox(height: 4),
                                        Text(
                                          statusText,
                                          style: TextStyle(
                                            color: statusColor,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    isExpanded
                                        ? Icons.keyboard_arrow_up_rounded
                                        : Icons.keyboard_arrow_down_rounded,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (isExpanded) ...[
                            const SizedBox(height: 10),
                            _buildGroupedDropdownContent(index, item),
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

  /// 호(동/호) 섹션 + 버튼 1개(묶음 처리)
  Widget _buildGroupedDropdownContent(
    int areaIndex,
    Map<String, dynamic> item,
  ) {
    final base = (item['base'] ?? '') as String;
    final units = (item['units'] as List?) ?? [];
    int cursor = 0; // status 위치

    // 주소를 ‘…구/군/시’에서 줄바꿈
    final split = _splitAddressForTwoLines(base);
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

        // 이 호의 status 인덱스들
        final start = cursor;
        final myIndices = List.generate(count, (k) => start + k);
        cursor += count;

        // 집계 상태
        final statuses =
            myIndices.map((idx) => _safeStatus(areaIndex, idx)).toList();
        final agg = _aggregateStatus(statuses); // 0/1/2

        // 주소(두 줄)
        final fullAddrLine1 = baseLine1;
        final fullAddrLine2 =
            '${[baseLine2, unitLabel].where((s) => s.isNotEmpty).join(' ')}';

        // 대표 전화/네비
        final String phone = (_firstPhone(prods) ?? '01012345678');
        final String navAddr =
            '${[baseLine1, baseLine2, unitLabel].where((s) => s.isNotEmpty).join(' ')}';

        // 완료 묶음일 때 주소/아이콘/건수 회색
        final bool unitAllDone = (agg == 2);
        final Color addrTextColor =
            unitAllDone ? const Color(0xFFAAAAAA) : Colors.black87;
        final Color actionIconColor =
            unitAllDone ? const Color(0xFFAAAAAA) : const Color(0xFF61D5AB);

        // 버튼 생성
        Widget buildUnitButton() {
          if (agg == 2) {
            // 모두 완료 → 버튼/아이콘/글자 회색
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
            // 진행 중 → 도착 : '배송시작(1)'인 건만 완료 처리
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

                            // 1) 완료 먼저 시도
                            var ok = await ApiService.updateProductStatus(
                              p['productId'],
                              '배송완료',
                            );

                            // 2) 서버가 유효하지 않음(예: 아직 대기)일 수 있으니
                            //    한 번만 시작→완료 순서로 재시도
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

                            // 3) 이미지 전송
                            await ApiService.sendDeliveryImage(
                              productId: p['productId'],
                              imageUrl: url,
                            );

                            // 4) 고객 SMS
                            final tel =
                                (p['recipientPhone'] ?? '').toString().trim();
                            if (tel.isNotEmpty && tel.toLowerCase() != 'null') {
                              final smsText = '배송이 완료되었습니다.\n사진 확인: $url';
                              final uri = Uri.parse(
                                'sms:$tel?body=${Uri.encodeComponent(smsText)}',
                              );
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri);
                              }
                            }

                            // 5) 로컬 상태 반영
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

                          // ✅ 상태 갱신
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
            // 대기 → 시작 : 'WAITING(0)'인 건만 시작
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
                          activeAddress: activeAddr, // 주소 전달
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
                Navigator.of(context).pop(); // 로딩 닫기
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
            // 헤더: 주소 두 줄 + '배송 건수' + 전화/네비
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
                          color: addrTextColor, // 완료면 회색
                        ),
                      ),
                      Text(
                        fullAddrLine2,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: addrTextColor, // 완료면 회색
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
                                  ? const Color(0xFF888888) // 완료 시 회색
                                  : const Color(0xFF2D5FFF), // 진행/대기 시 파랑
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    // 전화 아이콘
                    GestureDetector(
                      onTap: () async {
                        final uri = Uri.parse('tel:$phone');
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      },
                      child: SvgPicture.asset(
                        'assets/images/delivery/phone.svg',
                        width: 20,
                        height: 20,
                        color: actionIconColor, // 완료면 회색
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 내비 아이콘
                    GestureDetector(
                      onTap: () => startNaviToAddressWithNaver(navAddr),
                      child: SvgPicture.asset(
                        'assets/images/delivery/nav.svg',
                        width: 20,
                        height: 20,
                        color: actionIconColor, // 완료면 회색
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

  // 진행 중 경고 다이얼로그 (builder의 context 사용!)
  Widget _activeWarnDialog(
    BuildContext dialogContext, {
    required String activeAddress,
  }) {
    const double dialogWidth = 360;
    const double contentHeight = 145;
    final hasAddr = activeAddress.trim().isNotEmpty;

    // 👉 주소를 두 줄로 쪼개기
    final split = _splitAddressForTwoLines(activeAddress);
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
                  textAlign: TextAlign.left,
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
                    line1, // 첫 줄
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF777777),
                    ),
                  ),
                  if (line2.isNotEmpty)
                    Text(
                      line2, // 두 번째 줄
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
