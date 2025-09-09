import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class AdjustedVolumeDialog extends StatelessWidget {
  final String title; // 굵은 제목
  final String description; // 회색 본문
  final String iconAsset; // 왼쪽 체크 아이콘
  final Color iconColor; // 아이콘 색(테마)
  final double width; // 팝업 가로
  final BorderRadius borderRadius;
  final VoidCallback? onClose;

  const AdjustedVolumeDialog({
    super.key,
    required this.title,
    required this.description,
    this.iconAsset = 'assets/images/icons/check.svg',
    this.iconColor = const Color(0xFF61D5AB),
    this.width = 320,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.onClose,
  });

  /// 간단 호출용: AdjustedVolumeDialog.show(context, title: '...', description: '...')
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String description,
    String iconAsset = 'assets/images/icons/check.svg',
    Color iconColor = const Color(0xFF61D5AB),
    double width = 320,
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(14)),
    VoidCallback? onClose,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder:
          (_) => Center(
            child: SizedBox(
              width: width,
              child: Dialog(
                shape: RoundedRectangleBorder(borderRadius: borderRadius),
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                child: AdjustedVolumeDialog(
                  title: title,
                  description: description,
                  iconAsset: iconAsset,
                  iconColor: iconColor,
                  width: width,
                  borderRadius: borderRadius,
                  onClose: onClose,
                ),
              ),
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: Material(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // X 닫기 버튼 (오른쪽 위, 살짝 위로)
              Positioned(
                right: -4,
                top: -8,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(
                    Icons.close,
                    size: 20,
                    color: Color(0xFF8C8C8C),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    onClose?.call();
                  },
                ),
              ),

              // 본문
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 좌측 아이콘 (SVG currentColor만 변경)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0, right: 12.0),
                    child: SvgPicture.asset(
                      iconAsset,
                      width: 24,
                      height: 24,
                      theme: SvgTheme(currentColor: iconColor),
                    ),
                  ),

                  // 텍스트
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 굵은 타이틀 (스크린샷 느낌)
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            height: 1.35,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // 회색 본문
                        Text(
                          description,
                          style: const TextStyle(
                            fontSize: 13.5,
                            height: 1.5,
                            color: Color(0xFF8F8F8F),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
