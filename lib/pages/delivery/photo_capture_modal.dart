import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../utils/api_service.dart';
import 'package:shimbox_app/utils/firebase_uploader.dart';

class PhotoCaptureModal extends StatefulWidget {
  final String phoneNumber;
  final Function(File) onSend;
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
  File? _image;

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera);
    if (picked != null) {
      setState(() {
        _image = File(picked.path);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _pickImage();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 80,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child:
              _image == null
                  ? const SizedBox(
                    height: 200,
                    child: Center(child: CircularProgressIndicator()),
                  )
                  : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                        child: Image.file(
                          _image!,
                          width: double.infinity,
                          height: 260,
                          fit: BoxFit.cover,
                        ),
                      ),
                      GestureDetector(
                        onTap: () async {
                          if (_image != null) {
                            widget.onSend(_image!); // ✅ 이 부분만 호출하고 나머지 제거
                            Navigator.of(context, rootNavigator: false).pop();
                          }
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
                            '고객에게 문자 보내기 >',
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
        ),
        Positioned(
          top: 220,
          right: 36,
          child: GestureDetector(
            onTap: () async => await _pickImage(),
            child: MediaQuery(
              // ✅ 시스템 글꼴 확대 무시(원하면 삭제)
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.0)),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '다시찍기',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14, // 고정 폰트 크기
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(width: 6),
                    SvgPicture.asset(
                      'assets/images/delivery/re.svg',
                      width: 18, // 아이콘도 살짝 축
                      height: 18,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
