import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../../utils/address_utils.dart';

class ActiveWarnDialog extends StatelessWidget {
  final String? activeAddress; // 진행중 주소(옵션)

  const ActiveWarnDialog({super.key, this.activeAddress});

  @override
  Widget build(BuildContext context) {
    const double dialogWidth = 360;
    const double contentHeight = 145;

    final hasAddr = (activeAddress ?? '').trim().isNotEmpty;
    final split = splitAddressForTwoLines(activeAddress ?? '');
    final line1 = split['line1'] ?? (activeAddress ?? '');
    final line2 = split['line2'] ?? '';

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
          content: SizedBox(
            height: contentHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '다른 주소에서 이미 배송을 시작했습니다.\n이전 건에서 "배송 도착"을 먼저 눌러 주세요.\n',
                  style: TextStyle(fontSize: 13, height: 1.5),
                  textAlign: TextAlign.left,
                ),
                if (hasAddr) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '[ 진행 중 배송지 ]',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color.fromARGB(255, 63, 63, 63),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    line1,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF777777),
                    ),
                  ),
                  if (line2.isNotEmpty)
                    Text(
                      line2,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF777777),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
