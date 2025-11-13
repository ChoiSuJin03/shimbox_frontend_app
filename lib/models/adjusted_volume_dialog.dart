// lib/models/adjusted_volume_dialog.dart
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class AdjustedVolumeDialog extends StatelessWidget {
  /// 1줄/2줄 제목
  final String title;
  final String? titleLine2;

  /// 1줄/2줄 본문
  final String description;

  /// 강조 본문용 (예: before/after 숫자)
  final int? before;
  final int? after;

  /// 좌측 아이콘 (SVG, currentColor 사용)
  final String iconAsset;
  final Color iconColor; // 브랜드 포인트 컬러 (아이콘에만 적용)

  /// 팝업 크기
  final double width;
  final double? height; // 전체 다이얼로그 세로 고정(옵션)
  final double? contentHeight; // 본문 영역만 고정+스크롤(옵션)

  final BorderRadius borderRadius;
  final VoidCallback? onClose;

  const AdjustedVolumeDialog({
    super.key,
    required this.title,
    this.titleLine2,
    required this.description,
    this.before,
    this.after,
    this.iconAsset = 'assets/images/icons/check.svg',
    this.iconColor = const Color(0xFF61D5AB),
    this.width = 320,
    this.height,
    this.contentHeight,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.onClose,
  });

  /// 간단 호출용 정적 메서드
  static Future<void> show(
    BuildContext context, {
    required String title,
    String? titleLine2,
    required String description,
    int? before,
    int? after,
    String iconAsset = 'assets/images/icons/check.svg',
    Color iconColor = const Color(0xFF61D5AB),
    double width = 320,
    double? height = 212,
    double? contentHeight,
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(14)),
    VoidCallback? onClose,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.45),
      builder:
          (_) => Center(
            child: Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              elevation: 0,
              child: AdjustedVolumeDialog(
                title: title,
                titleLine2: titleLine2,
                description: description,
                before: before,
                after: after,
                iconAsset: iconAsset,
                iconColor: iconColor,
                width: width,
                height: height,
                contentHeight: contentHeight,
                borderRadius: borderRadius,
                onClose: onClose,
              ),
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const pLeft = 20.0, pTop = 16.0, pRight = 12.0, pBottom = 16.0;

    final Widget titleWidget = _buildTitle();
    final Widget descriptionWidget = _buildDescription();

    final card = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: borderRadius,
        border: Border.all(color: const Color(0xFFEAEAEA)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.10),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(pLeft, pTop, pRight, pBottom),
        child: Stack(
          children: [
            // 닫기(X)
            Positioned(
              right: 2,
              top: -4,
              child: InkResponse(
                radius: 20,
                onTap: () {
                  Navigator.of(context).pop();
                  onClose?.call();
                },
                child: const Icon(
                  Icons.close,
                  size: 18,
                  color: Color(0xFF9AA0A6),
                ),
              ),
            ),

            // 내용
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 아이콘
                Padding(
                  padding: const EdgeInsets.only(top: 5, bottom: 10.0),
                  child: SvgPicture.asset(
                    iconAsset,
                    width: 38,
                    height: 38,
                    theme: SvgTheme(currentColor: iconColor),
                  ),
                ),

                // 타이틀
                titleWidget,

                // 타이틀과 본문 사이 간격 넓힘
                const SizedBox(height: 20),

                // 본문
                descriptionWidget,
              ],
            ),
          ],
        ),
      ),
    );

    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Material(color: Colors.white, child: card),
      ),
    );
  }

  // 내부 헬퍼
  Widget _buildTitle() {
    if (titleLine2 != null && titleLine2!.trim().isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleText(title),
          const SizedBox(height: 4),
          _titleText(titleLine2!),
        ],
      );
    }
    return _titleText(title);
  }

  /// 증가/감소/동일 UI를 자동 구성
  Widget _buildDescription() {
    final baseStyle = const TextStyle(
      fontSize: 13.5,
      height: 1.1,
      fontWeight: FontWeight.w600,
      color: Color(0xFF8F8F8F), // 기본 회색
    );

    final List<Widget> children = [Text(description, style: baseStyle)];

    if (before != null && after != null) {
      final int b = before!;
      final int a = after!;
      final int delta = a - b; // +면 증가, -면 감소
      final int diff = (b - a).abs();

      final bool increased = delta > 0;
      final bool decreased = delta < 0;

      // 색/아이콘
      final Color changeColor =
          increased
              ? const Color(0xFFEE404C) // 빨강: 증가(부하 증가)
              : (decreased
                  ? const Color(0xFF61D5AB) // 그린: 감소(완화)
                  : Colors.black);

      final IconData arrowIcon =
          increased
              ? Icons.arrow_upward
              : (decreased ? Icons.arrow_downward : Icons.remove);

      children.add(const SizedBox(height: 6));

      if (decreased) {
        // 🔻 감소 케이스: "4건 다운 6건이 되었어요."
        children.add(
          RichText(
            text: TextSpan(
              style: baseStyle,
              children: [
                const TextSpan(text: '배정건수가 '),
                // 변화량
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Text(
                    '$diff건',
                    style: baseStyle.copyWith(
                      color: changeColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const TextSpan(text: ' 다운 '),
                // 아이콘(아래 화살표)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Icon(arrowIcon, size: 14, color: changeColor),
                ),
                const TextSpan(text: ' '),
                // 최종 값
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Text(
                    '$a건',
                    style: baseStyle.copyWith(color: Colors.black),
                  ),
                ),
                const TextSpan(text: '이 되었어요.'),
              ],
            ),
          ),
        );
      } else if (increased) {
        // 🔺 증가 케이스: "3건 업 15건이 되었어요."
        children.add(
          RichText(
            text: TextSpan(
              style: baseStyle,
              children: [
                const TextSpan(text: '배정건수가 '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Text(
                    '$diff건',
                    style: baseStyle.copyWith(
                      color: changeColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const TextSpan(text: ' 업 '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Icon(arrowIcon, size: 14, color: changeColor),
                ),
                const TextSpan(text: ' '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Text(
                    '$a건',
                    style: baseStyle.copyWith(color: Colors.black),
                  ),
                ),
                const TextSpan(text: '이 되었어요.'),
              ],
            ),
          ),
        );
      } else {
        // 변동 없음
        children.add(
          RichText(
            text: TextSpan(
              style: baseStyle,
              children: [
                const TextSpan(text: '배정건수가 '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Text(
                    '$a건',
                    style: baseStyle.copyWith(color: Colors.black),
                  ),
                ),
                const TextSpan(text: '으로 동일합니다.'),
              ],
            ),
          ),
        );
      }
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );

    if (contentHeight == null) return content;
    return SizedBox(
      height: contentHeight,
      child: SingleChildScrollView(child: content),
    );
  }

  Widget _titleText(String text) => Text(
    text,
    softWrap: true,
    style: const TextStyle(
      fontSize: 16.5,
      fontWeight: FontWeight.w800,
      height: 1.35,
      color: Colors.black,
    ),
  );
}
