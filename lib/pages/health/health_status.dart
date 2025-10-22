// lib/pages/health/health_page.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shimbox_app/pages/health/health_service.dart';
import 'package:shimbox_app/utils/api_service.dart';
import 'package:shimbox_app/models/test_user_data.dart';

// 건강 데이터 전송은 위치 소켓으로
import 'package:shimbox_app/services/location_socket_service.dart';

// ★ 알림(Alarm)으로 피로도 경고를 보내기 위해 GetX 컨트롤러 사용
import 'package:get/get.dart';
import 'package:shimbox_app/controllers/alarm_controller.dart';
import 'package:shimbox_app/models/alarm/alarm_item.dart';

// ★ 팝업 다이얼로그
import 'package:shimbox_app/pages/health/health_alert_dialog.dart';

class HealthPage extends StatefulWidget {
  const HealthPage({super.key});

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> with WidgetsBindingObserver {
  final _service = HealthService();

  // ── 상태들 ──────────────────────────────────────────────────────────
  String _stepCount = '연동 필요';
  int _stepCountValue = 0;

  String _heartRate = '연동 필요';
  int _heartRateValue = 0;

  bool _isLoadingStep = false;
  bool _isLoadingHeartRate = false;
  bool _isHealthConnected = false;

  DateTime? _lastStepUpdatedAt;
  DateTime? _lastHeartUpdatedAt;

  int _todayDeliveryCount = 0;

  // ── 피로도(동적) ──────────────────────────────────────────────────
  double? _fatigue; // 0~1 score
  String _fatigueLevel = '보통'; // 좋음/보통/주의/위험
  Color _fatigueColorDyn = const Color(0xFF8EC5A8);
  String _fatigueMessageDyn = '무리 없이 진행 중...';

  // 더미 BMI (API 없어서 임시)
  final int _dummyHeightCm = 180;
  final int _dummyWeightKg = 80;

  // 심박 중앙값용 히스토리(최근 N개)
  final List<int> _hrHistory = <int>[];
  static const int _hrHistoryMax = 20;

  // ── 그래프 공통 규격 ───────────────────────────────────────────────
  static const double _barMinPx = 2.0; // 최소 2px
  static const double _barMaxPx = 28.0; // 최대 28px
  static const double _chartAreaHeight = 90.0;

  // 주간 근무 통계(API)
  int? _todayWorkMinutesFromApi; // 오늘 근무 분(서버 또는 로컬 중 큰 값)
  double? _avgDailyWorkMinutesFromApi; // 평일 평균(분)
  List<double> _workBarHeights = const [2, 2, 2, 2, 2];
  final List<String> _workBarLabels = const ['월', '화', '수', '목', '금'];
  bool _workBarsLoaded = false;

  // 배달 건수 마이크로 바 (이번 주 월~금, 오늘만 반영)
  List<double> _deliveryBarHeights = const [2, 2, 2, 2, 2];
  final List<String> _deliveryBarLabels = const ['월', '화', '수', '목', '금'];
  bool _deliveryBarsLoaded = false;

  // 출근 중 로컬 가산 타이머
  Timer? _workTicker;
  static const _workTick = Duration(seconds: 10);

  // 피로도 30분 주기 재계산 타이머
  Timer? _fatigueTicker;
  static const _fatigueTick = Duration(minutes: 10);

  // ── 자동 UI 새로고침 타이머 (걸음/심박/피로도) ─────────────────────
  Timer? _uiRefreshTicker;
  static const _uiRefreshTick = Duration(seconds: 10);

  // ── 피로도 알림/팝업 제어 ─────────────────────────────────────────
  String? _prevFatigueLevel; // 이전 등급 기억
  DateTime? _lastAlarmInsertedAt; // 최근 알림 추가 시각
  static const Duration _alarmDebounce = Duration(minutes: 5);

  // 팝업 디바운스
  DateTime? _lastPopupAt;
  static const Duration _popupDebounce = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();

    _startHealthStreaming();
    _startWorkTickerIfNeeded();
    _startUiRefreshTicker(); // 자동 새로고침 시작

    _startFatigueTicker(); // 피로도 자동 재계산 시작
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startHealthStreaming();
      _startWorkTickerIfNeeded();
      _startUiRefreshTicker(); // 복귀 시 재개
      _startFatigueTicker(); // 포그라운드 복귀 시 재개
    } else {
      _stopHealthStreaming();
      _stopWorkTicker();
      _stopUiRefreshTicker(); // 백그라운드 시 정지
      _stopFatigueTicker(); // 백그라운드 시 정지
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopHealthStreaming();
    _stopWorkTicker();
    _stopUiRefreshTicker();
    _stopFatigueTicker();
    super.dispose();
  }

