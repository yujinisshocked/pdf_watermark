import 'dart:typed_data';

import 'exceptions.dart';
import 'pdf_parser.dart';

/// Display size of a PDF page, in PDF points. For pages with a non-zero
/// `/Rotate`, [width] and [height] already reflect the rotated
/// (displayed) orientation.
class PageSize {
  final double width;
  final double height;
  final int rotate;

  const PageSize({
    required this.width,
    required this.height,
    this.rotate = 0,
  });

  @override
  String toString() =>
      'PageSize(${width.toStringAsFixed(1)}×${height.toStringAsFixed(1)}, '
      'rotate=$rotate)';
}

/// Reads the first page's display size from raw PDF bytes.
PageSize readFirstPageSize(Uint8List pdfBytes) {
  if (pdfBytes.isEmpty) throw PdfWatermarkException('empty input');

  final doc = PdfDoc(pdfBytes)..load();
  final rootRef = doc.trailer!.v['Root'];
  if (rootRef is! PRef) throw PdfWatermarkException('missing /Root');
  final root = doc.obj(rootRef.num);
  if (root is! PDict) throw PdfWatermarkException('malformed /Root');
  final pagesRef = root.v['Pages'];
  if (pagesRef is! PRef) throw PdfWatermarkException('missing /Pages');

  final pages = collectPages(doc, pagesRef.num);
  if (pages.isEmpty) throw PdfWatermarkException('PDF has no pages');

  final pn = pages.first;
  final boxRaw =
      inherited(doc, pn, 'CropBox') ?? inherited(doc, pn, 'MediaBox');
  final box = boxRaw is PArr && boxRaw.v.length >= 4
      ? boxRaw.v.map((e) => (e as PNum).v.toDouble()).toList()
      : <double>[0, 0, 612, 792];

  final w = box[2] - box[0];
  final h = box[3] - box[1];

  var r = (inherited(doc, pn, 'Rotate') as PNum?)?.v.toInt() ?? 0;
  r = ((r % 360) + 360) % 360;

  final dispW = (r == 90 || r == 270) ? h : w;
  final dispH = (r == 90 || r == 270) ? w : h;
  return PageSize(width: dispW, height: dispH, rotate: r);
}