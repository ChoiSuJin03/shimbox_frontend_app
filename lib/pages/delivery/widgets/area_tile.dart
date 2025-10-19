import 'package:flutter/material.dart';
import '../../../../utils/address_utils.dart';

class AreaTile extends StatelessWidget {
  final String name; // ex) "OO로 123" 또는 "기타"
  final int total; // 총 건수
  final int progressed; // 진행(시작+완료)
  final int doneCount; // 완료
  final bool expanded; // 펼침 여부
  final VoidCallback onTap; // 탭 동작

  const AreaTile({
    super.key,
    required this.name,
    required this.total,
    required this.progressed,
    required this.doneCount,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final inProgressCount = progressed - doneCount;
    final isAllDone = progressed == total && total > 0 && inProgressCount == 0;

    Color markerBg;
    Color markerIcon;
    if (progressed == 0) {
      markerBg = const Color(0xFFF4F4F4);
      markerIcon = const Color(0xFF61D5AB);
    } else if (isAllDone) {
      markerBg = const Color(0xFFF4F4F4);
      markerIcon = const Color(0xFF6D6D6D);
    } else {
      markerBg = const Color(0xFF61D5AB);
      markerIcon = Colors.white;
    }

    final splitForHeader = splitAddressForTwoLines(name);
    final headerL1 = splitForHeader['line1'] ?? name;
    final headerL2 = splitForHeader['line2'] ?? '';

    late String statusText;
    late Color statusColor;
    if (isAllDone) {
      statusText = '$total / $total건 완료';
      statusColor = const Color(0xFF888888);
    } else if (progressed > 0) {
      statusText = '$progressed / $total건 진행 중';
      statusColor = const Color(0xFF2D5FFF);
    } else {
      statusText = '0 / $total건 미완료';
      statusColor = const Color(0xFF888888);
    }

    final Color headerTextColor =
        isAllDone ? const Color(0xFF555555) : Colors.black87;

    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: markerBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.location_on, size: 24, color: markerIcon),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    headerL1 + (isAllDone ? ' (배송완료)' : ''),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: headerTextColor,
                    ),
                  ),
                  if (headerL2.isNotEmpty)
                    Text(
                      headerL2,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: headerTextColor,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
            ),
          ],
        ),
      ),
    );
  }
}
