import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'raster.dart';

/// Renders a brick-lay tiled text pattern to a [WatermarkRaster].
///
/// [pageWidth] and [pageHeight] should come from `readFirstPageSize`.
/// [dpi] controls output resolution: 150 is plenty for a watermark, 300
/// for crisp output in print.
///
/// If [fontBytes] is null, the platform default font is used.
Future<WatermarkRaster> renderTiledWatermark({
  required String text,
  required double pageWidth,
  required double pageHeight,
  double fontSize = 14,
  Color color = const Color(0xFF999999),
  double opacity = 0.2,
  double gapX = 10,
  double gapY = 6,
  double dpi = 150,
  Uint8List? fontBytes,
}) async {
  if (text.isEmpty) throw ArgumentError('text must not be empty');
  if (pageWidth <= 0 || pageHeight <= 0) {
    throw ArgumentError('page dimensions must be positive');
  }

  final scale = dpi / 72.0;
  final width = (pageWidth * scale).ceil();
  final height = (pageHeight * scale).ceil();

  // Register the custom font once per hash.
  String? family;
  if (fontBytes != null) {
    family = 'WM_${fontBytes.hashCode}';
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(fontBytes)));
    await loader.load();
  }

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );

  final resolved = color.withValues(alpha: opacity);

  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: family,
        fontSize: fontSize * scale,
        color: resolved,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  final spacingX = tp.width + gapX * scale;
  final spacingY = fontSize * scale + gapY * scale;

  var row = 0;
  for (double y = -spacingY; y < height + spacingY; y += spacingY) {
    final offsetX = (row & 1) == 1 ? (spacingX / 2) : 0.0;
    for (double x = -spacingX + offsetX; x < width + spacingX; x += spacingX) {
      tp.paint(canvas, Offset(x, y));
    }
    row++;
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bd = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  image.dispose();
  picture.dispose();

  if (bd == null) throw StateError('failed to rasterize watermark');

  return WatermarkRaster(
    rgba: bd.buffer.asUint8List(),
    width: width,
    height: height,
    pageWidth: pageWidth,
    pageHeight: pageHeight,
  );
}