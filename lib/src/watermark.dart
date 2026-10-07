import 'dart:convert';
import 'dart:typed_data';

import 'exceptions.dart';
import 'pdf_parser.dart';
import 'pdf_writer.dart';
import 'ttf.dart';

/// How the watermark text is laid out on each page.
enum WatermarkStyle {
  /// One big diagonal word across the page.
  diagonal,

  /// Tiled brick-lay pattern covering the whole page.
  tiled,
}

// ==================================================== BASE-14 METRICS

/// Helvetica AFM advance widths for ASCII 0x20..0x7E, in 1/1000 em.
const List<int> _helvWidths = [
  278,
  278,
  355,
  556,
  556,
  889,
  667,
  191,
  333,
  333,
  389,
  584,
  278,
  333,
  278,
  278,
  556,
  556,
  556,
  556,
  556,
  556,
  556,
  556,
  556,
  556,
  278,
  278,
  584,
  584,
  584,
  556,
  1015,
  667,
  667,
  722,
  722,
  667,
  611,
  778,
  722,
  278,
  500,
  667,
  556,
  833,
  722,
  778,
  667,
  778,
  722,
  667,
  611,
  722,
  667,
  944,
  667,
  667,
  611,
  278,
  278,
  278,
  469,
  556,
  333,
  556,
  556,
  500,
  556,
  556,
  278,
  556,
  556,
  222,
  222,
  500,
  222,
  833,
  556,
  556,
  556,
  556,
  333,
  500,
  278,
  556,
  500,
  722,
  500,
  500,
  500,
  334,
  260,
  334,
  584,
];

double _helvWidth(String s, double fontSize) {
  var total = 0;
  for (final r in s.runes) {
    total += (r >= 0x20 && r <= 0x7E) ? _helvWidths[r - 0x20] : 556;
  }
  return total * fontSize / 1000.0;
}

// ==================================================== TEXT ESCAPING

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

// ==================================================== FONT STATE

/// Knows how to turn a Dart string into a PDF text operand and how wide
/// the result will be. Base-14 path uses Helvetica AFM; embedded path
/// uses glyph IDs and the TTF's own advance widths.
class _FontState {
  final TtfFont? ttf;
  final Set<int> usedGlyphs;
  _FontState(this.ttf, this.usedGlyphs);

  int _glyphFor(int cp) {
    if (ttf == null) return 0;
    final g = ttf!.glyphFor(cp) ?? ttf!.glyphFor(0x3F) ?? 0;
    usedGlyphs.add(g);
    return g;
  }

  String textOperand(String s) {
    if (ttf == null) return '(${_escStr(s)})';
    final b = StringBuffer('<');
    for (final r in s.runes) {
      b.write(_glyphFor(r).toRadixString(16).padLeft(4, '0'));
    }
    b.write('>');
    return b.toString();
  }

  double textWidth(String s, double fontSize) {
    if (ttf == null) return _helvWidth(s, fontSize);
    var total = 0;
    for (final r in s.runes) {
      final g = ttf!.glyphFor(r) ?? ttf!.glyphFor(0x3F) ?? 0;
      total += ttf!.advanceFor(g);
    }
    return total * fontSize / ttf!.unitsPerEm;
  }
}

// ==================================================== CONTENT BUILDERS

String _buildDiagonalContent(
  _FontState fs,
  String text,
  double x0,
  double y0,
  double x1,
  double y1, {
  required double fontSize,
  required double gray,
}) {
  final cx = (x0 + x1) / 2;
  final cy = (y0 + y1) / 2;
  const c = 0.70710678118, s = 0.70710678118;
  final w = fs.textWidth(text, fontSize);
  final operand = fs.textOperand(text);
  final g = gray.toStringAsFixed(3);
  return 'q\n'
      '/GS_WM gs\n'
      '$g $g $g rg\n'
      'BT\n'
      '/F_WM ${fontSize.toStringAsFixed(2)} Tf\n'
      '$c $s ${-s} $c ${cx.toStringAsFixed(2)} ${cy.toStringAsFixed(2)} Tm\n'
      '${(-w / 2).toStringAsFixed(2)} ${(-fontSize / 3).toStringAsFixed(2)} Td\n'
      '$operand Tj\n'
      'ET\n'
      'Q\n';
}

String _buildTiledContent(
  _FontState fs,
  String text,
  double x0,
  double y0,
  double x1,
  double y1, {
  required double fontSize,
  required double gapX,
  required double gapY,
  required double gray,
}) {
  final w = x1 - x0;
  final h = y1 - y0;
  final textWidth = fs.textWidth(text, fontSize);
  final spacingX = textWidth + gapX;
  final spacingY = fontSize + gapY;
  final operand = fs.textOperand(text);
  final g = gray.toStringAsFixed(3);

  final b = StringBuffer();
  b.writeln('q');
  b.writeln('/GS_WM gs');
  b.writeln('$g $g $g rg');
  b.writeln('BT');
  b.writeln('/F_WM ${fontSize.toStringAsFixed(2)} Tf');

  var row = 0;
  for (double y = -spacingY; y < h + spacingY; y += spacingY) {
    final offsetX = (row & 1) == 1 ? (spacingX / 2) : 0.0;
    for (double x = -spacingX + offsetX; x < w + spacingX; x += spacingX) {
      final fx = x0 + x;
      final fy = y0 + y;
      b.writeln('1 0 0 1 ${fx.toStringAsFixed(2)} ${fy.toStringAsFixed(2)} Tm');
      b.writeln('$operand Tj');
    }
    row++;
  }

  b.writeln('ET');
  b.writeln('Q');
  return b.toString();
}

