import 'package:flutter/material.dart';
import '../../../../utils/address_utils.dart';
import 'unit_action_button.dart';

class UnitSection extends StatelessWidget {
  final String base; // 기본주소
  final String unitLabel; // "301동 102호"
  final List<Map<String, dynamic>> prods;
  final int aggregate; // 0/1/2
  final VoidCallback onPhoneTap;
  final VoidCallback onNaviTap;
  final VoidCallback onStart;
  final Future<void> Function() onArrive;

  const UnitSection({
    super.key,
    required this.base,
    required this.unitLabel,
    required this.prods,
    required this.aggregate,
    required this.onPhoneTap,
    required this.onNaviTap,
    required this.onStart,
    required this.onArrive,
  });

  @override
  Widget build(BuildContext context) {
    final count = prods.length;
    final split = splitAddressForTwoLines(base);
    final baseLine1 = split['line1'] ?? base;
    final baseLine2 = split['line2'] ?? '';

    final fullAddrLine1 = baseLine1;
    final fullAddrLine2 = [
      baseLine2,
      unitLabel,
    ].where((s) => s.isNotEmpty).join(' ');

    final bool unitAllDone = (aggregate == 2);
    final Color addrTextColor =
        unitAllDone ? const Color(0xFFAAAAAA) : Colors.black87;
    final Color actionIconColor =
        unitAllDone ? const Color(0xFFAAAAAA) : const Color(0xFF61D5AB);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fullAddrLine1,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: addrTextColor,
                    ),
                  ),
                  Text(
                    fullAddrLine2,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: addrTextColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '배송 건수 : $count건',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color:
                          unitAllDone
                              ? const Color(0xFF888888)
                              : const Color(0xFF2D5FFF),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                GestureDetector(
                  onTap: onPhoneTap,
                  child: Icon(Icons.phone, size: 20, color: actionIconColor),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: onNaviTap,
                  child: Icon(
                    Icons.navigation,
                    size: 20,
                    color: actionIconColor,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        UnitActionButton(
          aggregate: aggregate,
          onStart: onStart,
          onArrive: onArrive,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
