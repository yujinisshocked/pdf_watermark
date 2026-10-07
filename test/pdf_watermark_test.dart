import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_watermark/pdf_watermark.dart';

/// Builds a minimal valid 1-page PDF with correct byte offsets.
Uint8List minimalPdf() {
  final b = BytesBuilder();
  final off = <int>[];
  void w(String s) => b.add(ascii.encode(s));

  w('%PDF-1.4\n');
  off.add(b.length);
  w('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  off.add(b.length);
  w('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
  off.add(b.length);
  w('3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << >> >>\nendobj\n');
  final xref = b.length;
  w('xref\n0 4\n0000000000 65535 f \n');
  for (final o in off) {
    w('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  w('trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return b.takeBytes();
}

void main() {
  test('watermarks a minimal PDF', () {
    final out = watermarkPdf(minimalPdf(), text: 'CONFIDENTIAL');
    expect(out.length, greaterThan(0));
    expect(ascii.decode(out.sublist(0, 8)), '%PDF-1.4');
    expect(ascii.decode(out), contains('CONFIDENTIAL'));
    expect(ascii.decode(out).trimRight(), endsWith('%%EOF'));
  });

  test('rejects empty input', () {
    expect(
      () => watermarkPdf(Uint8List(0), text: 'x'),
      throwsA(isA<PdfWatermarkException>()),
    );
  });

  test('rejects garbage', () {
    expect(
      () => watermarkPdf(
        Uint8List.fromList(utf8.encode('not a pdf at all')),
        text: 'x',
      ),
      throwsA(isA<PdfWatermarkException>()),
    );
  });
}

