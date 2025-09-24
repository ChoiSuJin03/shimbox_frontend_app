import 'package:shimbox_app/pages/alarm/alarm.dart';
import 'package:shimbox_app/controllers/location_controller.dart';

import 'survey_module.dart';

import 'package:shimbox_app/models/adjusted_volume_dialog.dart'; // TODO(임시 미리보기): 나중에 삭제 가능
import 'package:shimbox_app/controllers/alarm_controller.dart'; // TODO(임시 미리보기)
import 'package:shimbox_app/models/alarm/alarm_item.dart'; // TODO(임시 미리보기)

// 기존 import 유지
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:shimbox_app/controllers/bottom_nav_controller.dart';
import '../delivery/delivery_detail.dart';
import 'package:shimbox_app/models/test_user_data.dart';
import 'package:shimbox_app/utils/api_service.dart';

class HomePage extends StatefulWidget {
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final BottomNavController bottomController;

  List<Map<String, dynamic>> deliveryAreas = []; // ✅ API 연동으로 대체됨

  int totalDeliveries = 0;
  int completedDeliveries = 0;

  final PageController _pageController = PageController();

  int _currentPage = 0;
  bool showSurvey = false;

  // final bottomController = Get.find<BottomNavController>();

  @override
  void initState() {
    super.initState();
    fetchDeliverySummary();

    // ✅ 현재 위치 추적 시작 (권한 요청 포함)
    // 앱 최초 진입 시 한 번만 호출되어도 됨 (main에서 호출했다면 생략 가능)
    LocationController.to.startTracking();

    bottomController = Get.find<BottomNavController>();
  }

  Future<void> fetchDeliverySummary() async {
    try {
      final data = await ApiService.fetchDeliverySummary();
      int total = 0;
      int completed = 0;

      // "서울특별시 성북구" 처럼 구 단위로 정규화
      String normalizeToGu(String? raw) {
        if (raw == null) return '';
        final s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
        return formatKoreanAddress(s); // 이미 파일에 있는 함수: 시/도 + 구 까지만 남김
      }

      // 구 단위로 합산
      final Map<String, Map<String, int>> buckets = {};
      for (final area in data) {
        final key = normalizeToGu(area['shippingLocation']?.toString());
        final int t = (area['totalCount'] ?? 0).toInt();
        final int c = (area['completedCount'] ?? 0).toInt();

        final slot = buckets.putIfAbsent(
          key,
          () => {'total': 0, 'completed': 0},
        );
        slot['total'] = (slot['total'] ?? 0) + t;
        slot['completed'] = (slot['completed'] ?? 0) + c;

        total += t;
        completed += c;
      }

      final areas =
          buckets.entries
              .map(
                (e) => {
                  'name': e.key, // ← 리스트 아이템에서 그대로 사용
                  'total': e.value['total']!,
                  'completed': e.value['completed']!,
                },
              )
              .toList()
            ..sort(
              (a, b) => (a['name'] as String).compareTo(b['name'] as String),
            );

      setState(() {
        deliveryAreas = areas;
        totalDeliveries = total;
        completedDeliveries = completed;
      });
    } catch (e) {
      print('❌ 배송 요약 불러오기 실패: $e');
    }
  }

