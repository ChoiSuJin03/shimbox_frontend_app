import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import '../../controllers/alarm_controller.dart';

class AlarmPage extends StatelessWidget {
  const AlarmPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<AlarmController>();

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          // 🔧 AlarmScreen과 동일한 패딩
          padding: const EdgeInsets.symmetric(horizontal: 39, vertical: 31),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 🔙 뒤로가기 (SVG)
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: SvgPicture.asset(
                  'assets/images/home/back.svg',
                  width: 9,
                  height: 18,
                  color: const Color(0xFF000000),
                ),
              ),
              const SizedBox(height: 39),

              // 🛎 제목
              const Text(
                '알림',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 26),

              // 📜 알림 리스트
              Expanded(
                child: GetX<AlarmController>(
                  builder: (ctrl) {
                    final items = ctrl.alarms;
                    if (items.isEmpty) {
                      return const Center(
                        child: Text(
                          '알림이 없습니다.',
                          style: TextStyle(fontSize: 16),
                        ),
                      );
                    }
                    return ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];

                        // '배송완료' 부분만 초록/굵게, 나머지는 검정
                        final title = item.title;
                        const keyword = '배송완료';
                        final hasKeyword = title.contains(keyword);
                        final before =
                            hasKeyword ? title.split(keyword).first : '';
                        final after =
                            hasKeyword
                                ? title.split(keyword).skip(1).join(keyword)
                                : '';

                        return Padding(
                          padding: const EdgeInsets.only(
                            bottom: 35.0,
                            left: 11,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 아이콘
                              Padding(
                                padding: const EdgeInsets.only(top: 7.0),
                                child: SvgPicture.asset(
                                  'assets/images/home/alarmG.svg',
                                  width: 17.14,
                                  height: 22.22,
                                  color: const Color(0xFF61D5AB),
                                ),
                              ),
                              const SizedBox(width: 20),

                              // 텍스트 묶음
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // 제목(리치텍스트)
                                    if (hasKeyword)
                                      RichText(
                                        text: TextSpan(
                                          children: [
                                            if (before.isNotEmpty)
                                              TextSpan(
                                                text: before,
                                                style: const TextStyle(
                                                  color: Colors.black,
                                                  fontWeight: FontWeight.w500,
                                                  fontSize: 15,
                                                ),
                                              ),
                                            const TextSpan(
                                              text: keyword,
                                              style: TextStyle(
                                                color: Color(0xFF61D5AB),
                                                fontWeight: FontWeight.bold,
                                                fontSize: 15,
                                              ),
                                            ),
                                            if (after.isNotEmpty)
                                              TextSpan(
                                                text: after,
                                                style: const TextStyle(
                                                  color: Colors.black,
                                                  fontWeight: FontWeight.w500,
                                                  fontSize: 15,
                                                ),
                                              ),
                                          ],
                                        ),
                                      )
                                    else
                                      const SizedBox.shrink(),

                                    // keyword가 없으면 그냥 일반 텍스트로
                                    if (!hasKeyword)
                                      Text(
                                        title,
                                        style: const TextStyle(
                                          color: Colors.black,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 15,
                                        ),
                                      ),

                                    const SizedBox(height: 4),

                                    // 주소(서브타이틀)
                                    Text(
                                      item.subtitle,
                                      style: const TextStyle(
                                        color: Colors.grey,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
