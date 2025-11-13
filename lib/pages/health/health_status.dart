// (생략 없이 원문 전체 붙임, 변경 라인에만 주석 표시)
import 'dart:async';
import 'dart:convert'; // ★ 낙상 JSON 파싱
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // ★ EventChannel 사용
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

// ★ 피로도 경고 팝업(기존)
import 'package:shimbox_app/pages/health/health_alert_dialog.dart';

// ★ 낙상 감지 전용 커스텀 다이얼로그 (X 버튼 + 빨간 타이틀 + ‘위험’ 배지)
import 'package:shimbox_app/pages/health/fall_detected_dialog.dart';

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
  String _fatigueLevel = '좋음'; // 좋음/경고/위험
  Color _fatigueColorDyn = const Color(0xFF61D5AB); // green
  String _fatigueMessageDyn =
      '컨디션이 좋아요. 평소 페이스로 진행하세요.\n수분 보충과 가벼운 스트레칭을 이어가면 좋아요.';

  // ▲ BMI용 키/몸무게 (API로 로드)
  int? _heightCm;
  int? _weightKg;

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

  // 피로도 10분 주기 재계산 타이머 (폴백/보강용)
  Timer? _fatigueTicker;
  static const _fatigueTick = Duration(minutes: 10);

  // ── 피로도 알림/팝업 제어 ─────────────────────────────────────────
  String? _prevFatigueLevel; // 이전 등급 기억
  DateTime? _lastAlarmInsertedAt; // 최근 알림 추가 시각
  static const Duration _alarmDebounce = Duration(minutes: 5);

  // 팝업 디바운스
  DateTime? _lastPopupAt;
  static const Duration _popupDebounce = Duration(minutes: 2);

  // ★ (수정) 위험 상태 잠금
  DateTime? _dangerLockedUntil;

  // ✅ 추가: 잠금 해제 타이머와 잠금 지속 시간
  Timer? _dangerUnlockTimer;
  static const Duration _dangerLockDuration = Duration(minutes: 5);

  // ── “이번 주 0분이면 초기화” 안전가드용 플래그 ─────────────────────
  bool _emptyWeekSeenOnce = false;

  // ★ 이벤트 구독(건강)
  StreamSubscription<HealthSnapshot>? _healthSub;

  // ★★★ Wear 낙상 이벤트(EventChannel) ─────────────────────────────
  static const EventChannel _fallChannel = EventChannel('shimbox/fall_events');
  StreamSubscription<dynamic>? _fallSub;
  DateTime? _lastFallPopupAt;
  static const Duration _fallPopupDebounce = Duration(seconds: 30);

  // ✅ 추가: 마지막 낙상 이벤트 시각(UTC)
  DateTime? _lastFallEventAtUtc;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();

    // 위치/소켓 주기 전송은 기존대로 (HealthPage에서는 건강만 조절)
    _startHealthStreaming();
    _startWorkTickerIfNeeded();

    // 폴백: 피로도는 10분마다 한 번 재평가 (서버/그래프 값 변화 대비)
    _startFatigueTicker();

    // ★ 낙상 이벤트 스트림 구독 시작
    _attachFallStream();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startHealthStreaming();
      _startWorkTickerIfNeeded();
      _startFatigueTicker();
      _service.startChangePolling(interval: const Duration(seconds: 5));
      _computeAndRenderFatigue();
      _attachFallStream();
    } else {
      _stopHealthStreaming();
      _stopWorkTicker();
      _stopFatigueTicker();
      _service.stopChangePolling();
      _detachFallStream();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _healthSub?.cancel();
    _service.stopChangePolling();

    _stopHealthStreaming();
    _stopWorkTicker();
    _stopFatigueTicker();

    _dangerUnlockTimer?.cancel();
    _detachFallStream();

    super.dispose();
  }

  // ── 소켓 전송 제어 ────────────────────────────────────────────────
  void _startHealthStreaming() {
    if (!LocationSocketService.instance.isConnected) {
      debugPrint('[HEALTH-WS] not connected (skip startHealthStreaming)');
      return;
    }
    LocationSocketService.instance.sendHealthNow(); // 즉시 1회
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

  // ── 드라이버 프로필 로드 (키/몸무게) ──────────────────────────────
  Future<void> _loadDriverProfile() async {
    try {
      final driverId = UserData.driverId;
      if (driverId == null) return;

      final profile = await ApiService.fetchDriverProfile(driverId);
      final data = profile.data;

      final int? h =
          data['height'] is int
              ? data['height'] as int
              : (data['height']?.toInt());
      final int? w =
          data['weight'] is int
              ? data['weight'] as int
              : (data['weight']?.toInt());

      if (!mounted) return;
      setState(() {
        _heightCm = h;
        _weightKg = w;
      });
    } catch (e) {
      debugPrint('[Profile] failed to load height/weight: $e');
    }
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

  // ── 피로도 10분 주기 ─────────────────────────────────────────────
  void _startFatigueTicker() {
    _fatigueTicker ??= Timer.periodic(
      _fatigueTick,
      (_) => _computeAndRenderFatigue(),
    );
    _computeAndRenderFatigue(); // 최초 즉시
  }

  void _stopFatigueTicker() {
    _fatigueTicker?.cancel();
    _fatigueTicker = null;
  }

  // ── 부팅 시 데이터 로딩 (호출 순서 조정) ──────────────────────────
  Future<void> _boot() async {
    await _restoreLocalWorkSessionFromPrefs();
    await _loadDriverProfile();
    await _checkHealthConnection();
    await _maybeAutoPromptHealthConnect();

    await _fetchDeliveryCount(); // 오늘 건수 + 배달 그래프
    await _fetchWeeklyWorkStats(); // 근무시간 + 근무 그래프

    await _resetWorkSessionIfEmpty();
    _attachHealthChangeStream(); // 이벤트 기반 갱신
  }

  void _attachHealthChangeStream() {
    _healthSub?.cancel();
    _healthSub = _service.changes.listen((snap) async {
      if (!mounted) return;

      // 1) 상태 업데이트
      setState(() {
        _stepCountValue = snap.steps;
        _stepCount = snap.steps > 0 ? snap.steps.toString() : '데이터 없음';
        _lastStepUpdatedAt = snap.capturedAt;

        _heartRateValue = snap.heartRate;
        _heartRate = snap.heartRate > 0 ? '${snap.heartRate} bpm' : '데이터 없음';
        _lastHeartUpdatedAt = snap.capturedAt;
      });

      // 2) 심박 히스토리/피로도
      _pushHr(snap.heartRate);
      await _computeAndRenderFatigue();

      // 3) 서버/소켓 전송
      await _sendHealthToServer();
      if (LocationSocketService.instance.isConnected) {
        await LocationSocketService.instance.sendHealthNow();
      }
    });

    _service.startChangePolling(interval: const Duration(seconds: 5));
  }

  /// 이번 주(月~金) 모든 일자 근무가 0분이면 로컬 세션 초기화
  Future<void> _resetWorkSessionIfEmpty() async {
    try {
      if (UserData.workStart != null && UserData.workEnd == null) {
        _emptyWeekSeenOnce = false;
        return;
      }

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
        if (!_emptyWeekSeenOnce) {
          _emptyWeekSeenOnce = true;
          return;
        }
        final endedLongAgo =
            (UserData.workEnd != null) &&
            now.difference(UserData.workEnd!).inHours > 24;

        if (endedLongAgo || UserData.workStart == null) {
          if (!mounted) return;
          setState(() {
            UserData.workStart = null;
            UserData.workEnd = null;
            _todayWorkMinutesFromApi = 0;
          });
          _stopWorkTicker();

          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('work_start_iso');
            await prefs.remove('work_end_iso');
          } catch (_) {}
        } else {
          // 최근에 끝난 세션은 유지
        }
      } else {
        _emptyWeekSeenOnce = false;
      }
    } catch (e) {
      debugPrint('[Work] 초기화 확인 실패: $e');
    }
  }

  Future<void> _refreshAllAndSendOnce() async {
    await _fetchStepCount();
    await _fetchHeartRate();
    await _computeAndRenderFatigue();
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
      ).subtract(Duration(days: now.weekday - 1));
      final weekEnd = weekStart.add(const Duration(days: 4));

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

      final maxM = minutesList.fold<int>(0, (m, v) => v > m ? v : m);
      final scaleBase = (maxM > 0) ? maxM : 480; // 모두 0이면 8시간 기준

      final bars =
          minutesList.map((m) {
            if (m <= 0) return _barMinPx;
            final h = (m / scaleBase) * _barMaxPx;
            return h.clamp(_barMinPx, _barMaxPx);
          }).toList();

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

  // ── 표시 유틸 ───────────────────────────────────────────────────
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
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.25,
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
        _service.stopChangePolling();
        _healthSub?.cancel();
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
      _attachHealthChangeStream();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Health Connect 권한을 허용해 주세요.')),
        );
      }
    }
  }

  // ── 걸음/심박 불러오기 (수동 새로고침용) ────────────────────────────
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

      if (!silent) {
        await _computeAndRenderFatigue();
      }

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

      _pushHr(hr);
      if (!silent) {
        await _computeAndRenderFatigue();
      }

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
      _attachHealthChangeStream();
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
      _attachHealthChangeStream();
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
      UserData.conditionStatus = _fatigueLevel;
      await ApiService.sendHealthData(
        step: _stepCountValue,
        heartRate: _heartRateValue,
        conditionStatus: UserData.conditionStatus,
      );
    }
  }

  // ── 피로도 계산 유틸 ─────────────────────────────────────────────
  double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : 1.0 * v);

  int _levelToSeverity(String level) {
    switch (level) {
      case '좋음':
        return 0;
      case '경고':
        return 1;
      case '위험':
        return 2;
      default:
        return 1;
    }
  }

  Map<String, String> _alarmTextForLevel(String level, double score) {
    switch (level) {
      case '경고':
        return {'title': '피로도 경고 상태입니다.', 'subtitle': '잠깐 스트레칭과 수분 섭취를 권장합니다.'};
      case '위험':
        return {
          'title': '피로도 위험 상태! 휴식이 필요합니다.',
          'subtitle': '무리 금지, 즉시 휴식을 취하세요.',
        };
      default:
        return {'title': '', 'subtitle': ''};
    }
  }

  void _pushAlarmItem(String title, String subtitle) {
    try {
      if (!Get.isRegistered<AlarmController>()) return;
      final ctrl = Get.find<AlarmController>();
      ctrl.addAlarm(AlarmItem(title: title, subtitle: subtitle));
    } catch (_) {}
  }

  Future<void> _maybeShowFatiguePopup(String level, double score) async {
    if (!(level == '경고' || level == '위험')) return;

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

  // ★ 3단계 + 2줄 메시지 + 위험 5분 잠금(유지)
  void _applyFatigueView(double s) {
    String newLvl;
    Color newCol;
    String newMsg;
    double newScore = s;

    if (_dangerLockedUntil != null &&
        DateTime.now().isBefore(_dangerLockedUntil!)) {
      newLvl = '위험';
      newCol = const Color(0xFFEE404C);
      newMsg = '위험! 즉시 휴식이 필요합니다.\n안전한 곳에서 안정을 취하세요. (상태 유지 중)';
      newScore = 0.9;
    } else {
      _dangerLockedUntil = null;

      if (s < 0.50) {
        newLvl = '좋음';
        newCol = const Color(0xFF61D5AB);
        newMsg = '컨디션이 좋아요.\n평소 페이스로 진행하세요.';
      } else if (s < 0.80) {
        newLvl = '경고';
        newCol = const Color(0xFFFFC069);
        newMsg = '주의! 스트레칭과 물 섭취가 필요해요.';
      } else {
        newLvl = '위험';
        newCol = const Color(0xFFEE404C);
        newMsg = '위험! 즉시 휴식이 필요합니다.';
      }
    }

    if (!mounted) return;
    setState(() {
      _fatigue = newScore;
      _fatigueLevel = newLvl;
      _fatigueColorDyn = newCol;
      _fatigueMessageDyn = newMsg;
    });

    // ★ WS 전송 시 피로도 캐시 업데이트(낙상 패킷에도 함께 포함됨)
    LocationSocketService.instance.updateFatigue(
      score: newScore,
      level: newLvl,
    );

    final String prevLvl = _prevFatigueLevel ?? '좋음';
    final int newSev = _levelToSeverity(newLvl);
    final int prevSev = _levelToSeverity(prevLvl);
    final bool isEscalation = newSev > prevSev;

    final now = DateTime.now();
    final canInsertAlarm =
        _lastAlarmInsertedAt == null ||
        now.difference(_lastAlarmInsertedAt!) >= _alarmDebounce;

    if (isEscalation) {
      final t = _alarmTextForLevel(newLvl, newScore);

      if (newLvl == '위험') {
        _dangerLockedUntil = DateTime.now().add(_dangerLockDuration);
        _dangerUnlockTimer?.cancel();
        _dangerUnlockTimer = Timer(_dangerLockDuration, () {
          _dangerLockedUntil = null; // 잠금 해제
          _computeAndRenderFatigue(); // 즉시 재평가
        });

        _pushAlarmItem(t['title']!, t['subtitle']!);
        _lastAlarmInsertedAt = now;
        _maybeShowFatiguePopup(newLvl, newScore);
      } else if (newLvl == '경고' && canInsertAlarm) {
        _pushAlarmItem(t['title']!, t['subtitle']!);
        _lastAlarmInsertedAt = now;
        _maybeShowFatiguePopup(newLvl, newScore);
      }
    }

    _prevFatigueLevel = newLvl;
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
      return math.max(60, med);
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

      double hrSlope = _clamp01((inc - 0.02) / 0.10);

      double hrBoost = 0.0;
      final bool severeDelta = delta >= 20 || currentHR >= 110;
      final bool acuteDelta = delta >= 10;
      if (severeDelta) {
        hrBoost = 1.0;
      } else if (acuteDelta) {
        hrBoost = 0.90;
      }
      final hrComp = math.max(hrSlope, hrBoost);

      // ✅ 심박이 충분히 내려왔으면(급성/심각 아님) 잠금 조기 해제
      if (_dangerLockedUntil != null && !severeDelta && !acuteDelta) {
        _dangerLockedUntil = null;
      }

      final workComp = _clamp01((workMin - 180) / (600 - 180)); // 3h→0, 10h→1
      final delivComp = _clamp01(deliveries / 120.0); // 0~120건
      final stepsComp = _clamp01((steps - 3000) / (15000 - 3000)); // 3k~15k

      double bmiPenalty = 0.0;
      if (_heightCm != null &&
          _heightCm! > 0 &&
          _weightKg != null &&
          _weightKg! > 0) {
        final bmi = _weightKg! / math.pow(_heightCm! / 100.0, 2);
        bmiPenalty = _clamp01((bmi - 25.0) / (27.0 - 25.0)); // 25~27 → 0~1
      } else {
        bmiPenalty = 0.0;
      }

      double score =
          0.55 * hrComp +
          0.20 * workComp +
          0.10 * delivComp +
          0.10 * stepsComp +
          0.05 * bmiPenalty;

      if (acuteDelta) {
        score = math.max(score, 0.80);
      } else if (severeDelta) {
        score = math.max(score, 0.90);
      }

      _applyFatigueView(_clamp01(score));
    } catch (e) {
      debugPrint('[Fatigue] compute failed: $e');
      _applyFatigueView(0.4);
    }
  }

  // ────────────── ★ 낙상(EventChannel) 핸들러들 ──────────────
  void _attachFallStream() {
    _fallSub?.cancel();
    _fallSub = _fallChannel.receiveBroadcastStream().listen(
      (dynamic raw) async {
        try {
          // MainActivity에서 JSON 문자열 그대로 넘김
          final String s = raw is String ? raw : (raw?.toString() ?? '{}');
          debugPrint('[Fall] raw: $s');
          final Map<String, dynamic> data = jsonDecode(s);

          // 이벤트 시각 파싱(가능 시 사용)
          final dynamic ts =
              (data['capturedAt'] ?? data['ts'] ?? data['timestamp']);
          DateTime? eventUtc;
          if (ts is String && ts.isNotEmpty) {
            final parsed = DateTime.tryParse(ts);
            if (parsed != null) {
              eventUtc = parsed.isUtc ? parsed : parsed.toUtc();
            }
          }
          _lastFallEventAtUtc = eventUtc ?? DateTime.now().toUtc();

          // 서버/워치 포맷에 따라 널리 대응
          final status =
              (data['status'] ?? data['result'] ?? '').toString().toLowerCase();
          final type = (data['type'] ?? '').toString().toLowerCase();
          final ok = (data['ok'] ?? data['success'] ?? false) == true;

          // 조건: status == fail || (명시적 ok=false) || type == 'fall' & severity>=threshold
          final severity =
              (data['severity'] is num)
                  ? (data['severity'] as num).toDouble()
                  : null;

          final isFail = status == 'fail' || (!ok && status.isEmpty);
          final looksLikeFall = type.contains('fall') || data['fall'] == true;

          final isFall =
              isFail || looksLikeFall || (severity != null && severity >= 0.8);

          debugPrint(
            '[Fall] parsed -> status=$status type=$type ok=$ok severity=$severity isFall=$isFall',
          );

          if (isFall) {
            // ★ 디버깅 로그: 신원 필드가 붙는지 확인 (WS 쪽에서 driverId/driverName 포함)
            debugPrint('[Fall] sending WS with ID via sendHealthFall');

            // ★ 감지 TRUE 즉시 전송 (피로도 score/level도 함께 실림)
            await LocationSocketService.instance.sendHealthFall(
              isDetected: true,
              capturedAtUtc: _lastFallEventAtUtc,
            );

            // ★ 팝업 띄우기 (닫힘 처리/false 전송은 다이얼로그 콜백에서 처리)
            await _showFallAlert(subtitle: _buildFallSubtitle(data));
          }
        } catch (e) {
          debugPrint('[Fall] payload parse error: $e');
        }
      },
      onError: (e) => debugPrint('[Fall] stream error: $e'),
      cancelOnError: false,
    );
    debugPrint('[Fall] stream attached');
  }

  void _detachFallStream() {
    _fallSub?.cancel();
    _fallSub = null;
    debugPrint('[Fall] stream detached');
  }

  String _buildFallSubtitle(Map<String, dynamic> data) {
    final ts = (data['capturedAt'] ?? data['ts'] ?? data['timestamp']);
    if (ts is String && ts.isNotEmpty) {
      return '낙상 의심 신호가 감지되었습니다.\n시간: $ts';
    }
    return '낙상 의심 신호가 감지되었습니다.\n안전을 먼저 확인하세요.';
  }

  // ✅ 낙상 팝업: 커스텀 다이얼로그 사용
  //   - 이제 여기서는 "false"를 직접 보내지 않고
  //   - 다이얼로그 쪽에서 onResolve 콜백을 통해 false 전송
  Future<void> _showFallAlert({required String subtitle}) async {
    // 포그라운드 + 현재 화면일 때만 팝업
    final appState = WidgetsBinding.instance.lifecycleState;
    final inForeground = appState == AppLifecycleState.resumed;
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (!mounted || !inForeground || !isCurrent) {
      debugPrint(
        '[Fall] popup skipped (foreground=$inForeground, isCurrent=$isCurrent)',
      );
      return;
    }

    // 30초 디바운스
    final now = DateTime.now();
    if (_lastFallPopupAt != null &&
        now.difference(_lastFallPopupAt!) < _fallPopupDebounce) {
      debugPrint('[Fall] popup debounced');
      return;
    }
    _lastFallPopupAt = now;

    // 🔔 여기서 커스텀 다이얼로그 호출
    await FallDetectedDialog.show(
      context,
      title: '낙상이 감지되었습니다.',
      subtitle: subtitle,
      badgeText: '위험',
      barrierDismissible: false, // ★ 추가: 바깥 터치로 닫히지 않게
      onResolved: () async {
        // ★ 추가: 유저가 직접 닫았을 때만 호출되는 콜백
        await LocationSocketService.instance.sendHealthFall(
          isDetected: false,
          capturedAtUtc: DateTime.now().toUtc(),
        );
        _pushAlarmItem('낙상 의심 감지', '안전을 먼저 확인하세요.');
      },
    );

    // ❌ 기존: 팝업 닫힌 직후 여기서 false 보내던 부분 제거
    // await LocationSocketService.instance.sendHealthFall(
    //   isDetected: false,
    //   capturedAtUtc: DateTime.now().toUtc(),
    // );
    // _pushAlarmItem('낙상 의심 감지', '안전을 먼저 확인하세요.');
  }

  // ────────────────────────────────────────────────────────────────
}
