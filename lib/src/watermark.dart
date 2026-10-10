import 'dart:convert';
import 'dart:typed_data';

import 'exceptions.dart';
import 'pdf_parser.dart';
import 'pdf_writer.dart';
import 'raster.dart';
import 'zlib.dart';

/// Stamps [raster] onto every page of [original] as a full-page image
/// overlay. The raster is embedded once, so multi-page PDFs cost the
/// same as single-page ones.
///
/// Output is an incremental update appended to [original]; the original
/// bytes are never modified.
Uint8List watermarkPdf(
  Uint8List original, {
  required WatermarkRaster raster,
}) {
  if (original.isEmpty) {
    throw PdfWatermarkException('empty input');
  }

  final doc = PdfDoc(original)..load();

  if (doc.trailer!.v.containsKey('Encrypt')) {
    throw PdfWatermarkException('encrypted PDFs are not supported');
  }

  final rootRef = doc.trailer!.v['Root'];
  if (rootRef is! PRef) throw PdfWatermarkException('missing /Root');
  final root = doc.obj(rootRef.num);
  if (root is! PDict) throw PdfWatermarkException('malformed /Root');
  final pagesRef = root.v['Pages'];
  if (pagesRef is! PRef) throw PdfWatermarkException('missing /Pages');

  final pages = collectPages(doc, pagesRef.num);
  var next = doc.maxObjNum() + 1;
  final newObjs = <int, P>{};

  // ---- Split RGBA into RGB + alpha.

  final rgba = raster.rgba;
  final n = raster.width * raster.height;
  final rgb = Uint8List(n * 3);
  final alpha = Uint8List(n);
  for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    rgb[j] = rgba[i];
    rgb[j + 1] = rgba[i + 1];
    rgb[j + 2] = rgba[i + 2];
    alpha[j ~/ 3] = rgba[i + 3];
  }

  final rgbZ = deflateBytes(rgb);
  final alphaZ = deflateBytes(alpha);

  // ---- SMask (grayscale alpha channel).

  final smaskNum = next++;
  newObjs[smaskNum] = PStream(
    PDict({
      'Type': const PName('XObject'),
      'Subtype': const PName('Image'),
      'Width': PNum(raster.width),
      'Height': PNum(raster.height),
      'ColorSpace': const PName('DeviceGray'),
      'BitsPerComponent': const PNum(8),
      'Filter': const PName('FlateDecode'),
    }),
    alphaZ,
  );

  // ---- RGB image XObject.

  final imageNum = next++;
  newObjs[imageNum] = PStream(
    PDict({
      'Type': const PName('XObject'),
      'Subtype': const PName('Image'),
      'Width': PNum(raster.width),
      'Height': PNum(raster.height),
      'ColorSpace': const PName('DeviceRGB'),
      'BitsPerComponent': const PNum(8),
      'Filter': const PName('FlateDecode'),
      'SMask': PRef(smaskNum, 0),
    }),
    rgbZ,
  );

  // ---- Reset stream: pop any leftover q/Q pairs from the original.

  final resetNum = next++;
  newObjs[resetNum] = PStream(
    const PDict({}),
    Uint8List.fromList(
      // Pop up to 64 leftover graphics-state saves (fixes inherited
      // CTM, blend modes, clip paths).
      utf8.encode('Q\n' * 64 +
          // Close up to 64 leftover marked-content sections (fixes
          // OCG / transparency-group leakage where our drawing gets
          // pulled into a layer that renders behind page content).
          'EMC\n' * 64),
    ),
  );

  // ---- Build per-page content streams.

  final contentNums = <int, int>{};
  for (final pn in pages) {
    final page = doc.obj(pn);
    if (page is! PDict) continue;

    final boxRaw =
        inherited(doc, pn, 'CropBox') ?? inherited(doc, pn, 'MediaBox');
    final box = boxRaw is PArr && boxRaw.v.length >= 4
        ? boxRaw.v.map((e) => (e as PNum).v.toDouble()).toList()
        : <double>[0, 0, 612, 792];

    var rot = (inherited(doc, pn, 'Rotate') as PNum?)?.v.toInt() ?? 0;
    rot = ((rot % 360) + 360) % 360;

    final cm = _unitSquareToBox(rot, box[0], box[1], box[2], box[3]);
    final stream = 'q\n$cm cm\n/Im_WM Do\nQ\n';

    final contentNum = next++;
    contentNums[pn] = contentNum;
    newObjs[contentNum] = PStream(
      const PDict({}),
      Uint8List.fromList(utf8.encode(stream)),
    );
  }

  // ---- Rewrite page dicts.

  for (final pn in pages) {
    final page = doc.obj(pn);
    if (page is! PDict) continue;

    final resRaw = inherited(doc, pn, 'Resources');
    final res = <String, P>{};
    if (resRaw is PDict) res.addAll(resRaw.v);

    final xobjs = <String, P>{};
    if (res['XObject'] is PDict) xobjs.addAll((res['XObject'] as PDict).v);
    xobjs['Im_WM'] = PRef(imageNum, 0);
    res['XObject'] = PDict(xobjs);

    final oldC = page.v['Contents'];
    final list = <P>[];
    if (oldC is PArr) {
      list.addAll(oldC.v);
    } else if (oldC != null) {
      list.add(oldC);
    }
    list.add(PRef(resetNum, 0));
    list.add(PRef(contentNums[pn]!, 0));

    final newPage = Map<String, P>.from(page.v);
    newPage['Contents'] = PArr(list);
    newPage['Resources'] = PDict(res);
    newObjs[pn] = PDict(newPage);
  }

  return _writeUpdate(original, doc, newObjs, next, rootRef);
}

