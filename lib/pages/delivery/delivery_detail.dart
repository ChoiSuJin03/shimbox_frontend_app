// lib/pages/delivery/delivery_detail.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimbox_app/controllers/bottom_nav_controller.dart';
import 'package:shimbox_app/utils/navigation_helper.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../utils/api_service.dart';
import 'package:shimbox_app/models/test_user_data.dart' as localUser;

import 'package:shimbox_app/controllers/alarm_controller.dart';
import 'package:shimbox_app/models/alarm/alarm_item.dart';

// 리포/유틸
import 'package:shimbox_app/services/delivery_repository.dart';
import 'package:shimbox_app/utils/address_utils.dart';

// 현재 위치 좌표
import 'package:geolocator/geolocator.dart';

import 'package:shimbox_app/pages/delivery/photo_capture_modal.dart';

class DeliveryDetailPage extends StatefulWidget {
  final Map<String, dynamic> area;
  const DeliveryDetailPage({super.key, required this.area});

  @override
  State<DeliveryDetailPage> createState() => _DeliveryDetailPageState();
}

class _DeliveryDetailPageState extends State<DeliveryDetailPage> {
  String? expandedRoadKey;

  // 서버 원본
  List<List<int>> deliveryStatus = [];
  List<Map<String, dynamic>> deliveryAreas = [];

  // productId -> status(0:대기, 1:시작, 2:완료)
  final Map<int, int> _statusByPid = {};

  // productId -> phone 캐시
  final Map<int, String> _phoneByPid = {};

  // ✅ 백엔드에 전화번호가 없을 때 사용할 기본 번호(하이픈 없이)
  static const String kFallbackPhone = '01012345678';

  bool isLoading = true;

  final AlarmController alarmController = Get.find<AlarmController>();
  final _repo = DeliveryRepository();

  /// 도로명별 현재 선택된 동
  final Map<String, String?> _selectedDongByRoadKey = {};

  /// 상세에서 상태 변경 발생 여부 (뒤로갈 때 Home 갱신용)
  bool _mutated = false;

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