// ==================================================== BACKWARDS-COMPAT API

/// Single rotated word across the rectangle. Base-14 Helvetica only.
/// Kept for callers who use it directly; not used internally anymore.
String buildWatermark(String text, double x0, double y0, double x1, double y1) {
  final fs = _FontState(null, {});
  return _buildDiagonalContent(
    fs,
    text,
    x0,
    y0,
    x1,
    y1,
    fontSize: 60,
    gray: 0.85,
  );
}

// ==================================================== TOUNICODE CMap

String _utf16Surrogates(int cp) {
  if (cp <= 0xFFFF) return cp.toRadixString(16).padLeft(4, '0');
  final v = cp - 0x10000;
  final hi = 0xD800 + (v >> 10);
  final lo = 0xDC00 + (v & 0x3FF);
  return hi.toRadixString(16).padLeft(4, '0') +
      lo.toRadixString(16).padLeft(4, '0');
}

String _buildToUnicode(Map<int, int> gidToCp) {
  final b = StringBuffer();
  b.writeln('/CIDInit /ProcSet findresource begin');
  b.writeln('12 dict begin');
  b.writeln('begincmap');
  b.writeln('/CIDSystemInfo <<');
  b.writeln('  /Registry (Adobe)');
  b.writeln('  /Ordering (UCS)');
  b.writeln('  /Supplement 0');
  b.writeln('>> def');
  b.writeln('/CMapName /Adobe-Identity-UCS def');
  b.writeln('/CMapType 2 def');
  b.writeln('1 begincodespacerange');
  b.writeln('<0000> <FFFF>');
  b.writeln('endcodespacerange');

  final entries = gidToCp.entries.toList();
  for (var i = 0; i < entries.length; i += 100) {
    final end = (i + 100) > entries.length ? entries.length : i + 100;
    final chunk = entries.sublist(i, end);
    b.writeln('${chunk.length} beginbfchar');
    for (final e in chunk) {
      final g = e.key.toRadixString(16).padLeft(4, '0');
      b.writeln('<$g> <${_utf16Surrogates(e.value)}>');
    }
    b.writeln('endbfchar');
  }

  b.writeln('endcmap');
  b.writeln('CMapName currentdict /CMap defineresource pop');
  b.writeln('end');
  b.writeln('end');
  return b.toString();
}

// ==================================================== PUBLIC API

