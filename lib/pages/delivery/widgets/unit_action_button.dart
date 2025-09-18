/// - 동/호 섹션 하단의 **액션 버튼**만 담당(배송 시작/도착/완료).

import 'package:flutter/material.dart';

class UnitActionButton extends StatelessWidget {
  final int aggregate; // 0(대기)/1(진행)/2(완료)
  final VoidCallback onStart;
  final Future<void> Function() onArrive;

  const UnitActionButton({
    super.key,
    required this.aggregate,
    required this.onStart,
    required this.onArrive,
  });

  @override
  Widget build(BuildContext context) {
    if (aggregate == 2) {
      return OutlinedButton(
        onPressed: null,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFAAAAAA),
          disabledForegroundColor: const Color(0xFFAAAAAA),
          side: const BorderSide(color: Color(0xFFAAAAAA)),
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          backgroundColor: Colors.white,
        ),
        child: const Text(
          '배송 완료',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      );
    } else if (aggregate == 1) {
      return ElevatedButton(
        onPressed: onArrive,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF61D5AB),
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
        child: const Text(
          '배송 도착',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      );
    } else {
      return OutlinedButton(
        onPressed: onStart,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF61D5AB),
          side: const BorderSide(color: Color(0xFF61D5AB)),
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
        child: const Text(
          '배송 시작',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      );
    }
  }
}
