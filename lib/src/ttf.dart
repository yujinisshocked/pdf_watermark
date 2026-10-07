import 'dart:typed_data';

import 'exceptions.dart';

class _TableRec {
  final int offset, length;
  const _TableRec(this.offset, this.length);
}

/// Minimal TrueType parser. Extracts only what a PDF embedder needs:
/// cmap lookup, advance widths, unitsPerEm, bbox, and the PS name.
class TtfFont {
  final Uint8List data;
  final int unitsPerEm;
  final List<int> advanceWidths; // by glyph id, in font units
  final Map<int, int> cmap;      // codepoint -> glyph id
  final String postScriptName;
  final int xMin, yMin, xMax, yMax;
  final int ascent, descent;

  TtfFont._({
    required this.data,
    required this.unitsPerEm,
    required this.advanceWidths,
    required this.cmap,
    required this.postScriptName,
    required this.xMin,
    required this.yMin,
    required this.xMax,
    required this.yMax,
    required this.ascent,
    required this.descent,
  });

  int? glyphFor(int codepoint) => cmap[codepoint];

  int advanceFor(int glyphId) =>
      glyphId >= 0 && glyphId < advanceWidths.length ? advanceWidths[glyphId] : 0;

  static TtfFont parse(Uint8List data) {
    if (data.length < 12) throw PdfWatermarkException('font data too short');
    final bd = ByteData.sublistView(data);
    final sfnt = bd.getUint32(0);

    if (sfnt == 0x74746366) {
      throw PdfWatermarkException('TTC font collections not supported');
    }
    if (sfnt == 0x4F54544F) {
      throw PdfWatermarkException(
          'CFF-based OpenType (.otf) not supported; use a TrueType (.ttf)');
    }
    if (sfnt != 0x00010000 && sfnt != 0x74727565) {
      throw PdfWatermarkException('not a TrueType font');
    }

    final numTables = bd.getUint16(4);
    final tables = <String, _TableRec>{};
    for (var i = 0; i < numTables; i++) {
      final recOff = 12 + i * 16;
      if (recOff + 16 > data.length) break;
      final tag = String.fromCharCodes(data.sublist(recOff, recOff + 4));
      final off = bd.getUint32(recOff + 8);
      final len = bd.getUint32(recOff + 12);
      if (off + len > data.length) continue;
      tables[tag] = _TableRec(off, len);
    }

    final head = tables['head'];
    final hhea = tables['hhea'];
    final maxp = tables['maxp'];
    final hmtx = tables['hmtx'];
    final cmapT = tables['cmap'];
    if (head == null || hhea == null || maxp == null || hmtx == null || cmapT == null) {
      throw PdfWatermarkException('font missing required tables');
    }

    final unitsPerEm = bd.getUint16(head.offset + 18);
    if (unitsPerEm == 0) throw PdfWatermarkException('font has unitsPerEm=0');

    final xMin = bd.getInt16(head.offset + 36);
    final yMin = bd.getInt16(head.offset + 38);
    final xMax = bd.getInt16(head.offset + 40);
    final yMax = bd.getInt16(head.offset + 42);

    final numGlyphs = bd.getUint16(maxp.offset + 4);
    final numberOfHMetrics = bd.getUint16(hhea.offset + 34);
    final ascent = bd.getInt16(hhea.offset + 4);
    final descent = bd.getInt16(hhea.offset + 6);

    // hmtx: numberOfHMetrics * (advanceWidth, lsb), then (numGlyphs - n) lsbs.
    final widths = List<int>.filled(numGlyphs, 0);
    var lastWidth = 0;
    for (var i = 0; i < numGlyphs; i++) {
      if (i < numberOfHMetrics) {
        final o = hmtx.offset + i * 4;
        if (o + 2 <= data.length) lastWidth = bd.getUint16(o);
      }
      widths[i] = lastWidth;
    }

    final cmap = _parseCmap(data, bd, cmapT.offset);

    var psName = 'EmbeddedFont';
    final nameT = tables['name'];
    if (nameT != null) {
      psName = _parseName(data, bd, nameT.offset) ?? psName;
    }
    psName = psName.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (psName.isEmpty || psName.length > 63) psName = 'EmbeddedFont';

    return TtfFont._(
      data: data,
      unitsPerEm: unitsPerEm,
      advanceWidths: widths,
      cmap: cmap,
      postScriptName: psName,
      xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax,
      ascent: ascent, descent: descent,
    );
  }

