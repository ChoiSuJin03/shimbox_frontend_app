/// - "다른 주소에서 이미 배송을 시작" 경고 다이얼로그.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class ActiveWarnDialog extends StatelessWidget {
  const ActiveWarnDialog({super.key});

  @override
  Widget build(BuildContext context) {
    const double dialogWidth = 360;
    const double contentHeight = 120;
    return Center(
      child: SizedBox(
        width: dialogWidth,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.antiAlias,
          backgroundColor: Colors.white,
          elevation: 6,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          titlePadding: const EdgeInsets.fromLTRB(27, 30, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(27, 13, 24, 20),
          title: SizedBox(
            height: 35,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SvgPicture.asset(
                    'assets/images/icons/warning.svg',
                    width: 35,
                    height: 34,
                    theme: const SvgTheme(currentColor: Color(0xFFEE404C)),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: -15,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(
                      Icons.close,
                      size: 22,
                      color: Color(0xFF777777),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
          content: const SizedBox(
            height: contentHeight,
            child: SingleChildScrollView(
              child: Text(
                '다른 주소에서 이미 배송을 시작했습니다.\n이전 건에서 "배송 도착"을 먼저 눌러 주세요.\n',
                style: TextStyle(fontSize: 13, height: 1.5),
                textAlign: TextAlign.left,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
