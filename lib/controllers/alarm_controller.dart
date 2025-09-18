// - SharedPreferences에 영속 저장
// - 앱 시작 시 복원 + 만료(24h) 자동 정리
// - 앱 켜진 동안 1시간마다 주기적으로 정리

import 'dart:async';
import 'dart:convert';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/alarm_item.dart';

class AlarmController extends GetxController {
  static const _prefsKey = 'alarms_v1';
  static const Duration _ttl = Duration(hours: 24); // ✅ 24시간 후 만료
  static const Duration _pruneInterval = Duration(hours: 1);

  final RxList<AlarmItem> alarms = <AlarmItem>[].obs;
  Timer? _pruneTimer;

  @override
  void onInit() {
    super.onInit();
    _loadAndPrune(); // 앱 시작 시 복원 + 만료 정리
    _pruneTimer = Timer.periodic(_pruneInterval, (_) => _pruneExpired());
  }

  @override
  void onClose() {
    _pruneTimer?.cancel();
    super.onClose();
  }

  // ---------- Public API ----------

  void addAlarm(AlarmItem item) {
    alarms.insert(0, item);
    _pruneExpired(); // 추가 직후 만료분도 정리
    _save();
  }

  // 같은 제목+주소 중복 방지(선택)
  void addAlarmIfNew(AlarmItem item) {
    final exists = alarms.any(
      (a) => a.subtitle == item.subtitle && a.title == item.title,
    );
    if (!exists) {
      addAlarm(item);
    }
  }

  int get unreadCount => alarms.where((a) => !a.read).length;

  void markAllRead() {
    for (final a in alarms) {
      a.read = true;
    }
    alarms.refresh();
    _save();
  }

  void removeAt(int index) {
    if (index < 0 || index >= alarms.length) return;
    alarms.removeAt(index);
    _save();
  }

  void clearAlarms() {
    alarms.clear();
    _save();
  }

  // ---------- Persistence / Pruning ----------

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = alarms.map((a) => a.toJson()).toList();
    await prefs.setString(_prefsKey, jsonEncode(list));
  }

  Future<void> _loadAndPrune() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List;
        final loaded =
            decoded
                .map((e) => AlarmItem.fromJson(e as Map<String, dynamic>))
                .toList();
        alarms.assignAll(loaded);
      } catch (_) {
        // 파싱 실패 시 초기화
        alarms.clear();
      }
    }
    _pruneExpired();
    await _save(); // 정리 결과 저장
  }

  void _pruneExpired() {
    final now = DateTime.now();
    final keep =
        alarms.where((a) => now.difference(a.createdAt) < _ttl).toList();
    if (keep.length != alarms.length) {
      alarms.assignAll(keep);
      _save();
    }
  }
}