  // ── 소켓 전송 제어 ────────────────────────────────────────────────
  void _startHealthStreaming() {
    if (!LocationSocketService.instance.isConnected) return;
    LocationSocketService.instance.sendHealthNow();
    LocationSocketService.instance.startHealthPeriodic(
      interval: const Duration(seconds: 30),
    );
  }

  void _stopHealthStreaming() {
    LocationSocketService.instance.stopHealthPeriodic();
  }

  // ── 로컬 근무 세션 복구 ──────────────────────────────────────────
  Future<void> _restoreLocalWorkSessionFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString('work_start_iso');
      final e = prefs.getString('work_end_iso');
      if (s != null && s.isNotEmpty && UserData.workStart == null) {
        UserData.workStart = DateTime.tryParse(s);
      }
      if (e != null && e.isNotEmpty) {
        UserData.workEnd = DateTime.tryParse(e);
      }
      _startWorkTickerIfNeeded();
    } catch (_) {}
  }

  // ── 로컬 근무시간 가산 타이머 ─────────────────────────────────────
  void _startWorkTickerIfNeeded() {
    if (UserData.workStart != null && UserData.workEnd == null) {
      _workTicker ??= Timer.periodic(_workTick, (_) => _refreshLocalWorkNow());
      _refreshLocalWorkNow();
    }
  }

  void _stopWorkTicker() {
    _workTicker?.cancel();
    _workTicker = null;
  }

  void _refreshLocalWorkNow() {
    if (!mounted) return;
    if (UserData.workStart == null) return;

    final end = UserData.workEnd ?? DateTime.now();
    final localMinutes = end.difference(UserData.workStart!).inMinutes;
    if (localMinutes < 0) return;

    setState(() {
      if (_todayWorkMinutesFromApi == null ||
          localMinutes > _todayWorkMinutesFromApi!) {
        _todayWorkMinutesFromApi = localMinutes;
      }
    });
  }

  // ── 자동 새로고침 구현(조용히 갱신) ───────────────────────────────
  void _startUiRefreshTicker() {
    _uiRefreshTicker ??= Timer.periodic(
      _uiRefreshTick,
      (_) => _autoRefreshHealth(),
    );
  }

  void _stopUiRefreshTicker() {
    _uiRefreshTicker?.cancel();
    _uiRefreshTicker = null;
  }

  Future<void> _autoRefreshHealth() async {
    if (!_isHealthConnected || !mounted) return;
    await _fetchStepCount(silent: true);
    await _fetchHeartRate(silent: true);
    await _sendHealthToServer();
    await _computeAndRenderFatigue();
  }

  // ── 피로도 30분 주기 ─────────────────────────────────────────────
  void _startFatigueTicker() {
    _fatigueTicker ??= Timer.periodic(
      _fatigueTick,
      (_) => _computeAndRenderFatigue(),
    );
    _computeAndRenderFatigue(); // 최초 1회 즉시 계산
  }

  void _stopFatigueTicker() {
    _fatigueTicker?.cancel();
    _fatigueTicker = null;
  }

  // ── 부팅 시 데이터 로딩 ───────────────────────────────────────────
  Future<void> _boot() async {
    await _restoreLocalWorkSessionFromPrefs(); // ★ 로컬 세션 복구
    await _checkHealthConnection();
    await _maybeAutoPromptHealthConnect();
    await _resetWorkSessionIfEmpty(); // 이번 주 0이면 로컬세션 초기화
    await _fetchDeliveryCount(); // 오늘 건수 + 배달 그래프
    await _fetchWeeklyWorkStats(); // 근무시간 + 근무 그래프
  }

  /// 이번 주(月~金) 모든 일자 근무가 0분이면 로컬 세션 초기화
  Future<void> _resetWorkSessionIfEmpty() async {
    try {
      final stats = await ApiService.fetchWeeklyWorkStats();

      final now = DateTime.now();
      final weekStart = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: now.weekday - 1)); // 월
      final weekEnd = weekStart.add(const Duration(days: 4)); // 금

      final hasWorkThisWeek = stats.dailyStats.any((d) {
        final only = DateTime(d.date.year, d.date.month, d.date.day);
        final inWeek = !only.isBefore(weekStart) && !only.isAfter(weekEnd);
        return inWeek && d.workMinutes > 0;
      });

      if (!hasWorkThisWeek) {
        if (!mounted) return;
        setState(() {
          UserData.workStart = null;
          UserData.workEnd = null;
          _todayWorkMinutesFromApi = 0;
        });
        _stopWorkTicker();
        debugPrint('[Work] 이번 주 근무 0분 → 로컬 근무 세션 초기화');
      } else {
        debugPrint('[Work] 이번 주에 근무 데이터 있음 → 초기화 스킵');
      }
    } catch (e) {
      debugPrint('[Work] 초기화 확인 실패: $e');
    }
  }

  Future<void> _refreshAllAndSendOnce() async {
    await _fetchStepCount();
    await _fetchHeartRate();
    await _sendHealthToServer();
    if (LocationSocketService.instance.isConnected) {
      await LocationSocketService.instance.sendHealthNow();
    }
  }

  // ── 오늘 배달 건수 + 배달 그래프(마이크로) ───────────────────────
  Future<void> _fetchDeliveryCount() async {
    try {
      final data = await ApiService.fetchDeliverySummary();
      int count = 0;
      for (final area in data) {
        count += (area['completedCount'] ?? 0) as int;
      }

      // 마이크로 바: 이번 주 월~금, 오늘 요일만 (2px + 건수), 나머지는 2px
      final List<double> bars = List<double>.filled(5, _barMinPx);
      final wd = DateTime.now().weekday; // Mon=1..Sun=7
      if (wd >= 1 && wd <= 5) {
        final todayH = (_barMinPx + count).clamp(_barMinPx, _barMaxPx);
        bars[wd - 1] = todayH;
      }

      if (!mounted) return;
      setState(() {
        _todayDeliveryCount = count;
        _deliveryBarHeights = bars;
        _deliveryBarsLoaded = true;
      });

      // 갱신 시 피로도 즉시 재계산
      await _computeAndRenderFatigue();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _todayDeliveryCount = 0;
        _deliveryBarHeights = const [2, 2, 2, 2, 2];
        _deliveryBarsLoaded = true;
      });
    }
  }

  // ── 주간 근무 통계 (이번 주 월~금만) ──────────────────────────────
  Future<void> _fetchWeeklyWorkStats() async {
    setState(() {
      _workBarsLoaded = false;
    });

    try {
      final stats = await ApiService.fetchWeeklyWorkStats();

      final now = DateTime.now();
      final weekStart = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: now.weekday - 1)); // 월
      final weekEnd = weekStart.add(const Duration(days: 4)); // 금

      final Map<int, int> minutesByWeekday = {1: 0, 2: 0, 3: 0, 4: 0, 5: 0};

      for (final d in stats.dailyStats) {
        final only = DateTime(d.date.year, d.date.month, d.date.day);
        if (only.isBefore(weekStart) || only.isAfter(weekEnd)) continue;
        final wd = only.weekday;
        if (wd >= 1 && wd <= 5) {
          minutesByWeekday[wd] = (minutesByWeekday[wd] ?? 0) + d.workMinutes;
        }
      }

      final minutesList = [
        minutesByWeekday[1]!,
        minutesByWeekday[2]!,
        minutesByWeekday[3]!,
        minutesByWeekday[4]!,
        minutesByWeekday[5]!,
      ];

      // 스케일: 모두 0이면 480분(8시간)을 기준으로
      final maxM = minutesList.fold<int>(0, (m, v) => v > m ? v : m);
      final scaleBase = (maxM > 0) ? maxM : 480;

      final bars =
          minutesList.map((m) {
            if (m <= 0) return _barMinPx;
            final h = (m / scaleBase) * _barMaxPx;
            return h.clamp(_barMinPx, _barMaxPx);
          }).toList();

      // 오늘 분(서버값)
      int todayM = 0;
      final todayKey = DateTime(now.year, now.month, now.day);
      for (final d in stats.dailyStats) {
        final key = DateTime(d.date.year, d.date.month, d.date.day);
        if (key == todayKey) todayM += d.workMinutes;
      }

      if (!mounted) return;
      setState(() {
        final localNow = _calcLocalMinutes();
        int chosen = todayM;
        if (localNow != null && localNow > chosen) {
          chosen = localNow;
        }

        _todayWorkMinutesFromApi = chosen; // max(server, local)
        _avgDailyWorkMinutesFromApi = stats.averageDailyWorkMinutes;
        _workBarHeights = bars;
        _workBarsLoaded = true;
      });

      // 갱신 시 피로도 즉시 재계산
      await _computeAndRenderFatigue();
    } catch (e) {
      debugPrint('fetchWeeklyWorkStats error: $e');
      if (!mounted) return;
      setState(() {
        _workBarHeights = const [2, 2, 2, 2, 2];
        _workBarsLoaded = true;
      });
    }
  }

  int? _calcLocalMinutes() {
    if (UserData.workStart == null) return null;
    final end = UserData.workEnd ?? DateTime.now();
    final m = end.difference(UserData.workStart!).inMinutes;
    return m < 0 ? 0 : m;
  }

  // ── 표시 유틸 ────────────────────────────────────────────────────
  String _formattedDate() {
    final now = DateTime.now();
    const weekdayKor = ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'];
    final formatted = DateFormat('yy.MM.dd').format(now);
    return '$formatted ${weekdayKor[now.weekday - 1]}';
  }

  String _recencyText(DateTime? when) {
    if (when == null) return '데이터 없음';
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return '방금 전';
    if (diff.inHours < 1) return '최근 ${diff.inMinutes}분 전';
    if (diff.inHours < 24) return '최근 ${diff.inHours}시간 전';
    return DateFormat('MM/dd HH:mm').format(when);
  }

  // ── UI ───────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 39, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 25),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _formattedDate(),
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 40),
                        Text(
                          '${UserData.name ?? '사용자'}님의 건강 리포트',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 1),
                  ],
                ),

                const SizedBox(height: 15),

                // 피로도 카드 (동적)
                Row(
                  children: [
                    Container(
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        color: _fatigueColorDyn,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            '예상 피로도',
                            style: TextStyle(fontSize: 12, color: Colors.white),
                          ),
                          Text(
                            _fatigueLevel,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _fatigueMessageDyn,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 25),

                Row(
                  children: [
                    Expanded(
                      child: _healthCard(
                        iconPath: 'assets/images/health/chart.svg',
                        title: '걸음 수',
                        value: _isLoadingStep ? '...' : _stepCount,
                        sub:
                            _isHealthConnected
                                ? _recencyText(_lastStepUpdatedAt)
                                : '연동 필요',
                        subColor:
                            _isHealthConnected ? null : const Color(0xFF61D5AB),
                        isLoading: _isLoadingStep,
                        onRefresh:
                            _isHealthConnected ? () => _fetchStepCount() : null,
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 68,
                      color: const Color(0xFFE3E3E3),
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    Expanded(
                      child: _healthCard(
                        iconPath: 'assets/images/health/heart.svg',
                        title: '심박수',
                        value: _isLoadingHeartRate ? '...' : _heartRate,
                        sub:
                            _isHealthConnected
                                ? (_heartRate == '데이터 없음' || _heartRate == '오류'
                                    ? '데이터 없음'
                                    : _recencyText(_lastHeartUpdatedAt))
                                : '연동 필요',
                        subColor:
                            _isHealthConnected ? null : const Color(0xFF61D5AB),
                        isLoading: _isLoadingHeartRate,
                        onRefresh:
                            _isHealthConnected ? () => _fetchHeartRate() : null,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 28),

                // 근무시간
                _metricCardWithBarChart(
                  iconPath: 'assets/images/health/time.svg',
                  title: '근무시간',
                  value: workTime,
                  subtitle: workTimeSub,
                  barHeights:
                      _workBarsLoaded ? _workBarHeights : const [2, 2, 2, 2, 2],
                  barLabels: _workBarLabels,
                ),

                const SizedBox(height: 40),

                // 배달 건수
                _metricCardWithBarChart(
                  iconPath: 'assets/images/health/delivery.svg',
                  title: '배달 건수',
                  value: deliveryCount,
                  subtitle: deliverySub,
                  barHeights:
                      _deliveryBarsLoaded
                          ? _deliveryBarHeights
                          : const [2, 2, 2, 2, 2],
                  barLabels: _deliveryBarLabels,
                  subtitleColor: const Color(0xFF61D5AB),
                  iconWidth: 23,
                  iconHeight: 23,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 표시용 Getter ────────────────────────────────────────────────
  String get workTime {
    if (_todayWorkMinutesFromApi != null) {
      final m = _todayWorkMinutesFromApi!.clamp(0, 24 * 60);
      final h = m ~/ 60;
      final mm = m % 60;
      return '${h}시간 ${mm}분';
    }
    final local = _calcLocalMinutes();
    if (local != null) {
      final h = local ~/ 60;
      final mm = local % 60;
      return '${h}시간 ${mm}분';
    }
    return '정보 없음';
  }

  String get workTimeSub {
    if (_avgDailyWorkMinutesFromApi != null) {
      final avgMin = _avgDailyWorkMinutesFromApi!.round();
      final h = avgMin ~/ 60;
      final mm = avgMin % 60;
      if (mm == 0) return '주간 평균 ${h}시간';
      return '주간 평균 ${h}시간 ${mm}분';
    }
    if ((UserData.weeklyWorkAvgHours ?? 0) > 0) {
      return '주간 평균 ${UserData.weeklyWorkAvgHours}시간';
    }
    return '주간 평균 0시간';
  }

  String get deliveryCount => '$_todayDeliveryCount건';

  String get deliverySub {
    final today = _todayDeliveryCount;
    const avg = 0;
    final diff = today - avg;
    final sign = diff >= 0 ? '+' : '';
    return '평균 대비 $sign$diff건';
  }

  // ── 공통 카드 위젯들 ─────────────────────────────────────────────
  Widget _healthCard({
    required String iconPath,
    required String title,
    required String value,
    required String sub,
    Color? subColor,
    bool isLoading = false,
    VoidCallback? onRefresh,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SvgPicture.asset(
              iconPath,
              width: 20,
              height: 20,
              colorFilter: const ColorFilter.mode(
                Color(0xFF61D5AB),
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            if (onRefresh != null)
              IconButton(
                icon: Image.asset('assets/images/health/reload.png', width: 15),
                onPressed: isLoading ? null : onRefresh,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              ),
          ],
        ),
        const SizedBox(height: 10),
        isLoading
            ? const CircularProgressIndicator(color: Color(0xFF61D5AB))
            : Text(
              value,
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
        const SizedBox(height: 8),
        Text(
          sub,
          style: TextStyle(fontSize: 17, color: subColor ?? Colors.grey),
        ),
      ],
    );
  }

  Widget _metricCardWithBarChart({
    required String iconPath,
    required String title,
    required String value,
    required String subtitle,
    required List<double> barHeights,
    required List<String> barLabels,
    Color? subtitleColor,
    double iconWidth = 20,
    double iconHeight = 20,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 제목줄
        Row(
          children: [
            SvgPicture.asset(
              iconPath,
              width: iconWidth,
              height: iconHeight,
              colorFilter: const ColorFilter.mode(
                Color(0xFF61D5AB),
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // 본문
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 왼쪽 텍스트 묶음
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 14,
                      color: subtitleColor ?? Colors.grey,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),

            // 오른쪽 고정 높이 그래프
            SizedBox(
              height: _chartAreaHeight,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(barHeights.length, (index) {
                    final h = barHeights[index].clamp(_barMinPx, _barMaxPx);
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Container(
                            width: 20,
                            height: h,
                            decoration: BoxDecoration(
                              color: const Color(0xFF61D5AB),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            barLabels[index],
                            style: const TextStyle(fontSize: 9),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── 웨어러블 연결/해제 다이얼로그 ──────────────────────────────────
  Future<void> _tryConnectHealthService() async {
    if (_isHealthConnected) {
      final shouldDisconnect = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('연동 해제'),
              content: const Text('웨어러블 연동을 해제하시겠습니까?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('취소'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('해제'),
                ),
              ],
            ),
      );
      if (shouldDisconnect == true) {
        await _service.disconnect();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('health_connected', false);
        if (!mounted) return;
        setState(() {
          _isHealthConnected = false;
          _stepCount = '연동 필요';
          _heartRate = '연동 필요';
        });
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('웨어러블 연동이 해제되었습니다.')));
        }
      }
      return;
    }

    setState(() {
      _isLoadingStep = true;
      _isLoadingHeartRate = true;
    });
    final ok = await _service.connect();
    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('health_prompted_once', true);
    await prefs.setBool('health_connected', ok);

    setState(() {
      _isLoadingStep = false;
      _isLoadingHeartRate = false;
      _isHealthConnected = ok;
    });

    if (ok) {
      setState(() {
        _stepCount = '...';
        _heartRate = '...';
      });
      await _refreshAllAndSendOnce();
      _startHealthStreaming();
      _startUiRefreshTicker(); // 연결 시 자동 새로고침 보장
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Health Connect 권한을 허용해 주세요.')),
        );
      }
    }
  }

  // ── 걸음/심박 불러오기 ────────────────────────────────────────────
  Future<void> _fetchStepCount({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoadingStep = true;
        _stepCount = '...';
      });
    }

    try {
      final today = await _service.getTodaySteps();
      if (!mounted) return;
      setState(() {
        _stepCountValue = today;
        _stepCount = today.toString();
        _lastStepUpdatedAt = DateTime.now();
        UserData.stepCount = today;
      });

      // 갱신 시 피로도 즉시 재계산
      await _computeAndRenderFatigue();

      if (LocationSocketService.instance.isConnected) {
        await LocationSocketService.instance.sendHealthNow();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stepCount = '오류';
        _lastStepUpdatedAt = null;
      });
      if (mounted && !silent) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('걸음 수 가져오기 실패: $e')));
      }
    } finally {
      if (mounted && !silent) setState(() => _isLoadingStep = false);
    }
  }

  Future<void> _fetchHeartRate({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoadingHeartRate = true;
        _heartRate = '...';
      });
    }

    try {
      final hr = await _service.getCurrentHeartRate();
      if (!mounted) return;
      setState(() {
        _heartRateValue = hr;
        _heartRate = hr > 0 ? '$hr bpm' : '데이터 없음';
        _lastHeartUpdatedAt = DateTime.now();
        UserData.heartRate = hr;
      });

      // 심박 히스토리에 누적 + 즉시 재계산
      _pushHr(hr);
      await _computeAndRenderFatigue();

      if (LocationSocketService.instance.isConnected) {
        await LocationSocketService.instance.sendHealthNow();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _heartRate = '오류';
        _lastHeartUpdatedAt = null;
      });
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('심박수 데이터를 불러오는 데 실패했어요.\nHealth Connect 권한을 확인해주세요.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted && !silent) setState(() => _isLoadingHeartRate = false);
    }
  }

  // ── 연결 상태 확인 + 권유 ─────────────────────────────────────────
  Future<void> _checkHealthConnection() async {
    final prefs = await SharedPreferences.getInstance();
    final isConnected = prefs.getBool('health_connected') ?? false;
    if (!mounted) return;
    setState(() => _isHealthConnected = isConnected);

    if (isConnected) {
      await _refreshAllAndSendOnce();
      _startUiRefreshTicker(); // 연결 시 자동 새로고침 보장
    } else {
      setState(() {
        _stepCount = '연동 필요';
        _heartRate = '연동 필요';
      });
    }
  }

  Future<void> _maybeAutoPromptHealthConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final promptedOnce = prefs.getBool('health_prompted_once') ?? false;
    if (_isHealthConnected || promptedOnce) return;

    setState(() {
      _isLoadingStep = true;
      _isLoadingHeartRate = true;
    });

    final ok = await _service.connect();
    await prefs.setBool('health_prompted_once', true);

    if (!mounted) return;

    setState(() {
      _isHealthConnected = ok;
      _isLoadingStep = false;
      _isLoadingHeartRate = false;
    });

    if (ok) {
      setState(() {
        _stepCount = '...';
        _heartRate = '...';
      });
      await _refreshAllAndSendOnce();
      _startHealthStreaming();
      _startUiRefreshTicker(); // 연결 시 자동 새로고침 보장
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Health Connect 권한을 허용해 주세요.')),
        );
      }
    }
  }

  // ── 서버로 건강 데이터 전송 ───────────────────────────────────────
  Future<void> _sendHealthToServer() async {
    if (_stepCountValue > 0 && _heartRateValue > 0) {
      UserData.conditionStatus = '좋음';
      await ApiService.sendHealthData(
        step: _stepCountValue,
        heartRate: _heartRateValue,
        conditionStatus: UserData.conditionStatus,
      );
    }
  }

  // ── 피로도 계산 유틸 ─────────────────────────────────────────────
  double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

  // 등급 → 심각도(숫자) 매핑
  int _levelToSeverity(String level) {
    switch (level) {
      case '좋음':
        return 0;
      case '보통':
        return 1;
      case '주의':
        return 2;
      case '위험':
        return 3;
      default:
        return 1;
    }
  }

  // 알림 텍스트 템플릿
  Map<String, String> _alarmTextForLevel(String level, double score) {
    switch (level) {
      case '주의':
        return {'title': '피로도 주의 상태입니다.', 'subtitle': '잠깐 스트레칭/수분 섭취 권장'};
      case '위험':
        return {
          'title': '피로도 위험 상태! 휴식이 필요합니다.',
          'subtitle': '무리 금지, 즉시 휴식 권장',
        };
      default:
        return {'title': '', 'subtitle': ''};
    }
  }

  // 알림 추가 헬퍼(AlarmController 통해 리스트에 누적)
  void _pushAlarmItem(String title, String subtitle) {
    try {
      if (!Get.isRegistered<AlarmController>()) {
        debugPrint('[Alarm] AlarmController not registered.');
        return;
      }
      final ctrl = Get.find<AlarmController>();
      ctrl.addAlarm(AlarmItem(title: title, subtitle: subtitle));
      debugPrint('[Alarm] Added: $title | $subtitle');
    } catch (e) {
      debugPrint('[Alarm] Failed to add: $e');
    }
  }

  // 팝업 띄우기: 상향 시, 포그라운드 & 현재화면 & 디바운스
  Future<void> _maybeShowFatiguePopup(String level, double score) async {
    if (!(level == '주의' || level == '위험')) return;

    final now = DateTime.now();
    final canPopup =
        _lastPopupAt == null || now.difference(_lastPopupAt!) >= _popupDebounce;

    final appState = WidgetsBinding.instance.lifecycleState;
    final inForeground = appState == AppLifecycleState.resumed;
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;

    if (!mounted || !inForeground || !isCurrent || !canPopup) return;

    final t = _alarmTextForLevel(level, score);
    final color =
        (level == '위험') ? const Color(0xFFEE404C) : const Color(0xFFFFC069);

    _lastPopupAt = now;
    await HealthAlertDialog.show(
      context,
      title: t['title'] ?? '',
      subtitle: t['subtitle'] ?? '',
      warningColor: color,
    );
  }

  void _applyFatigueView(double s) {
    String lvl;
    Color col;
    String msg;
    if (s < 0.25) {
      lvl = '좋음';
      col = const Color(0xFF61D5AB);
      msg = '컨디션이 좋아요.';
    } else if (s < 0.50) {
      lvl = '보통';
      col = const Color(0xFF8EC5A8);
      msg = '무리 없이 진행 중.';
    } else if (s < 0.75) {
      lvl = '주의';
      col = const Color(0xFFFFC069);
      msg = '잠깐 스트레칭/물 섭취 권장.';
    } else {
      lvl = '위험';
      col = const Color(0xFFFF8A8A);
      msg = '휴식 필요! 무리 금지.';
    }

    debugPrint('[Fatigue] score=${s.toStringAsFixed(3)}, level=$lvl');

    if (!mounted) return;
    setState(() {
      _fatigue = s;
      _fatigueLevel = lvl;
      _fatigueColorDyn = col;
      _fatigueMessageDyn = msg;
    });

    // ★ 등급 상향 감지 → 알림 추가(디바운스, 단 "위험"은 즉시 허용) + 팝업
    final newLevel = lvl;
    final prev = _prevFatigueLevel;
    final newSev = _levelToSeverity(newLevel);
    final prevSev = prev == null ? -1 : _levelToSeverity(prev);
    final isEscalation = newSev > prevSev;

    final now = DateTime.now();
    final canInsert =
        _lastAlarmInsertedAt == null ||
        now.difference(_lastAlarmInsertedAt!) >= _alarmDebounce;

    if (isEscalation && (canInsert || newLevel == '위험')) {
      final t = _alarmTextForLevel(newLevel, s);
      if (t['title']!.isNotEmpty) {
        _pushAlarmItem(t['title']!, t['subtitle']!);
        _lastAlarmInsertedAt = now;

        // 팝업도 함께
        _maybeShowFatiguePopup(newLevel, s);
      }
    }
    _prevFatigueLevel = newLevel;
  }

  void _pushHr(int hr) {
    if (hr <= 0) return;
    _hrHistory.add(hr);
    if (_hrHistory.length > _hrHistoryMax) {
      _hrHistory.removeAt(0);
    }
  }

  int _baselineHr() {
    final vals = _hrHistory.where((e) => e > 0).toList()..sort();
    if (vals.isNotEmpty) {
      final med = vals[vals.length ~/ 2];
      return math.max(60, med); // 과도 저심박 방지
    }
    if (_heartRateValue > 0) {
      return math.max(60, (_heartRateValue * 0.85).round());
    }
    return 60;
  }

  Future<void> _computeAndRenderFatigue() async {
    try {
      final workMin = (_todayWorkMinutesFromApi ?? _calcLocalMinutes() ?? 0)
          .clamp(0, 24 * 60);
      final steps = _stepCountValue;
      final currentHR = _heartRateValue;
      final deliveries = _todayDeliveryCount;

      final baseline = _baselineHr();
      final delta = currentHR > 0 ? (currentHR - baseline) : 0;
      final inc =
          currentHR > 0
              ? (currentHR - baseline) /
                  (baseline <= 0 ? 1.0 : baseline.toDouble())
              : 0.0;

      // ── HR 컴포넌트 (매우 민감하게 조정) ───────────────────────────
      // 2%↑부터 가점, 12%↑면 만점 수준
      double hrSlope = _clamp01((inc - 0.02) / 0.10);

      // 새 임계치 부스트: 기준선 대비 +10bpm 이상이면 사실상 '위험'
      // +20bpm 이상 또는 HR≥110은 즉시 최댓값
      double hrBoost = 0.0;
      final bool severeDelta = delta >= 20 || currentHR >= 110;
      final bool acuteDelta = delta >= 10; // ← 요청: +10~20만 상승해도 위험
      if (severeDelta) {
        hrBoost = 1.0; // 강한 위험
      } else if (acuteDelta) {
        hrBoost = 0.90; // 위험 경계 넘도록 강한 부스트
      }
      final hrComp = math.max(hrSlope, hrBoost);

      final workComp = _clamp01((workMin - 180) / (600 - 180)); // 3h→0, 10h→1
      final delivComp = _clamp01(deliveries / 120.0); // 0~120건
      final stepsComp = _clamp01((steps - 3000) / (15000 - 3000)); // 3k~15k

      // 더미 BMI (180/80)
      final bmi = _dummyWeightKg / math.pow(_dummyHeightCm / 100.0, 2);
      final bmiPenalty = _clamp01((bmi - 25.0) / (27.0 - 25.0)); // 25~27 → 0~1

      double score =
          0.55 * hrComp +
          0.20 * workComp +
          0.10 * delivComp +
          0.10 * stepsComp +
          0.05 * bmiPenalty;

      // 급격한 심박 상승(+10bpm↑)은 무조건 '위험' 임계(0.75)를 넘기도록 보정
      if (acuteDelta) {
        score = math.max(score, 0.80);
      } else if (severeDelta) {
        score = math.max(score, 0.90);
      }

      _applyFatigueView(_clamp01(score));
    } catch (e) {
      debugPrint('[Fatigue] compute failed: $e');
      _applyFatigueView(0.4); // 안전 기본값
    }
  }
}
