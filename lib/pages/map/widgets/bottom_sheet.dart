import 'package:flutter/material.dart';

class ApartmentBottomSheet extends StatelessWidget {
  final String aptName;
  final List<Map<String, String>> deliveries;

  const ApartmentBottomSheet({
    super.key,
    required this.aptName,
    required this.deliveries,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (_, scrollController) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 헤더
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  const Icon(Icons.location_on, color: Colors.black54),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      aptName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // 리스트
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: deliveries.length,
                itemBuilder: (context, index) {
                  final d = deliveries[index];
                  return ListTile(
                    leading: const Icon(
                      Icons.apartment,
                      color: Color(0xFF2D5FFF),
                    ),
                    title: Text(d["address"] ?? ""),
                    subtitle: Text(d["detail"] ?? ""),
                    trailing: const Icon(
                      Icons.location_on,
                      size: 18,
                      color: Colors.green,
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
