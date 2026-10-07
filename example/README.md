# pdf_watermark

Lightweight, pure-Dart PDF watermarking. Zero runtime dependencies.

## Usage

```dart
import 'package:pdf_watermark/pdf_watermark.dart';

final out = watermarkPdf(inputBytes, text: 'CONFIDENTIAL');
// out is a Uint8List containing the watermarked PDF