/// Thrown by the watermarker when the input PDF can't be processed.
class PdfWatermarkException implements Exception {
  final String message;
  PdfWatermarkException(this.message);

  @override
  String toString() => 'PdfWatermarkException: $message';
}