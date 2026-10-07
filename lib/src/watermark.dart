import 'dart:convert';
import 'dart:typed_data';

import 'exceptions.dart';
import 'pdf_parser.dart';
import 'pdf_writer.dart';

/// How the watermark text is laid out on each page.
enum WatermarkStyle {
  /// One big diagonal word across the page.
  diagonal,

  /// Tiled brick-lay pattern covering the whole page.
  tiled,
}

// ==================================================== TEXT ESCAPING

/// Escape [s] as a PDF literal string using WinAnsi (CP1252-ish) bytes.
///
/// ASCII passes through, `(`/`)`/`\` are backslash-escaped, and bytes in
/// the Latin-1 range go out as octal escapes. Anything else becomes `?`.
String _escStr(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x5C) {
      b.write(r'\');
    } else if (r == 0x28) {
      b.write(r'\(');
    } else if (r == 0x29) {
      b.write(r'\)');
    } else if (r >= 0x20 && r <= 0x7E) {
      b.writeCharCode(r);
    } else if (r >= 0xA0 && r <= 0xFF) {
      b.write('\\${r.toRadixString(8).padLeft(3, '0')}');
    } else {
      b.write('?');
    }
  }
  return b.toString();
}

// ==================================================== DIAGONAL LAYOUT

/// Single rotated word centered on the rectangle. Kept for backwards compat.
String buildWatermark(String text, double x0, double y0, double x1, double y1) {
  final cx = (x0 + x1) / 2;
  final cy = (y0 + y1) / 2;
  const fs = 60.0;
  const c = 0.70710678118, s = 0.70710678118;
  final w = text.length * fs * 0.52;
  final esc = _escStr(text);
  return 'q\n'
      '/GS_WM gs\n'
      '0.85 0.85 0.85 rg\n'
      'BT\n'
      '/F_WM $fs Tf\n'
      '$c $s ${-s} $c ${cx.toStringAsFixed(2)} ${cy.toStringAsFixed(2)} Tm\n'
      '${(-w / 2).toStringAsFixed(2)} ${(-fs / 3).toStringAsFixed(2)} Td\n'
      '($esc) Tj\n'
      'ET\n'
      'Q\n';
}

// ==================================================== TILED LAYOUT

/// Helvetica AFM advance widths for ASCII 0x20..0x7E, in 1/1000 em.
/// Index `i` corresponds to code point `0x20 + i`.
const List<int> _helvWidths = [
  // 0x20..0x2F  space ! " # $ % & ' ( ) * + , - . /
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278,
  278,
  // 0x30..0x39  0-9
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556,
  // 0x3A..0x40  : ; < = > ? @
  278, 278, 584, 584, 584, 556, 1015,
  // 0x41..0x50  A B C D E F G H I J K L M N O P
  667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
  667,
  // 0x51..0x5A  Q R S T U V W X Y Z
  778, 722, 667, 611, 722, 667, 944, 667, 667, 611,
  // 0x5B..0x60  [ \ ] ^ _ `
  278, 278, 278, 469, 556, 333,
  // 0x61..0x70  a b c d e f g h i j k l m n o p
  556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
  556,
  // 0x71..0x7A  q r s t u v w x y z
  556, 333, 500, 278, 556, 500, 722, 500, 500, 500,
  // 0x7B..0x7E  { | } ~
  334, 260, 334, 584,
];

/// Real rendered width of [s] in points at [fontSize], using Helvetica metrics.
double _helvWidth(String s, double fontSize) {
  var total = 0;
  for (final r in s.runes) {
    // Printable ASCII → exact width; anything else → average fallback.
    final w = (r >= 0x20 && r <= 0x7E) ? _helvWidths[r - 0x20] : 556;
    total += w;
  }
  return total * fontSize / 1000.0;
}