/// Watermark every page of [original] with [text].
///
/// If [font] is null, Helvetica (WinAnsi) is used and only Latin-1 text
/// renders. Pass TrueType bytes for [font] to use a custom font with full
/// Unicode support (via Identity-H CID encoding).
///
/// [style] selects the layout, [fontSize] is in points, [opacity] is 0..1.
Uint8List watermarkPdf(
  Uint8List original, {
  required String text,
  WatermarkStyle style = WatermarkStyle.diagonal,
  double fontSize = 60,
  double opacity = 0.3,
  double gray = 0.6,
  double gapX = 8,
  double gapY = 6,
  Uint8List? font,
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

  final ttf = font == null ? null : TtfFont.parse(font);

  // Allocate object numbers up front so page dicts can reference the font
  // before the font's contents are fully built (needs the used-glyph set).
  final fontObjNum = next++;
  final gsNum = next++;
  int? fontFileNum, fontDescNum, cidFontNum, toUnicodeNum;
  if (ttf != null) {
    fontFileNum = next++;
    fontDescNum = next++;
    cidFontNum = next++;
    toUnicodeNum = next++;
  }

  final usedGlyphs = <int>{};
  final fs = _FontState(ttf, usedGlyphs);
  final newObjs = <int, P>{};

  // ---- Pass 1: build content streams, collect used glyphs.

  final contentNums = <int, int>{};
  for (final pn in pages) {
    final page = doc.obj(pn);
    if (page is! PDict) continue;

    final mbRaw = inherited(doc, pn, 'MediaBox');
    final mb = mbRaw is PArr && mbRaw.v.length >= 4
        ? mbRaw.v.map((e) => (e as PNum).v.toDouble()).toList()
        : <double>[0, 0, 612, 792];

    final stream = switch (style) {
      WatermarkStyle.diagonal => _buildDiagonalContent(
          fs,
          text,
          mb[0],
          mb[1],
          mb[2],
          mb[3],
          fontSize: fontSize,
          gray: gray,
        ),
      WatermarkStyle.tiled => _buildTiledContent(
          fs,
          text,
          mb[0],
          mb[1],
          mb[2],
          mb[3],
          fontSize: fontSize,
          gapX: gapX,
          gapY: gapY,
          gray: gray,
        ),
    };

    final contentNum = next++;
    contentNums[pn] = contentNum;
    newObjs[contentNum] = PStream(
      const PDict({}),
      Uint8List.fromList(utf8.encode(stream)),
    );
  }

  // ---- Pass 2: build the font objects.

  if (ttf == null) {
    newObjs[fontObjNum] = PDict({
      'Type': const PName('Font'),
      'Subtype': const PName('Type1'),
      'BaseFont': const PName('Helvetica'),
      'Encoding': const PName('WinAnsiEncoding'),
    });
  } else {
    final scale = 1000.0 / ttf.unitsPerEm;

    // Reverse map for /ToUnicode: GID -> codepoint.
    final reverse = <int, int>{};
    for (final r in text.runes) {
      final g = ttf.glyphFor(r) ?? ttf.glyphFor(0x3F);
      if (g != null) reverse[g] = r;
    }

    newObjs[fontFileNum!] = PStream(
      PDict({'Length1': PNum(ttf.data.length)}),
      ttf.data,
    );

    newObjs[fontDescNum!] = PDict({
      'Type': const PName('FontDescriptor'),
      'FontName': PName(ttf.postScriptName),
      'Flags': const PNum(32), // Nonsymbolic
      'FontBBox': PArr([
        PNum((ttf.xMin * scale).round()),
        PNum((ttf.yMin * scale).round()),
        PNum((ttf.xMax * scale).round()),
        PNum((ttf.yMax * scale).round()),
      ]),
      'ItalicAngle': const PNum(0),
      'Ascent': PNum((ttf.ascent * scale).round()),
      'Descent': PNum((ttf.descent * scale).round()),
      'CapHeight': PNum((ttf.ascent * scale * 0.7).round()),
      'StemV': const PNum(80),
      'FontFile2': PRef(fontFileNum, 0),
    });

    // /W array: [ gid1 [w1] gid2 [w2] ... ], widths in 1000-unit em.
    final wArr = <P>[];
    final gids = usedGlyphs.toList()..sort();
    for (final g in gids) {
      final w = (ttf.advanceFor(g) * scale).round();
      wArr.add(PNum(g));
      wArr.add(PArr([PNum(w)]));
    }

    newObjs[cidFontNum!] = PDict({
      'Type': const PName('Font'),
      'Subtype': const PName('CIDFontType2'),
      'BaseFont': PName(ttf.postScriptName),
      'CIDSystemInfo': PDict({
        'Registry': PStr(Uint8List.fromList(ascii.encode('Adobe'))),
        'Ordering': PStr(Uint8List.fromList(ascii.encode('Identity'))),
        'Supplement': const PNum(0),
      }),
      'FontDescriptor': PRef(fontDescNum, 0),
      'DW': const PNum(1000),
      'W': PArr(wArr),
      'CIDToGIDMap': const PName('Identity'),
    });

    newObjs[toUnicodeNum!] = PStream(
      const PDict({}),
      Uint8List.fromList(utf8.encode(_buildToUnicode(reverse))),
    );

    newObjs[fontObjNum] = PDict({
      'Type': const PName('Font'),
      'Subtype': const PName('Type0'),
      'BaseFont': PName(ttf.postScriptName),
      'Encoding': const PName('Identity-H'),
      'DescendantFonts': PArr([PRef(cidFontNum, 0)]),
      'ToUnicode': PRef(toUnicodeNum, 0),
    });
  }

  newObjs[gsNum] = PDict({
    'Type': const PName('ExtGState'),
    'ca': PNum(opacity),
    'CA': PNum(opacity),
  });

  // ---- Pass 3: rewrite page dicts.

  for (final pn in pages) {
    final page = doc.obj(pn);
    if (page is! PDict) continue;

    final resRaw = inherited(doc, pn, 'Resources');
    final res = <String, P>{};
    if (resRaw is PDict) res.addAll(resRaw.v);

    final fonts = <String, P>{};
    if (res['Font'] is PDict) fonts.addAll((res['Font'] as PDict).v);
    fonts['F_WM'] = PRef(fontObjNum, 0);
    res['Font'] = PDict(fonts);

    final gs = <String, P>{};
    if (res['ExtGState'] is PDict) gs.addAll((res['ExtGState'] as PDict).v);
    gs['GS_WM'] = PRef(gsNum, 0);
    res['ExtGState'] = PDict(gs);

    final oldC = page.v['Contents'];
    final contentNum = contentNums[pn]!;
    final newC =
        oldC == null ? PRef(contentNum, 0) : PArr([oldC, PRef(contentNum, 0)]);

    final newPage = Map<String, P>.from(page.v);
    newPage['Contents'] = newC;
    newPage['Resources'] = PDict(res);
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
