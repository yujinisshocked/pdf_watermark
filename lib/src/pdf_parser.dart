import 'dart:convert';
import 'dart:typed_data';

import 'exceptions.dart';
import 'inflate.dart';

// ============================================================ VALUES

sealed class P {
  const P();
}

class PNull extends P {
  const PNull();
}

class PBool extends P {
  final bool v;
  const PBool(this.v);
}

class PNum extends P {
  final num v;
  const PNum(this.v);
}

class PName extends P {
  final String v;
  const PName(this.v);
}

class PStr extends P {
  final Uint8List v;
  const PStr(this.v);
}

class PArr extends P {
  final List<P> v;
  const PArr(this.v);
}

class PDict extends P {
  final Map<String, P> v;
  const PDict(this.v);
}

class PRef extends P {
  final int num, gen;
  const PRef(this.num, this.gen);
}

class PStream extends P {
  final PDict dict;
  final Uint8List raw;
  PStream(this.dict, this.raw);

  Uint8List? _dec;
  Uint8List decoded() => _dec ??= _decodeStream(this);
}

// ============================================================ PARSER

bool _ws(int c) => c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;

bool _delim(int c) =>
    c == 0x28 || // (
    c == 0x29 || // )
    c == 0x3C || // <
    c == 0x3E || // >
    c == 0x5B || // [
    c == 0x5D || // ]
    c == 0x7B || // {
    c == 0x7D || // }
    c == 0x2F || // /
    c == 0x25; // %

class PdfParser {
  final Uint8List d;
  int p;
  PdfParser(this.d, [this.p = 0]);

  void skipWs() {
    while (p < d.length) {
      final c = d[p];
      if (_ws(c)) {
        p++;
        continue;
      }
      if (c == 0x25) {
        // comment to EOL
        while (p < d.length && d[p] != 10 && d[p] != 13) {
          p++;
        }
        continue;
      }
      break;
    }
  }

  String _token() {
    final s = p;
    while (p < d.length && !_ws(d[p]) && !_delim(d[p])) {
      p++;
    }
    return ascii.decode(d.sublist(s, p));
  }

  P parse() {
    skipWs();
    if (p >= d.length) throw StateError('EOF');
    final c = d[p];
    if (c == 0x2F) return _name();
    if (c == 0x28) return PStr(_literal());
    if (c == 0x5B) return _array();
    if (c == 0x3C) {
      if (p + 1 < d.length && d[p + 1] == 0x3C) return _dict();
      return PStr(_hex());
    }

    final tok = _token();
    if (tok == 'null') return const PNull();
    if (tok == 'true') return const PBool(true);
    if (tok == 'false') return const PBool(false);

    final n = num.tryParse(tok);
    if (n != null) {
      if (n is int && n >= 0) {
        final save = p;
        skipWs();
        final t2 = _token();
        final g = int.tryParse(t2);
        if (g != null && g >= 0) {
          skipWs();
          if (p < d.length && d[p] == 0x52 /* R */) {
            final after = p + 1;
            if (after >= d.length || _ws(d[after]) || _delim(d[after])) {
              p = after;
              return PRef(n, g);
            }
          }
        }
        p = save;
      }
      return PNum(n);
    }
    throw StateError('Unexpected token "$tok" at $p');
  }

  PName _name() {
    p++;
    final b = BytesBuilder();
    while (p < d.length && !_ws(d[p]) && !_delim(d[p])) {
      if (d[p] == 0x23 && p + 2 < d.length) {
        final v =
            int.tryParse(ascii.decode(d.sublist(p + 1, p + 3)), radix: 16);
        if (v != null) {
          b.addByte(v);
          p += 3;
          continue;
        }
      }
      b.addByte(d[p++]);
    }
    return PName(latin1.decode(b.takeBytes()));
  }

