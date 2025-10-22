// lib/pages/health/health_service.dart
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HealthService {
  final Health _health = Health();
  static const _channel = MethodChannel('shimbox/health');

  Timer? _poller;

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
    return ok;
  }

  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('health_connected', false);
  }

  // 디버그: 오리진 목록
  Future<void> debugOriginsOnce() async {
    try {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final json = await _channel.invokeMethod<String>('debugStepOrigins', {
        'start': start.millisecondsSinceEpoch,
        'end': now.millisecondsSinceEpoch,
      });
      // ignore: avoid_print
      print('[HealthService] origins=$json');
    } catch (e) {
      // ignore: avoid_print
      print('[HealthService] debugOrigins error: $e');
    }
  }

  // 걸음수 (삼성 오리진 우선, 없으면 전체 합산) — "하루 전체" 유지
  Future<int> getTodaySteps() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    try {
      final steps = await _channel.invokeMethod<int>('getSamsungStepsTotal', {
        'start': start.millisecondsSinceEpoch,
        'end': now.millisecondsSinceEpoch,
      });
      return steps ?? 0;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[HealthService] platform error getTodaySteps: $e');
      return 0;
    } catch (e) {
      // ignore: avoid_print
      print('[HealthService] getTodaySteps error: $e');
      return 0;
    }
  }

  Future<List<int>> getPast7DaysSteps() async {
    final now = DateTime.now();
    final List<int> out = [];
    for (int i = 6; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      final s = DateTime(d.year, d.month, d.day);
      final e = (i == 0) ? now : s.add(const Duration(days: 1));
      try {
        final steps = await _channel.invokeMethod<int>('getSamsungStepsTotal', {
          'start': s.millisecondsSinceEpoch,
          'end': e.millisecondsSinceEpoch,
        });
        out.add(steps ?? 0);
      } catch (_) {
        out.add(0);
      }
    }
    return out;
  }

  // 심박수: 최근 5분만 조회해서 가장 최근 1개 값 반환 (플러그인 최신 API 없이도 동작)
  Future<int> getCurrentHeartRate() async {
    final now = DateTime.now();
    final start = now.subtract(const Duration(minutes: 5));

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
}
