import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class HealthAlertDialog {
  /// 건강 경고 팝업 표시
  static Future<void> show(
    BuildContext context, {
    String title = '현재 심박수가 평소보다 높습니다.',
    String subtitle = '무리하지 마시고 휴식을 권장합니다.',
    String warningIconPath = 'assets/images/icons/warning.svg',
    double width = 340,
  }) async {
    return showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.transparent, // 배경은 아래 Stack에서 처리
      builder: (_) {
        final card = Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: width,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 본문
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 15),

                      // 경고 아이콘
                      // -> 삼각형은 currentColor 사용, 느낌표는 #FFFFFF 고정
                      // -> SvgTheme.currentColor 로만 빨강 지정
                      SvgPicture.asset(
                        warningIconPath,
                        width: 60,
                        height: 40,
                        theme: const SvgTheme(
                          currentColor: Color(0xFFEE404C), // 삼각형만 빨강으로
                        ),
                      ),

                      const SizedBox(height: 14),
                      // 제목
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // 부제
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 15,
                          color: Color(0xFF9E9E9E),
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                  ),

                  // 닫기 버튼 (우상단, 아이콘보다 위에 위치)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Material(
                      color: Colors.transparent,
                      child: IconButton(
                        tooltip: '닫기',
                        style: IconButton.styleFrom(
                          padding: const EdgeInsets.all(6),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        splashRadius: 20,
                        iconSize: 24,
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.black54,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        // 배경 반투명 + 카드
        return Stack(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(color: Colors.black.withOpacity(0.32)),
            ),
            card,
          ],
        );
      },
    );
  }
}
