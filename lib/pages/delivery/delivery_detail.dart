import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimbox_app/controllers/bottom_nav_controller.dart';
import 'package:shimbox_app/utils/navigation_helper.dart';
import 'package:shimbox_app/pages/delivery/photo_capture_modal.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shimbox_app/utils/firebase_uploader.dart';
import '../../utils/api_service.dart';
import 'package:shimbox_app/models/test_user_data.dart' as localUser;

import 'package:shimbox_app/controllers/alarm_controller.dart';
import 'package:shimbox_app/models/alarm_item.dart';

class DeliveryDetailPage extends StatefulWidget {
  final Map<String, dynamic> area;
  const DeliveryDetailPage({super.key, required this.area});

  @override
  State<DeliveryDetailPage> createState() => _DeliveryDetailPageState();
}

class _DeliveryDetailPageState extends State<DeliveryDetailPage> {
  int? expandedIndex;
  List<List<int>> deliveryStatus = [];
  List<Map<String, dynamic>> deliveryAreas = [];
  bool isLoading = true;

  final AlarmController alarmController =
      Get.find<AlarmController>(); // ✅ find만!

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, () async {
      final prefs = await SharedPreferences.getInstance();
      final savedToken = prefs.getString('token');
      localUser.UserData.token = savedToken;
      fetchData();
    });
  }

  Future<void> fetchData() async {
    try {
      final data = await ApiService.fetchDeliverySummary();
      setState(() {
        deliveryAreas =
            data.expand<Map<String, dynamic>>((area) {
              return area['groups'].map<Map<String, dynamic>>((group) {
                return {
                  'name': area['shippingLocation'],
                  'address': group['detailAddress'],
                  'total': group['count'],
                  'phone': '01012345678',
                  'products': group['products'],
                };
              });
            }).toList();

        deliveryStatus =
            deliveryAreas.map((e) {
              return List.generate(
                e['products'].length,
                (i) => _statusToInt(e['products'][i]['shippingStatus']),
              );
            }).toList();

        isLoading = false;
      });
    } catch (_) {
      setState(() => isLoading = false);
    }
  }

  int _statusToInt(String status) {
    switch (status) {
      case '배송시작':
        return 1;
      case '배송완료':
        return 2;
      default:
        return 0;
    }
  }

  /// 현재 화면 데이터에서 status==1(배송시작)인 첫 건을 찾아 주소/이름 반환
  Map<String, String>? _findActiveDeliveryInfo() {
    for (int a = 0; a < deliveryAreas.length; a++) {
      final products = deliveryAreas[a]['products'] as List;
      for (int p = 0; p < products.length; p++) {
        if (deliveryStatus[a][p] == 1) {
          final prod = products[p] as Map<String, dynamic>;
          final addr = '${prod['address']} ${prod['detailAddress']}';
          final name = '${prod['recipientName']}';
          return {'address': addr, 'name': name};
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.area['name']} 배달 건',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.only(left: 37),
          child: Center(
            child: GestureDetector(
              onTap: () => Get.find<BottomNavController>().changeBottomNav(0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: SvgPicture.asset(
                  'assets/images/home/back.svg',
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
      ),
      body:
          isLoading
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 36,
                  vertical: 16,
                ),
                child: ListView.builder(
                  itemCount: deliveryAreas.length,
                  itemBuilder: (context, index) {
                    final item = deliveryAreas[index];
                    final isExpanded = expandedIndex == index;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap:
                              () => setState(
                                () => expandedIndex = isExpanded ? null : index,
                              ),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF4F4F4),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Center(
                                    child: SvgPicture.asset(
                                      'assets/images/home/marker.svg',
                                      width: 24,
                                      height: 24,
                                      color: const Color(0xFF61D5AB),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${item['name']}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${item['total']}건',
                                        style: const TextStyle(
                                          color: Colors.grey,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  isExpanded
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (isExpanded) ...[
                          const SizedBox(height: 10),
                          _buildDropdownContent(index, item),
                        ],
                        const SizedBox(height: 12),
                      ],
                    );
                  },
                ),
              ),
    );
  }

  Widget _buildDropdownContent(int areaIndex, Map<String, dynamic> item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(item['products'].length, (i) {
        final product = item['products'][i];
        final status = deliveryStatus[areaIndex][i];
        final textColor = status == 2 ? const Color(0xFF7A7A7A) : Colors.black;
        final iconColor =
            status == 2 ? const Color(0xFF7A7A7A) : const Color(0xFF61D5AB);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${product['recipientName']}',
                        style: TextStyle(
                          fontSize: 14,
                          color: textColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${product['address']} ${product['detailAddress']}',
                        style: TextStyle(fontSize: 14, color: textColor),
                      ),
                    ],
                  ),
                ),
                SvgPicture.asset(
                  'assets/images/delivery/phone.svg',
                  width: 20,
                  height: 20,
                  color: iconColor,
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap:
                      () => startNaviToAddressWithNaver(
                        '${product['address']} ${product['detailAddress']}',
                      ),
                  child: SvgPicture.asset(
                    'assets/images/delivery/nav.svg',
                    width: 20,
                    height: 20,
                    color: iconColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildStatusButton(areaIndex, i, status, product),
            const SizedBox(height: 24),
            if (i < item['products'].length - 1)
              Divider(color: Colors.grey[300], height: 1),
            const SizedBox(height: 24),
          ],
        );
      }),
    );
  }

  Widget _buildStatusButton(
    int areaIndex,
    int i,
    int status,
    Map<String, dynamic> product,
  ) {
    if (status == 2) {
      return OutlinedButton(
        onPressed: null,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFAAAAAA),
          side: const BorderSide(color: Color(0xFFAAAAAA)),
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          backgroundColor: Colors.white,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(
              'assets/images/delivery/complete.svg',
              width: 20,
              height: 20,
              color: const Color(0xFFAAAAAA),
            ),
            const SizedBox(width: 8),
            const Text('배송 완료', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      );
    } else if (status == 1) {
      return ElevatedButton(
        onPressed: () async {
          final ok = await ApiService.updateProductStatus(
            product['productId'],
            '배송완료',
          );
          if (!ok) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('배송완료 상태 전환 실패')));
            return;
          }
          await Future.delayed(const Duration(milliseconds: 700));
          await showDialog(
            context: context,
            useRootNavigator: false,
            builder:
                (_) => PhotoCaptureModal(
                  phoneNumber: product['recipientPhone'] ?? '01012345678',
                  productId: product['productId'],
                  onSend: (image) async {
                    final url = await FirebaseUploader.uploadImage(
                      image,
                      folder: 'deliveries',
                    );
                    if (url != null) {
                      final smsText = '배송이 완료되었습니다.\n사진 확인: $url';
                      final uri = Uri.parse(
                        'sms:${product['recipientPhone']}?body=${Uri.encodeComponent(smsText)}',
                      );
                      if (await canLaunchUrl(uri)) await launchUrl(uri);
                      final imgOk = await ApiService.sendDeliveryImage(
                        productId: product['productId'],
                        imageUrl: url,
                      );
                      if (imgOk && mounted)
                        setState(() => deliveryStatus[areaIndex][i] = 2);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Firebase 업로드 실패')),
                      );
                    }
                  },
                ),
          );
        },
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
        onPressed: () async {
          // 이미 진행 중인(배송시작) 건이 있는지 확인
          final active = _findActiveDeliveryInfo();
          if (active != null) {
            final activeAddr = active['address']!;
            alarmController.addAlarm(
              AlarmItem(
                title: '배송완료를 눌렀는지 확인해주세요',
                subtitle: activeAddr, // ✅ “배송시작으로 켜져 있는 주소”를 표시
              ),
            );
            // (팝업) 알림 보기 → 알림 페이지로 이동
            await showDialog(
              context: context,
              builder: (_) {
                // 원하는 사이즈
                const double dialogWidth = 360; // <- 가로
                const double contentHeight = 120; // <- 내용 영역 높이

                return Center(
                  // <= AlertDialog를 원하는 폭으로 제한
                  child: SizedBox(
                    width: dialogWidth,
                    child: AlertDialog(
                      // ✅ 둥글기/외곽선/클립
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10), // ← 원하는 반경으로
                        // side: const BorderSide(color: Color(0xFFEAEAEA), width: 1), // (선택) 테두리
                      ),
                      clipBehavior: Clip.antiAlias, // 내용도 둥근 모서리에 맞게 잘라줌
                      // 색/그림자
                      backgroundColor: Colors.white,
                      // elevation: 50,

                      // 바깥 여백(화면과 다이얼로그 사이)
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 24,
                      ),

                      // 타이틀/컨텐트 패딩
                      titlePadding: const EdgeInsets.fromLTRB(27, 30, 24, 0),
                      contentPadding: const EdgeInsets.fromLTRB(27, 13, 24, 20),

                      // 🔶 경고 아이콘(좌) + X 버튼(우, 살짝 위)
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
                                theme: const SvgTheme(
                                  currentColor: Color.fromARGB(255, 199, 20, 0),
                                ),
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

                      // ✅ 내용 높이 고정 + 스크롤 가능
                      content: SizedBox(
                        height: contentHeight,
                        child: SingleChildScrollView(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '다른 주소에서 이미 배송을 시작했습니다.\n',
                                  style: const TextStyle(
                                    fontSize: 15, // ← 크기 업
                                    fontWeight: FontWeight.w700, // ← 진하게
                                    height: 1.4,
                                    color: Colors.black,
                                  ),
                                ),
                                const TextSpan(
                                  text: '이전 건에서 "배송 도착"을 먼저 눌러 주세요.\n\n',
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                    color: Colors.black87,
                                  ),
                                ),
                                TextSpan(
                                  text: '진행 중인 주소 : $activeAddr',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                    color: Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                            textAlign: TextAlign.left,
                          ),
                        ),
                      ),

                      // actions 생략하면 하단 버튼 영역 없음 (필요하면 추가)
                    ),
                  ),
                );
              },
            );

            return;
          }

          // 정상 처리
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => const Center(child: CircularProgressIndicator()),
          );
          final ok = await ApiService.updateProductStatus(
            product['productId'],
            '배송시작',
          );
          Navigator.of(context).pop();
          if (ok) {
            await Future.delayed(const Duration(seconds: 1));
            setState(() => deliveryStatus[areaIndex][i] = 1);
          } else {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('배송 시작 처리에 실패했습니다.')));
          }
        },
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