  Future<void> fetchData() async {
    try {
      final res = await _repo.fetchAreas();
      if (!mounted) return;

      setState(() {
        deliveryAreas = res.deliveryAreas;
        deliveryStatus = res.deliveryStatus;
        isLoading = false;
      });

      // pid -> status 매핑
      _statusByPid.clear();
      for (int a = 0; a < deliveryAreas.length; a++) {
        final units = (deliveryAreas[a]['units'] as List?) ?? [];
        for (final u in units) {
          final prods =
              ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
          for (final p in prods) {
            final pid = int.tryParse(p['productId'].toString()) ?? -1;
            if (pid <= 0) continue;

            final raw =
                (p['shippingStatus'] ?? p['status'] ?? '').toString().trim();

            int st;
            if (raw.isNotEmpty && raw.toLowerCase() != 'null') {
              final s = raw;
              if (s.contains('완료') || s.toUpperCase() == 'COMPLETED')
                st = 2;
              else if (s.contains('시작') || s.toUpperCase() == 'STARTED')
                st = 1;
              else
                st = 0;
            } else {
              st = 0;
            }
            _statusByPid[pid] = st;
          }
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

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
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length >= 3) return '${parts[1]} ${parts[2]}';
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

  Map<String, int> _countStatusesForAreaIndex(int aIdx) {
    int total = 0, done = 0, inProg = 0;
    if (aIdx < 0 || aIdx >= deliveryAreas.length) {
      return {'total': 0, 'done': 0, 'inProg': 0};
    }
    final units = (deliveryAreas[aIdx]['units'] as List?) ?? [];
    for (final u in units) {
      final prods =
          ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
      for (final p in prods) {
        final pid = int.tryParse(p['productId'].toString()) ?? -1;
        if (pid <= 0) continue;
        total++;
        final st = statusByPid(pid);
        if (st == 2)
          done++;
        else if (st == 1)
          inProg++;
      }
    }
    return {'total': total, 'done': done, 'inProg': inProg};
  }

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

      final areaAgg = _countStatusesForAreaIndex(i);
      (roadSlot['totals'] as Map)['total'] =
          ((roadSlot['totals'] as Map)['total'] as int) + areaAgg['total']!;
      (roadSlot['totals'] as Map)['done'] =
          ((roadSlot['totals'] as Map)['done'] as int) + areaAgg['done']!;
      (roadSlot['totals'] as Map)['inProg'] =
          ((roadSlot['totals'] as Map)['inProg'] as int) + areaAgg['inProg']!;

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

  int statusByPid(int productId) => _statusByPid[productId] ?? 0;
  void setStatusByPid(int productId, int v) {
    _statusByPid[productId] = v;
    _mutated = true;
  }

  Map<String, int> _calcDongProgressWithPid(List<int> areaIndexes) {
    int total = 0;
    int done = 0;
    int inProg = 0;
    for (final aIdx in areaIndexes) {
      final area = _countStatusesForAreaIndex(aIdx);
      total += area['total']!;
      done += area['done']!;
      inProg += area['inProg']!;
    }
    return {'total': total, 'done': done, 'inProg': inProg};
  }

  String _stableRoadKey(String roadName, List<Map<String, dynamic>> dongs) {
    final idxs = <int>[];
    for (final d in dongs) {
      final indices = ((d['indices'] as List?) ?? []).cast<int>();
      idxs.addAll(indices);
    }
    idxs.sort();
    final name = roadName.isEmpty ? '기타' : roadName;
    return 'road:$name|idx:${idxs.join(',')}';
  }

  // ===== 전화번호 정규화/탐색 강화 =====

  // 한국 전화번호 패턴 (+82 포함, 02/0xx 유선, 010 휴대폰)
  final RegExp _krPhoneRegex = RegExp(
    r'(?:\+?82[-\s]?)?0(?:2|\d{2})[-\s]?\d{3,4}[-\s]?\d{4}',
  );

  // 정규화: +82 → 0, 숫자만 추출, 자릿수 보정
  String? _normalizeKoreanPhone(String? raw) {
    if (raw == null) return null;
    String digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;

    if (digits.startsWith('82')) {
      digits = '0' + digits.substring(2);
    }

    // 010 휴대폰 최우선
    final idx010 = digits.indexOf('010');
    if (idx010 != -1 && digits.length >= idx010 + 11) {
      return digits.substring(idx010, idx010 + 11);
    }

    // 02 유선 (9~10자리)
    if (digits.startsWith('02')) {
      if (digits.length >= 9 && digits.length <= 10) return digits;
      if (digits.length > 10) return digits.substring(0, 10);
    }

    // 0xx 유선 (10~11자리)
    if (RegExp(r'^0\d{1,2}').hasMatch(digits)) {
      if (digits.length >= 10 && digits.length <= 11) return digits;
      if (digits.length > 11) return digits.substring(0, 11);
    }

    if (digits.length < 9) return null;
    return digits.substring(0, digits.length.clamp(9, 11));
  }

  // 임의 데이터 어디서든 전화번호를 찾아내는 재귀 탐색
  String? _extractPhoneAnywhere(dynamic data) {
    if (data == null) return null;

    if (data is String) {
      // 문자열에 직접 번호가 있으면 매칭
      final match = _krPhoneRegex.firstMatch(data);
      if (match != null) {
        final normalized = _normalizeKoreanPhone(match.group(0));
        if (normalized != null) return normalized;
      }
      return null;
    }

    if (data is num || data is bool) return null;

    if (data is List) {
      for (final v in data) {
        final r = _extractPhoneAnywhere(v);
        if (r != null) return r;
      }
      return null;
    }

    if (data is Map) {
      // 1) 컬럼/키가 확정된 경우 최우선 확인
      const primaryKeys = [
        'recipient_phone_number', // DB 컬럼
        // 혹시 변형 스키마 대비
        'recipientPhoneNumber', 'recipientPhone', 'recipient_phone',
        'phoneNumber', 'phone', 'mobile', 'tel',
      ];
      for (final k in primaryKeys) {
        if (data.containsKey(k)) {
          final r = _extractPhoneAnywhere(data[k]);
          if (r != null) return r;
        }
      }

      // 2) 그 외 흔한 후보 키들
      const candidateKeys = [
        'recipientTel',
        'recipient_tel',
        'receiverPhone',
        'customerPhone',
        'userPhone',
        'clientPhone',
        'contact',
        'contactPhone',
        'mobileNumber',
        'hp',
        'hpNo',
        'telNo',
        'phoneNo',
        'cell',
        'cellPhone',
        'cellphone',
        'memo',
        'note',
        'requestMessage',
        'deliveryMemo',
        'message',
        'recipient',
        'receiver',
        'customer',
        'user',
        'client',
        'consignee',
      ];
      for (final k in candidateKeys) {
        if (data.containsKey(k)) {
          final r = _extractPhoneAnywhere(data[k]);
          if (r != null) return r;
        }
      }

      // 3) 전수 검사(키 이름이 완전 생소한 경우)
      for (final v in data.values) {
        final r = _extractPhoneAnywhere(v);
        if (r != null) return r;
      }
      return null;
    }

    // 알 수 없는 타입은 문자열 변환 후 시도
    return _extractPhoneAnywhere(data.toString());
  }

  // 개별 productId로 상세 조회하여 전화번호 가져오기(+캐시)
  Future<String?> _fetchPhoneForPid(int pid) async {
    if (_phoneByPid.containsKey(pid)) return _phoneByPid[pid];

    // FIXME: 백엔드 상세 엔드포인트 확인 후 필요시 수정
    final resp = await ApiService.get('/api/v1/driver/product/$pid');

    final sc = resp['statusCode'] ?? resp['status'] ?? 500;
    if (sc != 200) return null;

    final data = resp['data'];
    if (data is! Map) return null;

    // 키 여러 형태 커버
    final raw =
        data['recipient_phone_number'] ??
        data['recipientPhoneNumber'] ??
        data['recipientPhone'] ??
        data['recipient_phone'] ??
        data['phoneNumber'] ??
        data['phone'] ??
        data['mobile'] ??
        data['tel'];

    String? phone = _normalizeKoreanPhone(raw?.toString());
    phone ??= _extractPhoneAnywhere(data); // 메모/자유텍스트에 있는 경우

    if (phone != null) _phoneByPid[pid] = phone;
    return phone;
  }

  // products 배열에서 첫 전화번호 추출
  String? _firstPhone(List<Map<String, dynamic>> prods) {
    for (final p in prods) {
      // 1) 확정 키(바로 반환)
      final direct = _normalizeKoreanPhone(
        p['recipient_phone_number']?.toString(),
      );
      if (direct != null) return direct;

      // 2) 부분 키명 스캔 (phone/tel/mobile/cell 들어가면 후보 처리)
      for (final entry in p.entries) {
        final key = entry.key.toString().toLowerCase();
        if (key.contains('phone') ||
            key.contains('tel') ||
            key.contains('mobile') ||
            key.contains('cell')) {
          final cand = _normalizeKoreanPhone(entry.value?.toString());
          if (cand != null) return cand;
        }
      }

      // 3) 재귀 전수 탐색(메모/중첩 객체/문자열 내부 숫자)
      final any = _extractPhoneAnywhere(p);
      if (any != null) return any;
    }

    // 디버깅 도움
    if (prods.isNotEmpty) {
      debugPrint('[PHONE] not found. product keys: ${prods.first.keys}');
    }
    return null;
  }

  // ================================

  Map<String, String>? _findActiveDeliveryInfo() {
    for (int a = 0; a < deliveryAreas.length; a++) {
      final units = (deliveryAreas[a]['units'] as List?) ?? [];
      for (final u in units) {
        final prods =
            ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
        for (final prod in prods) {
          final pid = int.tryParse(prod['productId'].toString()) ?? -1;
          if (pid > 0 && statusByPid(pid) == 1) {
            final addr = '${prod['address']} ${prod['detailAddress']}';
            final name = '${prod['recipientName']}';
            return {'address': addr, 'name': name};
          }
        }
      }
    }
    return null;
  }

  /// 다른 진행중 건이 있는지 검사 (ignorePids는 "같이 처리 중"으로 간주하여 제외)
  Map<String, String>? _findOtherActiveDeliveryInfo({
    int? excludePid,
    Set<int>? ignorePids,
  }) {
    for (int a = 0; a < deliveryAreas.length; a++) {
      final units = (deliveryAreas[a]['units'] as List?) ?? [];
      for (final u in units) {
        final prods =
            ((u['products'] as List?) ?? []).cast<Map<String, dynamic>>();
        for (final prod in prods) {
          final pid = int.tryParse(prod['productId'].toString()) ?? -1;
          if (pid <= 0) continue;
          if (excludePid != null && pid == excludePid) continue;
          if (ignorePids != null && ignorePids.contains(pid)) continue;

          if (statusByPid(pid) == 1) {
            final addr = '${prod['address']} ${prod['detailAddress']}';
            final name = '${prod['recipientName']}';
            return {'address': addr, 'name': name};
          }
        }
      }
    }
    return null;
  }

  // 전화번호 마스킹(다이얼로그 표시용)
  String _maskPhone(String tel) {
    final t = tel.replaceAll(RegExp(r'[^0-9]'), '');
    if (t.length < 7) return tel;
    return '${t.substring(0, 3)}-${t.substring(3, 7)}-${t.substring(7)}';
  }

  @override
  Widget build(BuildContext context) {
    const colorDoneBg = Color(0xFFF4F4F4);
    const colorDoneFg = Color(0xFF4FC99D);
    const colorProgBg = Color(0xFF4FC99D);
    const colorProgFg = Colors.white;
    const colorIdleBg = Color(0xFFF4F4F4);
    const colorIdleFg = Colors.black;

    final roadGroups = groupByRoadThenDong();

    return WillPopScope(
      onWillPop: () async {
        Get.back(result: _mutated);
        return false;
      },
      child: Scaffold(
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
                onTap: () => Get.back(result: _mutated),
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

                        final roadKey = _stableRoadKey(roadName, dongs);

                        // ▶ 헤더(도로명)
                        Widget roadHeader() {
                          final bool isCompleted =
                              (progressed == total && total > 0 && inProg == 0);
                          final bool isIdle = progressed == 0;
                          final bool isInProgress =
                              !isCompleted && !isIdle; // 일부 진행중

                          final Color bgColor =
                              isCompleted
                                  ? const Color(0xFFF4F4F4) // 완료 배경
                                  : (isInProgress
                                      ? const Color(0xFF61D5AB) // 진행중 배경
                                      : const Color(0xFFF4F4F4)); // 미시작 배경
                          final Color iconColor =
                              isCompleted
                                  ? const Color(0xFF61D5AB) // 완료 아이콘
                                  : (isInProgress
                                      ? const Color(0xFFF4F4F4) // 진행중 아이콘
                                      : const Color(0xFF171412)); // 미시작 아이콘(검정)

                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                expandedRoadKey =
                                    (expandedRoadKey == roadKey)
                                        ? null
                                        : roadKey;
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: bgColor,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Center(
                                      child: SvgPicture.asset(
                                        'assets/images/home/marker.svg',
                                        width: 24,
                                        height: 24,
                                        color: iconColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          roadName.isEmpty ? '기타' : roadName,
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                            color:
                                                isCompleted
                                                    ? const Color(0xFF555555)
                                                    : Colors.black87,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          isCompleted
                                              ? '$total / $total건 완료'
                                              : '$progressed / $total건 진행 중',
                                          style: TextStyle(
                                            color:
                                                isCompleted
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
                        }

                        final opened = expandedRoadKey == roadKey;

                        final dongNames =
                            dongs
                                .map((d) => (d['dong'] as String?) ?? '미지정동')
                                .toList();
                        if (!_selectedDongByRoadKey.containsKey(roadKey)) {
                          _selectedDongByRoadKey[roadKey] =
                              dongNames.isNotEmpty ? dongNames.first : null;
                        }
                        final selectedDongName =
                            _selectedDongByRoadKey[roadKey];

                        return KeyedSubtree(
                          key: ValueKey(roadKey),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              roadHeader(),
                              if (opened) ...[
                                // 동 칩
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
                                                (d['dong'] as String?) ??
                                                '미지정동';
                                            final areaIdxs =
                                                ((d['indices'] as List?) ?? [])
                                                    .cast<int>();

                                            final prog =
                                                _calcDongProgressWithPid(
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
                                                            : Colors
                                                                .transparent,
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
                                            ((d['dong'] as String?) ??
                                                '미지정동') ==
                                            selectedDongName,
                                        orElse: () => <String, dynamic>{},
                                      );
                                      if (selectedDongBlock == null ||
                                          (selectedDongBlock['items']
                                                  as List?) ==
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
                                          ((selectedDongBlock['indices']
                                                  as List))
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

        String dong = extractDong(item);
        if ((dong.isEmpty || dong == '미지정동') && prods.isNotEmpty) {
          dong = extractDong(item, prods.first);
        }

        final prodIds =
            prods
                .map((p) => int.tryParse(p['productId'].toString()) ?? -1)
                .where((pid) => pid > 0)
                .toList()
              ..sort();

        final stableUnitKey = 'unit:${areaIndex}:${prodIds.join(',')}';

        final statuses = prodIds.map((pid) => statusByPid(pid)).toList();
        final int total = statuses.length;
        final int done = statuses.where((s) => s == 2).length;
        final int started = statuses.where((s) => s == 1).length;
        final int agg =
            (total > 0 && done == total)
                ? 2
                : ((done == 0 && started == 0) ? 0 : 1);

        final fullAddrLine1 = baseLine1;
        final fullAddrLine2 = [
          baseLine2,
          (dong != '미지정동') ? dong : null,
          unitLabel,
        ].where((s) => s != null && s!.isNotEmpty).join(' ');

        // ✅ 기본 번호 fallback 적용 (묶음 표시용 저장값)
        final String phone = _firstPhone(prods) ?? kFallbackPhone;

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

        return KeyedSubtree(
          key: ValueKey(stableUnitKey),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 헤더
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
                          // 1) 묶음에서 추출한 번호
                          String? tel = phone;

                          // 2) 없으면 상세 조회 보완 (여러 pid 중 첫 성공)
                          if ((tel == null || tel.isEmpty) &&
                              prodIds.isNotEmpty) {
                            for (final pid in prodIds) {
                              tel = await _fetchPhoneForPid(pid);
                              if (tel != null) break;
                            }
                          }

                          // 3) 그래도 없으면 하드코딩 기본 번호 사용
                          tel ??= kFallbackPhone;

                          final uri = Uri.parse('tel:$tel');
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri);
                          }
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
              _buildUnitActionButton(areaIndex, prods, agg),
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

  Widget _buildUnitActionButton(
    int areaIndex,
    List<Map<String, dynamic>> prods,
    int agg,
  ) {
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
      // 진행중 → "고객에게 문자 보내기" 다이얼로그 → 확인 시 문자앱 열고, 복귀 후 '배송완료'
      return ElevatedButton(
        onPressed: () async {
          final prodsToProcess = List<Map<String, dynamic>>.from(prods);
          if (prodsToProcess.isEmpty) return;

          // 동일 유닛의 pid 집합 (동시에 허용)
          final allowedPids =
              prodsToProcess
                  .map((p) => int.tryParse(p['productId'].toString()) ?? -1)
                  .where((pid) => pid > 0)
                  .toSet();

          // 전화번호: 우선 추출 → 상세조회 보완 → 최종 fallback
          String? tel = _firstPhone(prodsToProcess);
          if ((tel == null || tel.isEmpty) && allowedPids.isNotEmpty) {
            for (final pid in allowedPids) {
              tel = await _fetchPhoneForPid(pid);
              if (tel != null) break;
            }
          }
          tel ??= kFallbackPhone;

          // ⬇️ 여기서 사진 대신 "텍스트 영역" 모달을 띄워 액션 처리
          await showDialog(
            context: context,
            barrierDismissible: true,
            builder: (_) {
              return PhotoCaptureModal(
                phoneNumber: tel!, // 마스킹은 모달 내부에서 처리
                productId: allowedPids.isEmpty ? -1 : allowedPids.first,
                onSend: () async {
                  // 1) 문자앱 열기
                  final smsText = '배송이 도착했습니다. 사진을 문자로 보내드립니다.';
                  final smsUri = Uri.parse(
                    'sms:$tel?body=${Uri.encodeComponent(smsText)}',
                  );
                  await launchUrl(smsUri, mode: LaunchMode.externalApplication);

                  // 2) 좌표(옵션)
                  final pos = await _safeGetPosition();
                  final double? lat = pos?.latitude;
                  final double? lng = pos?.longitude;

                  bool anyFailed = false;
                  bool anySucceeded = false;

                  // 문자앱 이동 후 복귀 시 완료 처리
                  Future<bool> _completeDirectly(
                    int pid,
                    Map<String, dynamic> p,
                  ) async {
                    final location =
                        '${p['address'] ?? ''} ${p['detailAddress'] ?? ''}'
                            .trim();
                    final addressShort = _makeAddressShort(
                      p['address']?.toString(),
                    );
                    final region = _extractRegionFromProd(p);

                    // 다른 진행중 건 차단(동일 유닛 pid는 허용)
                    await _refreshPreserveState();
                    final otherActive = _findOtherActiveDeliveryInfo(
                      ignorePids: allowedPids,
                    );
                    if (otherActive != null) {
                      await showDialog(
                        context: context,
                        builder:
                            (dctx) => _activeWarnDialog(
                              dctx,
                              activeAddress: otherActive['address'] ?? '',
                            ),
                      );
                      return false;
                    }

                    final okDone = await ApiService.updateProductStatus(
                      pid,
                      '배송완료',
                      location: location,
                      addressShort: addressShort,
                      region: region,
                      latitude: lat,
                      longitude: lng,
                    );
                    if (!okDone) return false;

                    setStatusByPid(pid, 2); // 로컬 완료
                    return true;
                  }

                  for (final p in prodsToProcess) {
                    final int pid =
                        int.tryParse(p['productId'].toString()) ?? -1;
                    if (pid <= 0) {
                      anyFailed = true;
                      continue;
                    }
                    final ok = await _completeDirectly(pid, p);
                    if (ok) {
                      anySucceeded = true;
                    } else {
                      anyFailed = true;
                    }
                  }

                  if (!mounted) return;

                  if (anySucceeded) {
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('배송이 완료되었습니다.')),
                    );
                  }
                  if (anyFailed) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('일부 건의 완료 처리에 실패했습니다.')),
                    );
                  }

                  await _refreshPreserveState();
                },
              );
            },
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
      // 대기(배송 시작) — 동일 유닛의 모든 상품 동시 STARTED
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
            builder: (_) => const Center(child: CircularProgressIndicator()),
          );

          bool anyFailed = false;
          bool anySucceeded = false;

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
                '${p['address'] ?? ''} ${p['detailAddress'] ?? ''}'.trim();
            final addressShort = _makeAddressShort(p['address']?.toString());
            final region = _extractRegionFromProd(p);

            if (statusByPid(pid) == 0) {
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
                setStatusByPid(pid, 1);
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

          await _refreshPreserveState();
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
}
