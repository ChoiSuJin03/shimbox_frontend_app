// lib/pages/health/health_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shimbox_app/pages/health/health_service.dart';
import 'package:shimbox_app/utils/api_service.dart';
import 'package:shimbox_app/models/test_user_data.dart';
import 'package:shimbox_app/pages/health/health_alert_dialog.dart';

// ✅ 건강은 위치 소켓(LocationSocketService)을 통해서만 전송
import 'package:shimbox_app/services/location_socket_service.dart';

class HealthPage extends StatefulWidget {
  const HealthPage({super.key});

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> with WidgetsBindingObserver {
  final _service = HealthService();

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

  // ── 피로도 UI용 상수 (그대로 유지) ─────────────────────────────
  final fatigueLevel = 'HIGH';
  final fatigueColor = const Color(0xFFFF8A8A);
  final fatigueMessage = '오늘은 좀 피곤하실 것 같네요.\n휴식이 필요해요!';

  // 데모 차트
  final workChartHeights = [77.0, 78.0, 55.0, 76.0, 71.0];
  final workChartLabels = ['월요일', '화요일', '수요일', '목요일', '금요일'];
  final deliveryChartHeights = [65.0, 60.0, 72.0, 55.0, 53.0];
  final deliveryChartLabels = ['월요일', '화요일', '수요일', '목요일', '금요일'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();

    // ✅ HealthPage 진입: 소켓이 이미 연결되어 있다면
    // 즉시 1회 전송 + 페이지 열려있는 동안만 주기 전송 시작
    _startHealthStreaming();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱 포그라운드/백그라운드 전환에 따라 건강 주기 전송 on/off
    if (state == AppLifecycleState.resumed) {
      _startHealthStreaming();
    } else {
      _stopHealthStreaming();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopHealthStreaming(); // ✅ 페이지 떠날 때 건강 주기 전송 중지
    super.dispose();
  }

  // ───────────────────────────────────────────
  // 건강 스트리밍 제어 (이 페이지에서만 보냄)
  // ───────────────────────────────────────────
  void _startHealthStreaming() {
    if (!LocationSocketService.instance.isConnected) return;

    // 즉시 1회
    LocationSocketService.instance.sendHealthNow();

    // 페이지 열려있는 동안만 주기 전송
    LocationSocketService.instance.startHealthPeriodic(
      interval: const Duration(seconds: 30),
    );
  }

  void _stopHealthStreaming() {
    LocationSocketService.instance.stopHealthPeriodic();
  }

  // ───────────────────────────────────────────
  // 초기 부팅/데이터 로딩
  // ───────────────────────────────────────────
  Future<void> _boot() async {
    await _checkHealthConnection();
    await _maybeAutoPromptHealthConnect();
    await _fetchDeliveryCount();
  }

  Future<void> _refreshAllAndSendOnce() async {
    await _fetchStepCount();
    await _fetchHeartRate();
    await _sendHealthToServer();

    // UI 갱신 직후 한 번 더 서버에 health 송신
    if (LocationSocketService.instance.isConnected) {
      await LocationSocketService.instance.sendHealthNow();
    }
  }

  Future<void> _fetchDeliveryCount() async {
    try {
      final data = await ApiService.fetchDeliverySummary();
      int count = 0;
      for (final area in data) {
        count += (area['completedCount'] ?? 0) as int;
      }
      if (!mounted) return;
      setState(() => _todayDeliveryCount = count);
    } catch (_) {}
  }

  Future<void> _checkHealthConnection() async {
    final prefs = await SharedPreferences.getInstance();
    final isConnected = prefs.getBool('health_connected') ?? false;
    if (!mounted) return;
    setState(() => _isHealthConnected = isConnected);

    if (isConnected) {
      await _refreshAllAndSendOnce();
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
      _startHealthStreaming(); // 권한 허용 직후에도 페이지 열려 있으면 주기 전송 시작
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Health Connect 권한을 허용해 주세요.')),
        );
      }
    }
  }

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
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Health Connect 권한을 허용해 주세요.')),
        );
      }
    }
  }

  // ===== 데이터 가져오기 =====
  Future<void> _fetchStepCount() async {
    setState(() {
      _isLoadingStep = true;
      _stepCount = '...';
    });

    try {
      final today = await _service.getTodaySteps();
      if (!mounted) return;
      setState(() {
        _stepCountValue = today;
        _stepCount = today.toString();
        _lastStepUpdatedAt = DateTime.now();
        UserData.stepCount = today;
      });

      if (LocationSocketService.instance.isConnected) {
        await LocationSocketService.instance.sendHealthNow();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stepCount = '오류';
        _lastStepUpdatedAt = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('걸음 수 가져오기 실패: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingStep = false);
      }
    }
  }

  Future<void> _fetchHeartRate() async {
    setState(() {
      _isLoadingHeartRate = true;
      _heartRate = '...';
    });

    try {
      final hr = await _service.getCurrentHeartRate();
      if (!mounted) return;
      setState(() {
        _heartRateValue = hr;
        _heartRate = hr > 0 ? '$hr bpm' : '데이터 없음';
        _lastHeartUpdatedAt = DateTime.now();
        UserData.heartRate = hr;
      });

      if (LocationSocketService.instance.isConnected) {
        await LocationSocketService.instance.sendHealthNow();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _heartRate = '오류';
        _lastHeartUpdatedAt = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('심박수 데이터를 불러오는 데 실패했어요.\nHealth Connect 권한을 확인해주세요.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingHeartRate = false);
      }
    }
  }

  // ===== 표시 유틸 =====
  String _formattedDate() {
    final now = DateTime.now();
    final weekdayKor = ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'];
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

  // ===== UI =====
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
                        const SizedBox(height: 4),
                        Text(
                          '${UserData.name ?? '사용자'}님의 건강 리포트',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    TextButton(
                      onPressed: _tryConnectHealthService,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(40, 40),
                      ),
                      child: Column(
                        children: [
                          Image.asset(
                            'assets/images/health/wearable.png',
                            width: 40,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _isHealthConnected ? '연동 완료' : '웨어러블\n연동',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '건강 경고 미리보기',
                      icon: SvgPicture.asset(
                        'assets/images/icons/warning.svg',
                        width: 22,
                        height: 22,
                      ),
                      onPressed: () async {
                        await HealthAlertDialog.show(
                          context,
                          title: '현재 심박수가 평소보다 높습니다.',
                          subtitle: '무리하지 마시고 휴식을 권장합니다.',
                          warningIconPath: 'assets/images/icons/warning.svg',
                          width: 340,
                        );
                      },
                    ),
                  ],
                ),

                const SizedBox(height: 15),

                // ▶ 피로도 카드 (이전 UI에서 가져온 부분)
                Row(
                  children: [
                    Container(
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        color: fatigueColor,
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
                            fatigueLevel,
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
                        fatigueMessage,
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
                        onRefresh: _isHealthConnected ? _fetchStepCount : null,
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
                        onRefresh: _isHealthConnected ? _fetchHeartRate : null,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 50),
                _metricCardWithBarChart(
                  iconPath: 'assets/images/health/time.svg',
                  title: '근무시간',
                  value: workTime,
                  subtitle: workTimeSub,
                  barHeights: workChartHeights,
                  barLabels: workChartLabels,
                ),
                const SizedBox(height: 25),
                _metricCardWithBarChart(
                  iconPath: 'assets/images/health/delivery.svg',
                  title: '배달 건수',
                  value: deliveryCount,
                  subtitle: deliverySub,
                  subtitleColor: const Color(0xFF61D5AB),
                  barHeights: deliveryChartHeights,
                  barLabels: deliveryChartLabels,
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

  String get workTime {
    if (UserData.workStart != null && UserData.workEnd != null) {
      final duration = UserData.workEnd!.difference(UserData.workStart!);
      return '${duration.inHours}시간 ${duration.inMinutes.remainder(60)}분';
    }
    return '정보 없음';
  }

  String get workTimeSub => '주간 평균 ${UserData.weeklyWorkAvgHours ?? 0}시간';

  String get deliveryCount => '$_todayDeliveryCount건';

  String get deliverySub {
    final today = _todayDeliveryCount;
    final avg = 0;
    final diff = today - avg;
    final sign = diff >= 0 ? '+' : '';
    return '평균 대비 $sign$diff건';
  }

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
        const SizedBox(height: 11),
        isLoading
            ? const CircularProgressIndicator(color: Color(0xFF61D5AB))
            : Text(
              value,
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
        const SizedBox(height: 11),
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
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 35,
                      fontWeight: FontWeight.bold,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 15),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 17,
                      color: subtitleColor ?? Colors.grey,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(barHeights.length, (index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        width: 23,
                        height: barHeights[index],
                        decoration: BoxDecoration(
                          color: const Color(0xFF61D5AB),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        barLabels[index],
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ],
    );
  }
}
