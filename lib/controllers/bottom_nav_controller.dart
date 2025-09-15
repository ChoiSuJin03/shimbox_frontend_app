import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shimbox_app/pages/delivery/delivery_detail.dart';

enum PageName { home, map, health }

class BottomNavController extends GetxController {
  var pageIndex = 0.obs;
  var selectedArea = Rxn<Map<String, dynamic>>();

  var isCheckedIn = false.obs;
  var checkInTime = ''.obs;

  var isCheckedOut = false.obs;
  var checkOutTime = ''.obs;

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  void changeBottomNav(int value) {
    pageIndex.value = value;
    selectedArea.value = null;
  }

  /// 상세로 push 하고 결과(bool?)를 반환. (Future가 null일 수 있어 ?? 로 보정)
  Future<bool?> goToDeliveryDetail(Map<String, dynamic> area) {
    final future = Get.to<bool>(
      () => DeliveryDetailPage(area: area),
    ); // Future<bool?>?
    return future ?? Future.value(null); // <- 핵심!
  }
}
