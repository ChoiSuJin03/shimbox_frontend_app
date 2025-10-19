import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class MapActionHeader extends StatelessWidget {
  final VoidCallback onCurrentLocationPressed;
  final VoidCallback onDrawRoutePressed;
  final VoidCallback? onBackPressed;

  const MapActionHeader({
    super.key,
    required this.onCurrentLocationPressed,
    required this.onDrawRoutePressed,
    this.onBackPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: onCurrentLocationPressed,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A73E9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.my_location,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed: onDrawRoutePressed,
                icon: SvgPicture.asset(
                  'assets/images/map/re.svg',
                  width: 16,
                  height: 16,
                  color: Colors.white,
                ),
                label: const Text('최적 경로 보기'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A73E9),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