  Uint8List _literal() {
    p++;
    final b = BytesBuilder();
    var depth = 1;
    while (p < d.length) {
      final c = d[p++];
      if (c == 0x5C /* \ */) {
        if (p >= d.length) break;
        final e = d[p++];
        const simple = {
          0x6E: 10,
          0x72: 13,
          0x74: 9,
          0x62: 8,
          0x66: 12,
          0x28: 0x28,
          0x29: 0x29,
          0x5C: 0x5C,
        };
        if (simple.containsKey(e)) {
          b.addByte(simple[e]!);
        } else if (e >= 0x30 && e <= 0x37) {
          var v = e - 0x30, k = 1;
          while (k < 3 && p < d.length && d[p] >= 0x30 && d[p] <= 0x37) {
            v = v * 8 + (d[p++] - 0x30);
            k++;
          }
          b.addByte(v & 0xFF);
        } else {
          b.addByte(e);
        }
      } else if (c == 0x28) {
        depth++;
        b.addByte(c);
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        b.addByte(c);
      } else if (c == 13) {
        b.addByte(10);
        if (p < d.length && d[p] == 10) p++;
      } else {
        b.addByte(c);
      }
    }
    return b.takeBytes();
  }

  Uint8List _hex() {
    p++;
    final b = BytesBuilder();
    int? hi;
    while (p < d.length) {
      final c = d[p++];
      if (c == 0x3E) break;
      if (_ws(c)) continue;
      final v = c >= 0x30 && c <= 0x39
          ? c - 0x30
          : c >= 0x41 && c <= 0x46
              ? c - 0x41 + 10
              : c >= 0x61 && c <= 0x66
                  ? c - 0x61 + 10
                  : -1;
      if (v < 0) continue;
      if (hi == null) {
        hi = v;
      } else {
        b.addByte((hi << 4) | v);
        hi = null;
      }
    }
    if (hi != null) b.addByte(hi << 4);
    return b.takeBytes();
  }

  PArr _array() {
    p++;
    final out = <P>[];
    while (true) {
      skipWs();
      if (p >= d.length) break;
      if (d[p] == 0x5D) {
        p++;
        break;
      }
      out.add(parse());
    }
    return PArr(out);
  }

  PDict _dict() {
    p += 2;
    final m = <String, P>{};
    while (true) {
      skipWs();
      if (p >= d.length) break;
      if (d[p] == 0x3E && p + 1 < d.length && d[p + 1] == 0x3E) {
        p += 2;
        break;
      }
      final k = parse();
      if (k is! PName) throw StateError('dict key not name');
      m[k.v] = parse();
    }
    return PDict(m);
  }

  P parseWithStream() {
    final o = parse();
    if (o is! PDict) return o;
    final save = p;
    skipWs();
    if (p + 6 > d.length || ascii.decode(d.sublist(p, p + 6)) != 'stream') {
      p = save;
      return o;
    }
    p += 6;
    if (p < d.length && d[p] == 13) p++;
    if (p < d.length && d[p] == 10) p++;
    final start = p;
    int? len;
    final l = o.v['Length'];
    if (l is PNum) len = l.v.toInt();
    if (len == null || start + len > d.length) {
      final idx = _indexOf(d, ascii.encode('endstream'), start);
      if (idx < 0) throw StateError('missing endstream');
      len = idx - start;
    }
    final raw = Uint8List.sublistView(d, start, start + len);
    p = start + len;
    skipWs();
    if (p + 9 <= d.length && ascii.decode(d.sublist(p, p + 9)) == 'endstream') {
      p += 9;
    }
    return PStream(o, raw);
  }
}

int _indexOf(Uint8List h, List<int> n, int from) {
  outer:
  for (var i = from; i <= h.length - n.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (h[i + j] != n[j]) continue outer;
    }
    return i;
  }
  return -1;
}

// ==================================================== STREAM FILTERS

Uint8List _decodeStream(PStream s) {
  final f = s.dict.v['Filter'];
  final filters = f is PName
      ? [f.v]
      : f is PArr
          ? f.v.whereType<PName>().map((e) => e.v).toList()
          : <String>[];
  var out = s.raw;
  for (final name in filters) {
    switch (name) {
      case 'FlateDecode':
      case 'Fl':
        out = inflateBytes(out);
        break;
      default:
        throw PdfWatermarkException('unsupported filter: $name');
    }
  }
  final parms = s.dict.v['DecodeParms'];
  if (parms is PDict) {
    final pred = (parms.v['Predictor'] as PNum?)?.v.toInt() ?? 1;
    if (pred >= 10) {
      out = _undoPng(
        out,
        (parms.v['Colors'] as PNum?)?.v.toInt() ?? 1,
        (parms.v['BitsPerComponent'] as PNum?)?.v.toInt() ?? 8,
        (parms.v['Columns'] as PNum?)?.v.toInt() ?? 1,
      );
    }
  }
  return out;
}

