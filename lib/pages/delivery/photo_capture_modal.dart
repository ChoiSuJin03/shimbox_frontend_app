import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class PhotoCaptureModal extends StatefulWidget {
  final String phoneNumber;
  final VoidCallback onSend;
  final int productId;

  const PhotoCaptureModal({
    super.key,
    required this.phoneNumber,
    required this.onSend,
    required this.productId,
  });

  @override
  State<PhotoCaptureModal> createState() => _PhotoCaptureModalState();
}

class _PhotoCaptureModalState extends State<PhotoCaptureModal> {
  String get _maskedPhone {
    final digits = widget.phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length >= 11) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
    }
    if (digits.length == 10) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
    }
    return widget.phoneNumber;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 상단 본문
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center, // 전체 중앙
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      '수신자: ',
                      style: TextStyle(
                        color: Color(0xFF444444),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _maskedPhone,
                      style: const TextStyle(
                        color: Color(0xFF777777),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // ⬇️ 안내문은 왼쪽 정렬 (전체는 중앙)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '문자앱으로 이동합니다.\n사진은 문자앱에서 촬영/첨부하여 전송하세요.',
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      color: Color(0xFF999999),
                      fontSize: 12,
                      height: 1.45,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 하단 CTA 버튼
          GestureDetector(
            onTap: () {
              widget.onSend();
              Navigator.of(context, rootNavigator: false).pop();
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(16),
                ),
              ),
              alignment: Alignment.center,
              child: const Text(
                '고객에게 문자 보내기 →',
                style: TextStyle(
                  color: Color(0xFF61D5AB),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
