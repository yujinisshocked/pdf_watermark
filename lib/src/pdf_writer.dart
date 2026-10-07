import 'dart:convert';
import 'dart:typed_data';

import 'pdf_parser.dart';

String _numStr(num v) {
  if (v is int) return v.toString();
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  var s = v.toString();
  if (s.contains('e') || s.contains('E')) {
    s = v.toStringAsFixed(6);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
  }
  return s;
}

String _escName(String s) {
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    final bad = c < 0x21 ||
        c > 0x7E ||
        c == 0x23 ||
        c == 0x2F ||
        c == 0x28 ||
        c == 0x29 ||
        c == 0x3C ||
        c == 0x3E ||
        c == 0x5B ||
        c == 0x5D ||
        c == 0x7B ||
        c == 0x7D ||
        c == 0x25;
    if (bad) {
      b.write('#${c.toRadixString(16).padLeft(2, '0').toUpperCase()}');
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}

void writeObj(BytesBuilder out, P o) {
  if (o is PNull) {
    out.add(ascii.encode('null'));
  } else if (o is PBool) {
    out.add(ascii.encode(o.v ? 'true' : 'false'));
  } else if (o is PNum) {
    out.add(ascii.encode(_numStr(o.v)));
  } else if (o is PRef) {
    out.add(ascii.encode('${o.num} ${o.gen} R'));
  } else if (o is PName) {
    out.add(ascii.encode('/${_escName(o.v)}'));
  } else if (o is PStr) {
    out.addByte(0x28);
    for (final b in o.v) {
      if (b == 0x28 || b == 0x29 || b == 0x5C) out.addByte(0x5C);
      out.addByte(b);
    }
    out.addByte(0x29);
  } else if (o is PArr) {
    out.addByte(0x5B);
    for (final i in o.v) {
      writeObj(out, i);
      out.addByte(0x20);
    }
    out.addByte(0x5D);
  } else if (o is PDict) {
    out.add(ascii.encode('<< '));
    o.v.forEach((k, v) {
      out.add(ascii.encode('/${_escName(k)} '));
      writeObj(out, v);
      out.addByte(0x20);
    });
    out.add(ascii.encode('>>'));
  } else if (o is PStream) {
    final d = Map<String, P>.from(o.dict.v);
    d['Length'] = PNum(o.raw.length);
    writeObj(out, PDict(d));
    out.add(ascii.encode('\nstream\n'));
    out.add(o.raw);
    out.add(ascii.encode('\nendstream'));
  }
}
