import 'package:shimbox_app/pages/alarm/alarm.dart';
import 'package:shimbox_app/controllers/location_controller.dart';
import 'survey_module.dart';
import 'dart:async';

import 'package:shimbox_app/models/adjusted_volume_dialog.dart';
import 'package:shimbox_app/controllers/alarm_controller.dart';
import 'package:shimbox_app/models/alarm/alarm_item.dart';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimbox_app/controllers/bottom_nav_controller.dart';
import '../delivery/delivery_detail.dart';
import 'package:shimbox_app/models/test_user_data.dart';
import 'package:shimbox_app/utils/api_service.dart';
import 'package:shimbox_app/services/location_socket_service.dart';

// ✅ 평균 심박/걸음 조회를 위해 추가
import 'package:shimbox_app/pages/health/health_service.dart';

class HomePage extends StatefulWidget {
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final BottomNavController bottomController;

  List<Map<String, dynamic>> deliveryAreas = [];
  int totalDeliveries = 0;
  int completedDeliveries = 0;

  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool showSurvey = false;

  Timer? _homeRefreshTicker;
  static const Duration _homeRefreshTick = Duration(seconds: 10);

  int? _lastAssignedTotal;
  static const String _prefsAssignedKey = 'assigned_total_last';

  DateTime? _lastPopupAt;
  static const Duration _popupDebounce = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    bottomController = Get.find<BottomNavController>();

    _restoreLastAssignedFromPrefs();
    _connectLocationWsOnce();
    LocationSocketService.instance.markHomeEntered();

