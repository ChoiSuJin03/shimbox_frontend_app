import 'package:get/get.dart';
import '../models/alarm_item.dart';

class AlarmController extends GetxController {
  final RxList<AlarmItem> alarms = <AlarmItem>[].obs;

  void addAlarm(AlarmItem item) {
    alarms.insert(0, item); // 최신이 위로
  }

  // (선택) 같은 주소 중복 방지
  void addAlarmIfNew(AlarmItem item) {
    final exists = alarms.any(
      (a) => a.subtitle == item.subtitle && a.title == item.title,
    );
    if (!exists) alarms.insert(0, item);
  }

  int get unreadCount => alarms.where((a) => !a.read).length;

  void markAllRead() {
    for (final a in alarms) {
      a.read = true;
    }
    alarms.refresh();
  }
}