  String getShortName(String fullName) {
    if (fullName.length <= 2) return fullName;
    return fullName.substring(fullName.length - 2);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // =========================
  // ✅ 진행률/상태 텍스트 & 색상
  // =========================
  String _areaStatusText(Map<String, dynamic> area) {
    final int total = (area['total'] ?? 0);
    final int done = (area['completed'] ?? 0);
    if (total == 0) return '0 / 0건 미완료';
    if (done == 0) return '0 / $total건 미완료';
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
    if (total > 0 && done >= total) return const Color(0xFF61D5AB); // 완료 → 초록
    if (done == 0) return Colors.grey; // 미완료 → 회색
    return const Color(0xFF747474); // 진행중 → 진한 회색
  }

  // ✅ 추가: "진행 중.." 여부 (0 < done < total)
  bool _isAreaInProgress(Map<String, dynamic> area) {
    final int total = (area['total'] ?? 0);
    final int done = (area['completed'] ?? 0);
    return total > 0 && done > 0 && done < total;
  }

  // ✅ 추가: "완료" 여부 (done >= total)
  bool _isAreaCompleted(Map<String, dynamic> area) {
    final int total = (area['total'] ?? 0);
    final int done = (area['completed'] ?? 0);
    return total > 0 && done >= total;
  }
  // =========================

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: const Text('물량 조정 팝업 미리보기'),
            actions: [
              IconButton(
                tooltip: '팝업 띄우기(임시)',
                icon: const Icon(Icons.notification_important_outlined),
                onPressed: () async {
                  const int before = 300;
                  const int after = 230;

                  await AdjustedVolumeDialog.show(
                    context,
                    title: '건강 상태를 고려해 오늘 배송물량이',
                    titleLine2: '조정 되었습니다.',
                    description: '무리 없이 일하실 수 있도록',
                    before: before,
                    after: after,
                    iconColor: const Color(0xFF61D5AB),
                    width: 340,
                  );

                  final alarm = Get.find<AlarmController>();
                  alarm.addAlarm(
                    AlarmItem(
                      title: '배송물량이 조정되었습니다.',
                      subtitle: '$before → $after건',
                    ),
                  );
                },
              ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 38),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 유저 정보 영역 -------------------------------------------------
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
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
                          Column(
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
                                children: [
                                  SvgPicture.asset(
                                    'assets/images/home/marker.svg',
                                    width: 17,
                                    height: 17,
                                    color: Colors.grey,
                                  ),
                                  const SizedBox(width: 5),
                                  // ✅ DB 주소 대신 현재 위치 주소 (LocationController)
                                  Obx(() {
                                    final raw =
                                        LocationController
                                            .to
                                            .currentShortAddress
                                            .value;
                                    final pos =
                                        LocationController
                                            .to
                                            .currentLatLng
                                            .value;
                                    final display =
                                        raw.isNotEmpty
                                            ? formatKoreanAddress(raw)
                                            : (pos != null
                                                ? '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}'
                                                : '위치 확인 중...');
                                    return Text(
                                      display,
                                      style: const TextStyle(
                                        color: Colors.grey,
                                        fontSize: 13,
                                      ),
                                    );
                                  }),
                                ],
                              ),
                            ],
                          ),
                        ],
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

                  // 출근/퇴근 박스 -------------------------------------------------
                  Center(
                    child: GestureDetector(
                      onTap: () async {
                        print('🟢 버튼 눌림: $_currentPage');

                        final now = DateTime.now();
                        final time =
                            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

                        if (_currentPage == 0) {
                          final success =
                              await ApiService.updateAttendanceStatus("출근");
                          print('🔁 출근 요청 결과: $success');
                          if (success) {
                            bottomController.isCheckedIn.value = true;
                            bottomController.checkInTime.value = time;
                            bottomController.isCheckedOut.value = false;
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('출근 상태 변경 실패')),
                            );
                          }
                        } else {
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

                  // 오늘의 배송 ----------------------------------------------------
                  const Text(
                    '오늘의 배송',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),

                  // 배송 상태(전체)
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

                  // 배송 목록 (지역별 진행 상태 표시) -------------------------------
                  Expanded(
                    child: ListView.builder(
                      itemCount: deliveryAreas.length,
                      itemBuilder: (context, index) {
                        final area = deliveryAreas[index];

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
                                      inProgress
                                          ? Colors.white
                                          : (completed
                                              ? const Color(0xFF61D5AB)
                                              : const Color(0xFF171412)),
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

              final dummySuccess = await ApiService.createDummyHealthRecord();
              if (!dummySuccess) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('건강 데이터 생성 실패')));
                }
                return;
              }

              final surveySuccess = await ApiService.submitHealthSurvey(
                finish1: finish1,
                finish2: finish2,
                finish3: finish3,
                step: UserData.stepCount ?? 0,
                heartRate: UserData.heartRate ?? 0,
                conditionStatus: UserData.conditionStatus ?? '미정',
              );

              if (!surveySuccess) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('설문 제출 실패')));
                }
                return;
              }

              final now = DateTime.now();
              final time =
                  '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

              final offSuccess = await ApiService.updateAttendanceStatus("퇴근");
              if (!offSuccess) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('퇴근 상태 변경 실패')));
                }
                return;
              }

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
            },
            onClose: (_) {
              setState(() => showSurvey = false);
            },
          ),
      ],
    );
  }
}