    fetchDeliverySummary();
    _startHomeRefreshTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      LocationSocketService.instance.markHomeEntered();
      if (!LocationSocketService.instance.isConnected) {
        await _connectLocationWsOnce();
      }
      fetchDeliverySummary();
      _startHomeRefreshTicker();
    } else {
      _stopHomeRefreshTicker();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    LocationSocketService.instance.markHomeEntered();
    fetchDeliverySummary();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopHomeRefreshTicker();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _restoreLastAssignedFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(_prefsAssignedKey);
      _lastAssignedTotal = v;
    } catch (_) {}
  }

  void _startHomeRefreshTicker() {
    _homeRefreshTicker ??= Timer.periodic(
      _homeRefreshTick,
      (_) => _autoRefreshHome(),
    );
  }

  void _stopHomeRefreshTicker() {
    _homeRefreshTicker?.cancel();
    _homeRefreshTicker = null;
  }

  Future<void> _autoRefreshHome() async {
    if (!mounted) return;
    if (!LocationSocketService.instance.isConnected) {
      await _connectLocationWsOnce();
    }
    await fetchDeliverySummary();
  }

  // ▶ 완료(배송완료) 건은 숨기고, 활성(미완료=total-completed)만 보여주는 버전
  Future<void> fetchDeliverySummary() async {
    try {
      final data = await ApiService.fetchDeliverySummary();

      int totalActiveAll = 0; // 전체 활성(미완료) 합계
      final Map<String, Map<String, int>> buckets = {};

      String normalizeToGu(String? raw) {
        if (raw == null) return '';
        final s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
        return formatKoreanAddress(s);
      }

      // 지역별 활성(= total - completed) 집계, 활성 0이면 제외
      for (final area in data) {
        final key = normalizeToGu(area['shippingLocation']?.toString());
        final int total = (area['totalCount'] ?? 0).toInt();
        final int completed = (area['completedCount'] ?? 0).toInt();
        final int active = (total - completed).clamp(0, total);

        if (active == 0) continue; // 전부 완료인 지역은 숨김

        final slot = buckets.putIfAbsent(key, () => {'active': 0});
        slot['active'] = (slot['active'] ?? 0) + active;
        totalActiveAll += active;
      }

      final areas =
          buckets.entries
              .map(
                (e) => {
                  'name': e.key,
                  'total': e.value['active']!, // 리스트의 total을 '활성 수'로 사용
                  'completed': 0, // 완료는 숨김
                },
              )
              .toList()
            ..sort(
              (a, b) => (a['name'] as String).compareTo(b['name'] as String),
            );

      if (!mounted) return;

      _maybeShowAdjustedVolumePopup(
        prev: _lastAssignedTotal,
        now: totalActiveAll,
      );

      setState(() {
        deliveryAreas = areas;
        totalDeliveries = totalActiveAll; // 상단 게이지 분모도 활성 합계
        completedDeliveries = 0; // 완료는 표시하지 않음
      });

      _persistAssignedTotal(totalActiveAll);
    } catch (e) {
      print('❌ 배송 요약 불러오기 실패: $e');
    }
  }

  Future<void> _maybeShowAdjustedVolumePopup({
    int? prev,
    required int now,
  }) async {
    if (showSurvey) return;
    if (prev == null) return;
    if (prev == now) return;

    final appState = WidgetsBinding.instance.lifecycleState;
    final inForeground = appState == AppLifecycleState.resumed;
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final nowTs = DateTime.now();
    final canPopup =
        _lastPopupAt == null ||
        nowTs.difference(_lastPopupAt!) >= _popupDebounce;

    if (!mounted || !inForeground || !isCurrent || !canPopup) return;

    _lastPopupAt = nowTs;

    await AdjustedVolumeDialog.show(
      context,
      title: '건강/상황을 반영해 오늘 배송물량이',
      titleLine2: '조정되었습니다.',
      description: '무리없이 일하실 수 있도록 도와드릴게요.',
      before: prev,
      after: now,
      iconColor: const Color(0xFF61D5AB),
      width: 340,
    );

    try {
      final alarm = Get.find<AlarmController>();
      alarm.addAlarm(
        AlarmItem(title: '배송물량이 조정되었습니다.', subtitle: '$prev → ${now}건'),
      );
    } catch (_) {}
  }

  Future<void> _persistAssignedTotal(int v) async {
    _lastAssignedTotal = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsAssignedKey, v);
    } catch (_) {}
  }

  String getShortName(String fullName) {
    if (fullName.length <= 2) return fullName;
    return fullName.substring(fullName.length - 2);
  }

  String _areaStatusText(Map<String, dynamic> area) {
    final int total = (area['total'] ?? 0); // 여기서는 '활성 수'
    final int done = (area['completed'] ?? 0); // 항상 0으로 처리
    if (total == 0) return '0 / 0건 미완료';
    if (done == 0) return '0 / $total건 완료';
    if (done >= total) return '$done / $total건 완료';
    return '$done / $total건 진행 중..';
  }

  String formatKoreanAddress(String? input) {
    if (input == null) return '';
    final parts = input.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '';

    final first = parts[0];

    if (first.endsWith('특별시') ||
        first.endsWith('광역시') ||
        first.endsWith('특별자치시')) {
      if (parts.length >= 2) return '${parts[0]} ${parts[1]}';
      return parts[0];
    }

    if (first.endsWith('도') || first.endsWith('특별자치도')) {
      if (parts.length >= 3) return '${parts[0]} ${parts[1]} ${parts[2]}';
      if (parts.length >= 2) return '${parts[0]} ${parts[1]}';
      return parts[0];
    }

    return parts.take(2).join(' ');
  }

  Color _areaStatusColor(Map<String, dynamic> area) {
    final int total = (area['total'] ?? 0);
    final int done = (area['completed'] ?? 0);
    if (total > 0 && done >= total) return const Color(0xFF61D5AB);
    if (done == 0) return Colors.grey;
    return const Color(0xFF747474);
  }

  bool _isAreaNotStarted(Map<String, dynamic> area) {
    final int total = (area['total'] ?? 0);
    final int done = (area['completed'] ?? 0);
    return total > 0 && done == 0;
  }

  bool _isAreaInProgress(Map<String, dynamic> area) {
    final int total = (area['total'] ?? 0);
    final int done = (area['completed'] ?? 0);
    return total > 0 && done > 0 && done < total;
  }

  bool _isAreaCompleted(Map<String, dynamic> area) {
    final int total = (area['total'] ?? 0);
    final int done = (area['completed'] ?? 0);
    return total > 0 && done >= total;
  }

  String _extractGu(String? s) {
    if (s == null) return '';
    final t = s.trim();
    final m = RegExp(r'([가-힣A-Za-z]+구)').firstMatch(t);
    return m != null ? m.group(1)! : t;
  }

  Future<void> _connectLocationWsOnce() async {
    final raw = LocationController.to.currentShortAddress.value;
    String region = _extractGu(raw);

    if (region.isEmpty && deliveryAreas.isNotEmpty) {
      region = _extractGu(deliveryAreas.first['name']?.toString());
    }
    if (region.isEmpty) region = '성북구';

    print('[HOME] connect WS with region="$region"');
    await LocationSocketService.instance.connect(region: region);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          // ✅ 임시 AppBar 제거 (미리보기 헤더 없앰)
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 38),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 유저 정보
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipOval(
                              child: Image.asset(
                                'assets/images/home/hong.png',
                                width: 63.84,
                                height: 63,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${UserData.name ?? '사용자'}님',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SvgPicture.asset(
                                        'assets/images/home/marker.svg',
                                        width: 17,
                                        height: 17,
                                        color: Colors.grey,
                                      ),
                                      const SizedBox(width: 5),
                                      Flexible(
                                        fit: FlexFit.loose,
                                        child: Obx(() {
                                          final full =
                                              LocationController
                                                  .to
                                                  .currentFullAddress
                                                  .value
                                                  .trim();
                                          final short =
                                              LocationController
                                                  .to
                                                  .currentShortAddress
                                                  .value
                                                  .trim();
                                          final pos =
                                              LocationController
                                                  .to
                                                  .currentLatLng
                                                  .value;

                                          final display =
                                              full.isNotEmpty
                                                  ? full
                                                  : (short.isNotEmpty
                                                      ? short
                                                      : (pos != null
                                                          ? '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}'
                                                          : '위치 확인 중...'));

                                          return Text(
                                            display.replaceAll('\n', ' '),
                                            style: const TextStyle(
                                              color: Colors.grey,
                                              fontSize: 13,
                                            ),
                                            softWrap: true,
                                          );
                                        }),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap:
                            () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => AlarmPage()),
                            ),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6.0),
                          child: SvgPicture.asset(
                            'assets/images/home/alarm.svg',
                            width: 19,
                            height: 21,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 35),

                  // 출근/퇴근 박스
                  Center(
                    child: GestureDetector(
                      onTap: () async {
                        print('🟢 버튼 눌림: $_currentPage');

                        final now = DateTime.now();
                        final time =
                            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

                        if (_currentPage == 0) {
                          // ▶ 출근
                          final pos = LocationController.to.currentLatLng.value;
                          final success =
                              await ApiService.updateAttendanceStatus(
                                "출근",
                                latitude: pos?.latitude,
                                longitude: pos?.longitude,
                              );
                          print('🔁 출근 요청 결과: $success');

                          if (success) {
                            bottomController.isCheckedIn.value = true;
                            bottomController.checkInTime.value = time;
                            bottomController.isCheckedOut.value = false;

                            UserData.workStart = now;
                            UserData.workEnd = null;

                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setString(
                              'work_start_iso',
                              now.toIso8601String(),
                            );
                            await prefs.remove('work_end_iso');

                            LocationSocketService.instance.markHomeEntered();

                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('출근이 등록되었습니다.')),
                              );
                            }
                          } else {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('출근 상태 변경 실패')),
                              );
                            }
                          }
                        } else {
                          // ▶ 퇴근(설문 먼저)
                          if (bottomController.isCheckedIn.value) {
                            setState(() => showSurvey = true);
                          }
                        }
                      },
                      child: Container(
                        height: 90,
                        decoration: BoxDecoration(
                          color: const Color(0xFF61D5AB),
                          borderRadius: BorderRadius.circular(21),
                        ),
                        child: Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20.0,
                                vertical: 14.0,
                              ),
                              child: PageView.builder(
                                controller: _pageController,
                                itemCount: 2,
                                onPageChanged:
                                    (index) =>
                                        setState(() => _currentPage = index),
                                itemBuilder: (context, index) {
                                  return Obx(() {
                                    final String displayName = getShortName(
                                      UserData.name ?? '사용자',
                                    );
                                    String label = '';
                                    String message =
                                        '$displayName님, 오늘 하루도 힘차게 시작해 볼까요?';

                                    if (index == 0) {
                                      label =
                                          bottomController.isCheckedIn.value
                                              ? '출근완료 ${bottomController.checkInTime.value}'
                                              : '출근';
                                    } else {
                                      if (bottomController.isCheckedOut.value) {
                                        label =
                                            '퇴근완료 ${bottomController.checkOutTime.value}';
                                        message =
                                            '$displayName님, 오늘 하루도 고생하셨어요';
                                      } else {
                                        label = '퇴근';
                                      }
                                    }

                                    return Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              message,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              label,
                                              style: const TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: const BoxDecoration(
                                            color: Colors.white,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Image.asset(
                                            'assets/images/home/btncar.png',
                                            width: 35,
                                            height: 35,
                                          ),
                                        ),
                                      ],
                                    );
                                  });
                                },
                              ),
                            ),
                            Positioned(
                              bottom: 8,
                              left: 0,
                              right: 0,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: List.generate(2, (dotIndex) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                    ),
                                    child: Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color:
                                            dotIndex == _currentPage
                                                ? Colors.white
                                                : Colors.white.withOpacity(0.5),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 50),

                  // 오늘의 배송
                  const Text(
                    '오늘의 배송',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Image.asset(
                        'assets/images/home/bus.png',
                        width: 78.68,
                        height: 61,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 11.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RichText(
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: '$completedDeliveries',
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF61D5AB),
                                      ),
                                    ),
                                    TextSpan(
                                      text: ' / $totalDeliveries 건 완료',
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.black,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(50),
                                child: Stack(
                                  children: [
                                    Container(
                                      height: 6,
                                      width: 223,
                                      color: Colors.grey[300],
                                    ),
                                    FractionallySizedBox(
                                      widthFactor:
                                          totalDeliveries > 0
                                              ? completedDeliveries /
                                                  totalDeliveries
                                              : 0,
                                      child: Container(
                                        height: 6,
                                        color: const Color(0xFF61D5AB),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  Expanded(
                    child: ListView.builder(
                      itemCount: deliveryAreas.length,
                      itemBuilder: (context, index) {
                        final area = deliveryAreas[index];

                        final bool notStarted = _isAreaNotStarted(area);
                        final bool inProgress = _isAreaInProgress(area);
                        final bool completed = _isAreaCompleted(area);

                        return Padding(
                          padding: const EdgeInsets.only(
                            bottom: 5.0,
                            left: 10,
                            right: 10,
                          ),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            minLeadingWidth: 0,
                            leading: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color:
                                    inProgress
                                        ? const Color(0xFF61D5AB)
                                        : const Color(0xFFF4F4F4),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Center(
                                child: SvgPicture.asset(
                                  'assets/images/home/marker.svg',
                                  width: 24,
                                  height: 24,
                                  color:
                                      completed
                                          ? const Color(0xFF61D5AB)
                                          : inProgress
                                          ? const Color(0xFFF4F4F4)
                                          : const Color(0xFF171412),
                                ),
                              ),
                            ),
                            title: Text(
                              formatKoreanAddress(area['name']?.toString()),
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              _areaStatusText(area),
                              style: TextStyle(
                                fontSize: 14,
                                color: _areaStatusColor(area),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            trailing: const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(Icons.chevron_right, size: 28),
                            ),
                            onTap: () async {
                              final changed =
                                  await Get.find<BottomNavController>()
                                      .goToDeliveryDetail(area);
                              if (changed == true) {
                                await fetchDeliverySummary();
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showSurvey)
          SurveyModule(
            onSubmit: (finish1, finish2, finish3) async {
              print('📤 설문 제출 시작');

              // ✅ 퇴근 직전: 오늘 총 걸음수 + 오늘 평균 심박수 확보
              final hs = HealthService();
              final int stepsToday = await hs.getTodaySteps();
              final int avgHrToday = await hs.getTodayAverageHeartRate();
              final String cond = UserData.conditionStatus ?? '좋음';

              // (선택) 실시간 전송 1회
              try {
                await ApiService.sendHealthData(
                  step: stepsToday,
                  heartRate: avgHrToday,
                  conditionStatus: cond,
                );
                if (LocationSocketService.instance.isConnected) {
                  await LocationSocketService.instance.sendHealthNow();
                }
              } catch (e) {
                debugPrint('퇴근 직전 건강값 전송 실패: $e');
              }

              // 1) 설문 저장 (걸음/평균심박/컨디션 포함)
              final surveySuccess = await ApiService.submitHealthSurvey(
                finish1: finish1,
                finish2: finish2,
                finish3: finish3,
                step: stepsToday,
                heartRate: avgHrToday,
                conditionStatus: cond,
              );
              if (!surveySuccess) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('설문 제출 실패')));
                }
                return;
              }

              // 2) 근태: 퇴근
              final now = DateTime.now();
              final time =
                  '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

              final pos = LocationController.to.currentLatLng.value;
              final offSuccess = await ApiService.updateAttendanceStatus(
                "퇴근",
                latitude: pos?.latitude,
                longitude: pos?.longitude,
              );
              if (!offSuccess) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('퇴근 상태 변경 실패')));
                }
                return;
              }

              // 3) 로컬/표시 갱신
              UserData.workEnd = now;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('work_end_iso', now.toIso8601String());

              bottomController.isCheckedOut.value = true;
              bottomController.checkOutTime.value = time;

              setState(() {
                _currentPage = 0;
                showSurvey = false;
                bottomController.isCheckedIn.value = false;
                bottomController.checkInTime.value = '';
              });

              bottomController.changeBottomNav(0);
              _pageController.jumpToPage(0);

              // 4) 요약 재조회 → 팝업 트리거
              await fetchDeliverySummary();
            },
            onClose: (_) => setState(() => showSurvey = false),
          ),
      ],
    );
  }
}
