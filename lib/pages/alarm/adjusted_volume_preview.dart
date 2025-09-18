import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shimbox_app/models/adjusted_volume_dialog.dart';
import 'package:shimbox_app/controllers/alarm_controller.dart';
import 'package:shimbox_app/models/alarm/alarm_item.dart';

class AdjustedVolumePreviewPage extends StatelessWidget {
  const AdjustedVolumePreviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final alarm = Get.find<AlarmController>();

    return Scaffold(
      appBar: AppBar(title: const Text('물량 조정 팝업 미리보기')),
      body: Center(
        child: ElevatedButton(
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

            alarm.addAlarm(
              AlarmItem(title: '배송물량이 조정되었습니다.', subtitle: '$before → $after건'),
            );
          },
          child: const Text('팝업 띄우기'),
        ),
      ),
    );
  }
}
