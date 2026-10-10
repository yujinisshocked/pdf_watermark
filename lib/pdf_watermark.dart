/// Pure-Dart PDF watermarking. Bytes in, bytes out. No Flutter needed.
library;

export 'src/exceptions.dart' show PdfWatermarkException;
export 'src/page_info.dart' show PageSize, readFirstPageSize;
export 'src/raster.dart' show WatermarkRaster;
export 'src/watermark.dart' show watermarkPdf;