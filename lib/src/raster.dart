import 'dart:typed_data';

/// A pre-rendered RGBA bitmap to stamp on every page of a PDF.
///
/// Pixels are 8-bit straight (non-premultiplied) RGBA, row-major,
/// top-row first. The alpha channel becomes the PDF image's `/SMask`,
/// so transparent regions show through to whatever is underneath.
class WatermarkRaster {
  final Uint8List rgba;
  final int width;
  final int height;

  /// Logical page size (in PDF points) this raster was rendered for.
  /// Informational only — the watermarker stretches to each page's box.
  final double pageWidth;
  final double pageHeight;

  WatermarkRaster({
    required this.rgba,
    required this.width,
    required this.height,
    required this.pageWidth,
    required this.pageHeight,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('raster dimensions must be positive');
    }
    if (rgba.length != width * height * 4) {
      throw ArgumentError(
        'rgba length ${rgba.length} does not match $width × $height × 4',
      );
    }
  }
}