import 'package:flutter/material.dart';

/// 낙상 감지 알럿 (좌상단 "위험" 배지 + 레드 톤 + 닫기 버튼)
class FallDetectedDialog {
  static Future<void> show(
    BuildContext context, {
    String badgeText = '위험',
    String title = '낙상이 감지되었습니다.',
    String? subtitle, // 추가 문구가 있으면 여기로
    double width = 340,
    bool barrierDismissible = false, // ★ 추가: 바깥 터치로 닫을지 여부
    Future<void> Function()? onResolved, // ★ 추가: 유저가 직접 닫았을 때 콜백
  }) async {
    return showDialog(
      context: context,
      barrierDismissible: barrierDismissible, // ★ 적용
      barrierColor: Colors.black.withOpacity(0.32),
      builder: (_) {
        final card = Material(
          color: Colors.transparent,
          child: Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 본문 카드
                Container(
                  width: width,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 18,
                        spreadRadius: 2,
                        offset: Offset(0, 8),
                        color: Color(0x22000000),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 상단 타이틀 + 닫기 버튼
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.warning_amber_rounded,
                            size: 22,
                            color: Color(0xFFEE404C),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                                height: 1.35,
                                color: Color(0xFFEE404C), // 빨간색
                              ),
                            ),
                          ),
                          // 닫기(X) 버튼
                          GestureDetector(
                            onTap: () async {
                              // ★ 유저가 직접 닫을 때만 onResolved 호출
                              if (onResolved != null) {
                                await onResolved();
                              }
                              Navigator.of(context).pop();
                            },
                            child: const Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: Colors.black45,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (subtitle != null && subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            color: Colors.black87,
                          ),
                        )
                      else
                        const Text(
                          '안전을 먼저 확인하세요.',
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            color: Colors.black87,
                          ),
                        ),
                    ],
                  ),
                ),

                // 좌상단 "위험" 배지
                Positioned(
                  left: -4,
                  top: -10,
                  child: _DangerBadge(text: badgeText),
                ),
              ],
            ),
          ),
        );

        return card;
      },
    );
  }
}

class _DangerBadge extends StatelessWidget {
  final String text;
  const _DangerBadge({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: ShapeDecoration(
        color: const Color(0xFFEE404C),
        shape: const StadiumBorder(),
        shadows: const [
          BoxShadow(
            blurRadius: 10,
            offset: Offset(0, 4),
            color: Color(0x33000000),
          ),
        ],
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 12,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}