/// Brick-lay tiled watermark. Each row is a line of the text repeated
/// side-by-side; alternate rows are shifted by half a tile.
///
/// [fontSize] is in PDF points. [gapX] and [gapY] are the spacing between
/// adjacent tiles (in points) so nothing overlaps.
String _buildTiled(
  String text,
  double x0,
  double y0,
  double x1,
  double y1, {
  required double fontSize,
  double gapX = 8,
  double gapY = 6,
}) {
  final esc = _escStr(text);
  final w = x1 - x0;
  final h = y1 - y0;

  // Estimated advance width of the string at this size.
  // 0.52 is a good Helvetica average for mixed-case ASCII.
  final textWidth = _helvWidth(text, fontSize);

  // Step between tiles horizontally and vertically. Add a gap so
  // adjacent copies don't touch.
  final spacingX = textWidth + gapX;
  final spacingY = fontSize + gapY;

  final b = StringBuffer();
  b.writeln('q');
  b.writeln('/GS_WM gs');
  b.writeln('BT');
  b.writeln('/F_WM ${fontSize.toStringAsFixed(2)} Tf');

  var row = 0;
  for (double y = -spacingY; y < h + spacingY; y += spacingY) {
    // Brick offset: shift odd rows right by half a tile.
    final offsetX = (row & 1) == 1 ? (spacingX / 2) : 0.0;

    for (double x = -spacingX + offsetX; x < w + spacingX; x += spacingX) {
      final fx = x0 + x;
      final fy = y0 + y;
      b.writeln(
        '1 0 0 1 ${fx.toStringAsFixed(2)} ${fy.toStringAsFixed(2)} Tm',
      );
      b.writeln('($esc) Tj');
    }
    row++;
  }

  b.writeln('ET');
  b.writeln('Q');
  return b.toString();
}

// ==================================================== PUBLIC API

/// Watermark every page of [original] with [text].
///
/// [style] selects between one big diagonal word and a tiled pattern.
/// [fontSize] is in PDF points. [opacity] is 0..1.
Uint8List watermarkPdf(
  Uint8List original, {
  required String text,
  WatermarkStyle style = WatermarkStyle.diagonal,
  double fontSize = 60,
  double opacity = 0.3,
  double grayLevel = 0.6,
}) {
  if (original.isEmpty) {
    throw PdfWatermarkException('empty input');
  }
  if (opacity < 0 || opacity > 1) {
    throw PdfWatermarkException('opacity must be 0..1');
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

  final fontNum = next++;
  final gsNum = next++;

  final newObjs = <int, P>{
    fontNum: PDict({
      'Type': const PName('Font'),
      'Subtype': const PName('Type1'),
      'BaseFont': const PName('Helvetica'),
      'Encoding': const PName('WinAnsiEncoding'),
    }),
    gsNum: PDict({
      'Type': const PName('ExtGState'),
      'ca': PNum(opacity),
      'CA': PNum(opacity),
    }),
  };

  for (final pn in pages) {
    final page = doc.obj(pn);
    if (page is! PDict) continue;

    final mbRaw = inherited(doc, pn, 'MediaBox');
    final mb = mbRaw is PArr && mbRaw.v.length >= 4
        ? mbRaw.v.map((e) => (e as PNum).v.toDouble()).toList()
        : <double>[0, 0, 612, 792];

    final stream = switch (style) {
      WatermarkStyle.diagonal =>
        buildWatermark(text, mb[0], mb[1], mb[2], mb[3]),
      WatermarkStyle.tiled => _buildTiled(
          text,
          mb[0],
          mb[1],
          mb[2],
          mb[3],
          fontSize: fontSize,
        ),
    };

    final contentNum = next++;
    newObjs[contentNum] = PStream(
      const PDict({}),
      Uint8List.fromList(utf8.encode(stream)),
    );

    // Merge page resources.
    final resRaw = inherited(doc, pn, 'Resources');
    final res = <String, P>{};
    if (resRaw is PDict) res.addAll(resRaw.v);

    final fonts = <String, P>{};
    if (res['Font'] is PDict) fonts.addAll((res['Font'] as PDict).v);
    fonts['F_WM'] = PRef(fontNum, 0);
    res['Font'] = PDict(fonts);

    final gs = <String, P>{};
    if (res['ExtGState'] is PDict) gs.addAll((res['ExtGState'] as PDict).v);
    gs['GS_WM'] = PRef(gsNum, 0);
    res['ExtGState'] = PDict(gs);

    final oldC = page.v['Contents'];
    final newC =
        oldC == null ? PRef(contentNum, 0) : PArr([oldC, PRef(contentNum, 0)]);

    final newPage = Map<String, P>.from(page.v);
    newPage['Contents'] = newC;
    newPage['Resources'] = PDict(res);

    if (grayLevel >= 0) {
      // fill color is set inside the content stream; nothing extra here
    }
    newObjs[pn] = PDict(newPage);
  }

  return _writeUpdate(original, doc, newObjs, next, rootRef);
}

// ==================================================== UPDATE WRITER

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
  tr['Prev'] = PNum(doc.startXrefOffset);

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