  static Map<int, int> _parseCmap(Uint8List data, ByteData bd, int off) {
    if (off + 4 > data.length) throw PdfWatermarkException('bad cmap');
    final numTables = bd.getUint16(off + 2);
    int? bestOff;
    var bestScore = -1;
    for (var i = 0; i < numTables; i++) {
      final rec = off + 4 + i * 8;
      if (rec + 8 > data.length) break;
      final plat = bd.getUint16(rec);
      final enc = bd.getUint16(rec + 2);
      final subOff = off + bd.getUint32(rec + 4);
      if (subOff + 2 > data.length) continue;
      final format = bd.getUint16(subOff);
      var score = 0;
      if (plat == 3 && enc == 10 && format == 12) {
        score = 100;
      } else if (plat == 0 && enc >= 4 && format == 12) {
        score = 95;
      } else if (plat == 3 && enc == 1 && format == 4) {
        score = 90;
      } else if (plat == 0 && format == 4) {
        score = 80;
      } else if (format == 4) {
        score = 50;
      } else if (format == 12) {
        score = 40;
      }
      if (score > bestScore) {
        bestScore = score;
        bestOff = subOff;
      }
    }
    if (bestOff == null) {
      throw PdfWatermarkException('no usable cmap subtable');
    }
    final fmt = bd.getUint16(bestOff);
    if (fmt == 4) return _parseCmap4(data, bd, bestOff);
    if (fmt == 12) return _parseCmap12(data, bd, bestOff);
    throw PdfWatermarkException('unsupported cmap format $fmt');
  }

  static Map<int, int> _parseCmap4(Uint8List data, ByteData bd, int off) {
    final segCountX2 = bd.getUint16(off + 6);
    final segCount = segCountX2 ~/ 2;
    final endOff = off + 14;
    final startOff = endOff + segCountX2 + 2;
    final deltaOff = startOff + segCountX2;
    final rangeOff = deltaOff + segCountX2;

    final out = <int, int>{};
    for (var s = 0; s < segCount; s++) {
      final end = bd.getUint16(endOff + s * 2);
      final start = bd.getUint16(startOff + s * 2);
      final delta = bd.getInt16(deltaOff + s * 2);
      final range = bd.getUint16(rangeOff + s * 2);
      if (start == 0xFFFF) continue;
      for (var c = start; c <= end; c++) {
        int g;
        if (range == 0) {
          g = (c + delta) & 0xFFFF;
        } else {
          final idx = rangeOff + s * 2 + range + (c - start) * 2;
          if (idx + 2 > data.length) continue;
          g = bd.getUint16(idx);
          if (g != 0) g = (g + delta) & 0xFFFF;
        }
        if (g != 0) out[c] = g;
      }
    }
    return out;
  }

  static Map<int, int> _parseCmap12(Uint8List data, ByteData bd, int off) {
    final nGroups = bd.getUint32(off + 12);
    final out = <int, int>{};
    for (var i = 0; i < nGroups; i++) {
      final g = off + 16 + i * 12;
      if (g + 12 > data.length) break;
      final start = bd.getUint32(g);
      final end = bd.getUint32(g + 4);
      final startGlyph = bd.getUint32(g + 8);
      // Guard against pathological ranges; we only ever need a few hundred.
      if (end - start > 0x20000) continue;
      for (var c = start; c <= end; c++) {
        out[c] = startGlyph + (c - start);
      }
    }
    return out;
  }

  static String? _parseName(Uint8List data, ByteData bd, int off) {
    final count = bd.getUint16(off + 2);
    final stringOff = off + bd.getUint16(off + 4);
    for (var i = 0; i < count; i++) {
      final rec = off + 6 + i * 12;
      if (rec + 12 > data.length) break;
      final plat = bd.getUint16(rec);
      final enc = bd.getUint16(rec + 2);
      final nameId = bd.getUint16(rec + 6);
      final len = bd.getUint16(rec + 8);
      final strOff = stringOff + bd.getUint16(rec + 10);
      if (nameId != 6) continue;
      if (strOff + len > data.length) continue;
      if (plat == 3 && (enc == 1 || enc == 10)) {
        final sb = StringBuffer();
        for (var j = 0; j + 1 < len; j += 2) {
          sb.writeCharCode(bd.getUint16(strOff + j));
        }
        return sb.toString();
      }
    }
    return null;
  }
}