// lib/pages/map/widgets/numbered_marker_icon.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'; // RenderRepaintBoundary
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class NumberedMarkerIcon {
  static final Map<String, BitmapDescriptor> _cache = {};

  // ────────────────────────────────────────────────
  // 내부 유틸
  // ────────────────────────────────────────────────

  // Color → 32bit ARGB 정수 (캐시 키 안정화용)
  static int _argb32(Color c) =>
      (c.alpha << 24) | (c.red << 16) | (c.green << 8) | c.blue;

  // 캔버스로 고품질 다운스케일
  static Future<Uint8List> _downscalePng({
    required ui.Image src,
    required int outW,
    required int outH,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = Paint()..isAntiAlias = true;

    final srcRect = Rect.fromLTWH(
      0,
      0,
      src.width.toDouble(),
      src.height.toDouble(),
    );
    final dstRect = Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());

    canvas.drawImageRect(src, srcRect, dstRect, paint);

    final img = await recorder.endRecording().toImage(outW, outH);
    final bytes =
        (await img.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
    return bytes;
  }

  /// 오버레이에 위젯을 크게(슈퍼샘플링) 그려서 `ui.Image`로 캡처
  static Future<ui.Image> _widgetToImage({
    required BuildContext context,
    required Widget widget,
    required double captureLogicalWidth,
    required double captureLogicalHeight,
    double pixelRatio = 1.0, // 슈퍼샘플링은 논리 크기로; 여기선 1.0 권장
  }) async {
    final key = GlobalKey();
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      throw StateError('No Overlay found in the provided context.');
    }

    late OverlayEntry entry;
    final completer = Completer<ui.Image>();

    entry = OverlayEntry(
      builder:
          (_) => Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: captureLogicalWidth,
                height: captureLogicalHeight,
                child: Material(type: MaterialType.transparency, child: widget),
              ),
            ),
          ),
    );

    overlay.insert(entry);

    // 다음 프레임까지 기다렸다가 캡처
    await SchedulerBinding.instance.endOfFrame;
    await Future.delayed(const Duration(milliseconds: 16));

    try {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      completer.complete(image);
    } catch (e) {
      completer.completeError(e);
    } finally {
      entry.remove();
    }

    return completer.future;
  }

  /// SVG + 중앙 텍스트를 합성한 마커 위젯
  static Widget _markerWidget({
    required String svgAssetPath,
    required String label,
    required double targetWidth,
    required double fontScale,
    required double centerYFactor,
    required Color textColor,
    required double strokeWidth,
    required Color strokeColor,
  }) {
    // 핀 세로비 (필요시 튜닝). SVG에 맞춰 1.40 정도가 보편적
    final double h = targetWidth * 1.40;

    return SizedBox(
      width: targetWidth,
      height: h,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SvgPicture.asset(
            svgAssetPath,
            width: targetWidth,
            height: h,
            fit: BoxFit.contain,
          ),
          Align(
            alignment: Alignment(0, (centerYFactor - 0.5) * 2),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w900,
                fontSize: targetWidth * 0.36 * (fontScale * 2.0),
                height: 1.0,
                shadows:
                    strokeWidth > 0
                        ? [Shadow(color: strokeColor, blurRadius: strokeWidth)]
                        : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────
  // 공개 API (슈퍼샘플링 적용)
  // ────────────────────────────────────────────────

  /// 숫자 마커 (빨간 핀 위 숫자)
  ///
  /// - [targetWidth]: 최종 보이는 마커 너비(px). 작아도 선명하게 보이도록
  ///   내부에서 [superSample]배로 크게 그려서 다운스케일함.
  /// - [superSample]: 3~4 권장 (기본 4)
  static Future<BitmapDescriptor> numberFromSvg({
    required BuildContext context,
    required int number,
    required String svgAssetPath,
    double targetWidth = 12, // 최종 보이는 크기
    double fontScale = 0.45,
    double centerYFactor = 0.42,
    Color textColor = Colors.white,
    double strokeWidth = 3,
    Color strokeColor = Colors.black54,
    double superSample = 4.0, // 크게 그렸다가 축소 → 선명
  }) async {
    final key =
        'NUM|$svgAssetPath|$number|$targetWidth|$fontScale|$centerYFactor|'
        '${_argb32(textColor)}|$strokeWidth|${_argb32(strokeColor)}|$superSample';
    final cached = _cache[key];
    if (cached != null) return cached;

    // 크게 캡처할 논리 크기
    final captureW = targetWidth * superSample;
    final captureH = captureW * 1.40; // 세로 비율 유지

    final widget = _markerWidget(
      svgAssetPath: svgAssetPath,
      label: number.toString(),
      targetWidth: captureW,
      fontScale: fontScale,
      centerYFactor: centerYFactor,
      textColor: textColor,
      strokeWidth: strokeWidth,
      strokeColor: strokeColor,
    );

    // 1) 큰 이미지로 캡처 (pixelRatio=1.0)
    final bigImage = await _widgetToImage(
      context: context,
      widget: widget,
      captureLogicalWidth: captureW,
      captureLogicalHeight: captureH,
      pixelRatio: 1.0,
    );

    // 2) 고품질 다운스케일 → 최종 targetWidth로 축소
    final outBytes = await _downscalePng(
      src: bigImage,
      outW: targetWidth.round(),
      outH: (targetWidth * 1.40).round(),
    );

    final bd = BitmapDescriptor.bytes(outBytes);
    _cache[key] = bd;
    return bd;
  }

  /// 시작 마커 (파란 핀 위 'S')
  static Future<BitmapDescriptor> startFromSvg({
    required BuildContext context,
    required String svgAssetPath,
    double targetWidth = 12,
    double fontScale = 0.48,
    double centerYFactor = 0.42,
    Color textColor = Colors.white,
    double strokeWidth = 3,
    Color strokeColor = Colors.black54,
    double superSample = 4.0,
  }) async {
    final key =
        'START|$svgAssetPath|$targetWidth|$fontScale|$centerYFactor|'
        '${_argb32(textColor)}|$strokeWidth|${_argb32(strokeColor)}|$superSample';
    final cached = _cache[key];
    if (cached != null) return cached;

    final captureW = targetWidth * superSample;
    final captureH = captureW * 1.40;

    final widget = _markerWidget(
      svgAssetPath: svgAssetPath,
      label: 'S',
      targetWidth: captureW,
      fontScale: fontScale,
      centerYFactor: centerYFactor,
      textColor: textColor,
      strokeWidth: strokeWidth,
      strokeColor: strokeColor,
    );

    final bigImage = await _widgetToImage(
      context: context,
      widget: widget,
      captureLogicalWidth: captureW,
      captureLogicalHeight: captureH,
      pixelRatio: 1.0,
    );

    final outBytes = await _downscalePng(
      src: bigImage,
      outW: targetWidth.round(),
      outH: (targetWidth * 1.40).round(),
    );

    final bd = BitmapDescriptor.bytes(outBytes);
    _cache[key] = bd;
    return bd;
  }
}
