import 'dart:async';
import 'package:flutter/services.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 값이 변할 때만 내보내는 스냅샷 (이벤트 드리븐)
class HealthSnapshot {
  final int steps;
  final int heartRate;
  final DateTime capturedAt;

  HealthSnapshot({
    required this.steps,
    required this.heartRate,
    DateTime? capturedAt,
  }) : capturedAt = capturedAt ?? DateTime.now();
}

class HealthService {
  final Health _health = Health();

  static final MethodChannel _channel = MethodChannel('shimbox/health');

  // 변화 이벤트 스트림
  final _changesCtrl = StreamController<HealthSnapshot>.broadcast();
  Stream<HealthSnapshot> get changes => _changesCtrl.stream;

  // 최근 전송값(변경 감지용)
  int _lastSteps = -1;
  int _lastHr = -1;

  // (Observer 없을 때) 가벼운 폴링
  Timer? _poller;
  Duration _pollInterval = const Duration(seconds: 5);

  Future<bool> connect() async {
    await _health.configure();

    final types = <HealthDataType>[
      HealthDataType.STEPS,
      HealthDataType.HEART_RATE,
    ];
    final perms = <HealthDataAccess>[
      HealthDataAccess.READ,
      HealthDataAccess.READ,
    ];

    bool ok = await _health.hasPermissions(types, permissions: perms) ?? false;
    if (!ok) ok = await _health.requestAuthorization(types, permissions: perms);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('health_connected', ok);

    if (ok) {
      final steps = await getTodaySteps();
      final hr = await getCurrentHeartRate();
      _emitIfChanged(steps: steps, hr: hr, force: true);
    }
    return ok;
  }

  Future<void> disconnect() async {
    stopChangePolling();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('health_connected', false);
  }

  // ── 데이터 조회 ───────────────────────────────────────────────────
  Future<int> getTodaySteps() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    try {
      final steps = await _channel.invokeMethod<int>('getSamsungStepsTotal', {
        'start': start.millisecondsSinceEpoch,
        'end': now.millisecondsSinceEpoch,
      });
      return steps ?? 0;
    } on PlatformException catch (_) {
      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// ✅ 오늘(자정~현재) 구간의 평균 심박수(bpm)
  Future<int> getTodayAverageHeartRate() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    try {
      var data = await _health.getHealthDataFromTypes(
        types: const [HealthDataType.HEART_RATE],
        startTime: start,
        endTime: now,
      );
      data = _health.removeDuplicates(data);

      double sum = 0;
      int n = 0;
      for (final d in data) {
        final v = _asNum(d.value);
        if (v == null) continue;
        final bpm = v.toDouble();
        if (bpm < 30 || bpm > 220) continue; // 간단 잡음 필터
        sum += bpm;
        n += 1;
      }
      if (n == 0) return 0;
      return (sum / n).round();
    } catch (_) {
      return 0;
    }
  }

  Future<int> getCurrentHeartRate() async {
    final now = DateTime.now();
    final start = now.subtract(const Duration(minutes: 40));
    var data = await _health.getHealthDataFromTypes(
      types: const [HealthDataType.HEART_RATE],
      startTime: start,
      endTime: now,
    );
    data = _health.removeDuplicates(data);

    double? latest;
    DateTime? latestTs;
    for (final d in data) {
      final v = _asNum(d.value);
      if (v == null) continue;
      final ts = d.dateTo ?? d.dateFrom;
      if (ts == null) continue;
      if (latestTs == null || ts.isAfter(latestTs)) {
        latestTs = ts;
        latest = v.toDouble();
      }
    }
    return latest?.round() ?? 0;
  }

  num? _asNum(dynamic v) {
    if (v is NumericHealthValue) return v.numericValue;
    if (v is num) return v;
    if (v is bool) return v ? 1 : 0;
    return null;
  }

  // ── 이벤트 발행/폴링 ─────────────────────────────────────────────
  void _emitIfChanged({
    required int steps,
    required int hr,
    bool force = false,
  }) {
    final changed = force || steps != _lastSteps || hr != _lastHr;
    if (!changed) return;
    _lastSteps = steps;
    _lastHr = hr;
    _changesCtrl.add(
      HealthSnapshot(steps: steps, heartRate: hr, capturedAt: DateTime.now()),
    );
  }

  void startChangePolling({Duration interval = const Duration(seconds: 5)}) {
    _pollInterval = interval;
    _poller?.cancel();
    _poller = Timer.periodic(_pollInterval, (_) async {
      try {
        final steps = await getTodaySteps();
        final hr = await getCurrentHeartRate();
        _emitIfChanged(steps: steps, hr: hr);
      } catch (_) {}
    });
  }

  void stopChangePolling() {
    _poller?.cancel();
    _poller = null;
  }

  void dispose() {
    stopChangePolling();
    _changesCtrl.close();
  }
}