// ============================================================ CM HELPERS

/// CM that maps the image unit square [0,1]² to the page's visible box,
/// compensating for /Rotate so the image appears upright to a viewer.
String _unitSquareToBox(
    int rotate, double x0, double y0, double x1, double y1) {
  final w = x1 - x0;
  final h = y1 - y0;
  String f(double v) => v.toStringAsFixed(4);

  switch (rotate) {
    case 90:
      return '0 ${f(h)} ${f(-w)} 0 ${f(x0 + w)} ${f(y0)}';
    case 180:
      return '${f(-w)} 0 0 ${f(-h)} ${f(x0 + w)} ${f(y0 + h)}';
    case 270:
      return '0 ${f(-h)} ${f(w)} 0 ${f(x0)} ${f(y0 + h)}';
    default:
      return '${f(w)} 0 0 ${f(h)} ${f(x0)} ${f(y0)}';
  }
}

// ============================================================ WRITER

Uint8List _writeUpdate(
  Uint8List orig,
  PdfDoc doc,
  Map<int, P> objs,
  int size,
  PRef root,
) {
  final out = BytesBuilder();
  out.add(orig);
  if (orig.isNotEmpty && orig.last != 10) out.addByte(10);

  final nums = objs.keys.toList()..sort();
  final offs = <int, int>{};
  for (final n in nums) {
    offs[n] = out.length;
    out.add(ascii.encode('$n 0 obj\n'));
    writeObj(out, objs[n]!);
    out.add(ascii.encode('\nendobj\n'));
  }

  final xrefOff = out.length;
  final sb = StringBuffer('xref\n0 1\n0000000000 65535 f \n');
  var i = 0;
  while (i < nums.length) {
    var j = i;
    while (j + 1 < nums.length && nums[j + 1] == nums[j] + 1) {
      j++;
    }
    sb.write('${nums[i]} ${j - i + 1}\n');
    for (var k = i; k <= j; k++) {
      sb.write('${offs[nums[k]]!.toString().padLeft(10, '0')} 00000 n \n');
    }
    i = j + 1;
  }

  final tr = <String, P>{};
  for (final k in ['Info', 'ID']) {
    final v = doc.trailer!.v[k];
    if (v != null) tr[k] = v;
  }
  tr['Size'] = PNum(size);
  tr['Root'] = root;
  if (doc.startXrefOffset >= 0) {
    tr['Prev'] = PNum(doc.startXrefOffset);
  }

  sb.write('trailer\n<< ');
  tr.forEach((k, v) {
    sb.write('/$k ');
    final tmp = BytesBuilder();
    writeObj(tmp, v);
    sb.write(ascii.decode(tmp.takeBytes()));
    sb.write(' ');
  });
  sb.write('>>\nstartxref\n$xrefOff\n%%EOF\n');
  out.add(ascii.encode(sb.toString()));

  return out.takeBytes();
}
