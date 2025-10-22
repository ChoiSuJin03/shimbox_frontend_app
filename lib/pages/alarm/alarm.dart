import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import '../health/health_status.dart';
import '../../controllers/alarm_controller.dart';

class AlarmPage extends StatelessWidget {
  const AlarmPage({super.key});

  Color _levelColor(String title) {
    if (title.contains('위험')) return const Color(0xFFFF8A8A); // 위험
    if (title.contains('주의')) return const Color(0xFFFFC069); // 주의
    if (title.contains('배송완료')) return const Color(0xFF61D5AB); // 기존 키워드
    return Colors.black;
  }

  FontWeight _levelWeight(String title) {
    if (title.contains('위험') ||
        title.contains('주의') ||
        title.contains('배송완료')) {
      return FontWeight.bold;
    }
    return FontWeight.w600;
  }

  bool _isFatigueAlarm(String title) {
    // 건강/피로도 관련 알림 키워드 판별 (필요시 패턴 추가)
    return title.contains('피로도') ||
        title.contains('심박') ||
        title.contains('휴식');
  }

  @override
  Widget build(BuildContext context) {
    final c = Get.find<AlarmController>();

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          // 🔧 기존 레이아웃 유지
          padding: const EdgeInsets.symmetric(horizontal: 39, vertical: 31),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 🔙 뒤로가기
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
                        final title = item.title;

                        // '배송완료' 강조는 기존 동작 유지
                        const keyword = '배송완료';
                        final hasKeyword = title.contains(keyword);
                        final before =
                            hasKeyword ? title.split(keyword).first : '';
                        final after =
                            hasKeyword
                                ? title.split(keyword).skip(1).join(keyword)
                                : '';

                        final titleColor = _levelColor(title);
                        final weight = _levelWeight(title);

                        final iconColor =
                            title.contains('위험')
                                ? const Color(0xFFFF8A8A)
                                : title.contains('주의')
                                ? const Color(0xFFFFC069)
                                : const Color(0xFF61D5AB);

                        return InkWell(
                          onTap: () {
                            // 피로도/건강 관련 알림이면 건강 페이지로 이동
                            if (_isFatigueAlarm(title)) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const HealthPage(),
                                ),
                              );
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(
                              bottom: 35.0,
                              left: 11,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 7.0),
                                  child: SvgPicture.asset(
                                    'assets/images/home/alarmG.svg',
                                    width: 17.14,
                                    height: 22.22,
                                    color: iconColor,
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (hasKeyword)
                                        RichText(
                                          text: TextSpan(
                                            children: [
                                              if (before.isNotEmpty)
                                                TextSpan(
                                                  text: before,
                                                  style: TextStyle(
                                                    color: titleColor,
                                                    fontWeight: weight,
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
                                                  style: TextStyle(
                                                    color: titleColor,
                                                    fontWeight: weight,
                                                    fontSize: 15,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        )
                                      else
                                        Text(
                                          title,
                                          style: TextStyle(
                                            color: titleColor,
                                            fontWeight: weight,
                                            fontSize: 15,
                                          ),
                                        ),
                                      const SizedBox(height: 4),
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