Uint8List _undoPng(Uint8List d, int colors, int bpc, int cols) {
  final bpp = ((colors * bpc) + 7) ~/ 8;
  final rowLen = ((colors * bpc * cols) + 7) ~/ 8;
  final rows = d.length ~/ (rowLen + 1);
  final out = Uint8List(rows * rowLen);
  var prev = Uint8List(rowLen);
  for (var r = 0; r < rows; r++) {
    final ft = d[r * (rowLen + 1)];
    final row = Uint8List.fromList(
      d.sublist(r * (rowLen + 1) + 1, r * (rowLen + 1) + 1 + rowLen),
    );
    for (var i = 0; i < rowLen; i++) {
      final a = i >= bpp ? row[i - bpp] : 0;
      final b = prev[i];
      final c = i >= bpp ? prev[i - bpp] : 0;
      switch (ft) {
        case 0:
          break;
        case 1:
          row[i] = (row[i] + a) & 0xFF;
          break;
        case 2:
          row[i] = (row[i] + b) & 0xFF;
          break;
        case 3:
          row[i] = (row[i] + ((a + b) >> 1)) & 0xFF;
          break;
        case 4:
          final p = a + b - c;
          final pa = (p - a).abs();
          final pb = (p - b).abs();
          final pc = (p - c).abs();
          final pr = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          row[i] = (row[i] + pr) & 0xFF;
      }
    }
    out.setRange(r * rowLen, (r + 1) * rowLen, row);
    prev = row;
  }
  return out;
}

// ========================================================== DOCUMENT

class _XrefSection {
  final Map<int, int> offsets = {};
  final Map<int, int> inStream = {};
  PDict? trailer;
}

class PdfDoc {
  final Uint8List data;
  final Map<int, int> _offset = {};
  final Map<int, int> _inStream = {};
  final Map<int, P> _cache = {};
  final Set<int> _stmLoaded = {};
  PDict? trailer;
  int startXrefOffset = -1;

  PdfDoc(this.data);

  void load() {
    startXrefOffset = _findStartXref();
    var off = startXrefOffset;
    final seen = <int>{};
    while (off >= 0 && seen.add(off)) {
      final sec = _parseXrefAt(off);
      sec.offsets.forEach((k, v) => _offset.putIfAbsent(k, () => v));
      sec.inStream.forEach((k, v) => _inStream.putIfAbsent(k, () => v));
      trailer ??= sec.trailer;
      final prev = sec.trailer?.v['Prev'];
      off = prev is PNum ? prev.v.toInt() : -1;
    }
    if (trailer == null) {
      throw PdfWatermarkException('no PDF trailer found');
    }
  }

  int _findStartXref() {
    final needle = ascii.encode('startxref');
    final lo = data.length - 2048 < 0 ? 0 : data.length - 2048;
    for (var i = data.length - needle.length; i >= lo; i--) {
      if (_indexOf(data, needle, i) == i) {
        var p = i + needle.length;
        while (p < data.length && _ws(data[p])) {
          p++;
        }
        final s = p;
        while (p < data.length && data[p] >= 0x30 && data[p] <= 0x39) {
          p++;
        }
        return int.parse(ascii.decode(data.sublist(s, p)));
      }
    }
    throw PdfWatermarkException('not a PDF (no startxref)');
  }

  _XrefSection _parseXrefAt(int off) {
    final sec = _XrefSection();
    final p = PdfParser(data, off);
    p.skipWs();
    if (p.p + 4 <= data.length &&
        ascii.decode(data.sublist(p.p, p.p + 4)) == 'xref') {
      p.p += 4;
      while (true) {
        p.skipWs();
        if (p.p + 7 <= data.length &&
            ascii.decode(data.sublist(p.p, p.p + 7)) == 'trailer') {
          p.p += 7;
          p.skipWs();
          sec.trailer = p.parse() as PDict;
          break;
        }
        final a = p.parse(), b = p.parse();
        if (a is! PNum || b is! PNum) break;
        final start = a.v.toInt(), count = b.v.toInt();
        for (var i = 0; i < count; i++) {
          p.skipWs();
          final s1 = p.p;
          while (p.p < data.length && !_ws(data[p.p])) {
            p.p++;
          }
          final o = int.tryParse(ascii.decode(data.sublist(s1, p.p))) ?? 0;
          p.skipWs();
          while (p.p < data.length && !_ws(data[p.p])) {
            p.p++;
          }
          p.skipWs();
          if (p.p >= data.length) break;
          if (data[p.p++] == 0x6E /* n */) sec.offsets[start + i] = o;
        }
      }
      return sec;
    }

    // xref stream
    final obj = p.parseWithStream();
    if (obj is! PStream) return sec;
    sec.trailer = obj.dict;
    final bytes = obj.decoded();
    final w =
        (obj.dict.v['W'] as PArr).v.map((e) => (e as PNum).v.toInt()).toList();
    final size = (obj.dict.v['Size'] as PNum).v.toInt();
    final index = obj.dict.v['Index'] is PArr
        ? (obj.dict.v['Index'] as PArr)
            .v
            .map((e) => (e as PNum).v.toInt())
            .toList()
        : [0, size];
    final rowLen = w.fold(0, (a, b) => a + b);
    var bp = 0;
    for (var seg = 0; seg + 1 < index.length; seg += 2) {
      final start = index[seg], count = index[seg + 1];
      for (var i = 0; i < count; i++) {
        if (bp + rowLen > bytes.length) return sec;
        final f = <int>[];
        for (final width in w) {
          var v = 0;
          for (var k = 0; k < width; k++) {
            v = (v << 8) | bytes[bp++];
          }
          f.add(v);
        }
        final type = w[0] == 0 ? 1 : f[0];
        final n = start + i;
        if (type == 1) {
          sec.offsets[n] = f[1];
        } else if (type == 2) {
          sec.inStream[n] = f[1];
        }
      }
    }
    return sec;
  }

  P? obj(int num) {
    if (_cache.containsKey(num)) return _cache[num];
    final off = _offset[num];
    if (off != null) {
      final p = PdfParser(data, off);
      p.parse();
      p.parse();
      p.skipWs();
      p._token(); // consume 'obj'
      return _cache[num] = p.parseWithStream();
    }
    final c = _inStream[num];
    if (c != null) {
      _loadObjStm(c);
      return _cache[num];
    }
    return null;
  }

  void _loadObjStm(int num) {
    if (!_stmLoaded.add(num)) return;
    final off = _offset[num];
    if (off == null) return;
    final p = PdfParser(data, off);
    p.parse();
    p.parse();
    p.skipWs();
    p._token();
    final o = p.parseWithStream();
    if (o is! PStream) return;
    final n = (o.dict.v['N'] as PNum).v.toInt();
    final first = (o.dict.v['First'] as PNum).v.toInt();
    final bytes = o.decoded();
    final h = PdfParser(bytes);
    final pairs = <int>[];
    for (var i = 0; i < n; i++) {
      pairs.add((h.parse() as PNum).v.toInt());
      pairs.add((h.parse() as PNum).v.toInt());
    }
    for (var i = 0; i < n; i++) {
      final sp = PdfParser(bytes, first + pairs[i * 2 + 1]);
      _cache[pairs[i * 2]] = sp.parse();
    }
  }

  int maxObjNum() {
    var m = _offset.keys.fold(0, (a, b) => a > b ? a : b);
    for (final k in _inStream.keys) {
      if (k > m) m = k;
    }
    final s = trailer?.v['Size'];
    if (s is PNum && s.v.toInt() - 1 > m) m = s.v.toInt() - 1;
    return m;
  }
}

// =================================================== PAGE NAVIGATION

List<int> collectPages(PdfDoc doc, int nodeNum, [Set<int>? seen]) {
  seen ??= {};
  if (!seen.add(nodeNum)) return [];
  final node = doc.obj(nodeNum);
  if (node is! PDict) return [];
  final t = node.v['Type'];
  if (t is PName && t.v == 'Page') return [nodeNum];
  final out = <int>[];
  final kids = node.v['Kids'];
  if (kids is PArr) {
    for (final k in kids.v) {
      if (k is PRef) out.addAll(collectPages(doc, k.num, seen));
    }
  }
  return out;
}

P? inherited(PdfDoc doc, int nodeNum, String key) {
  var cur = doc.obj(nodeNum);
  final seen = <int>{};
  while (cur is PDict) {
    if (cur.v.containsKey(key)) {
      var v = cur.v[key]!;
      while (v is PRef) {
        if (!seen.add(v.num)) return null;
        v = doc.obj(v.num) ?? const PNull();
      }
      return v;
    }
    final parent = cur.v['Parent'];
    if (parent is! PRef) break;
    cur = doc.obj(parent.num);
  }
  return null;
}
