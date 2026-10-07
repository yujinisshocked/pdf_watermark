# Flutter PDF Watermarker

This is a pdf watermarker. Made by Yujinisshocked.

all the watermark package in pub.dev seems sucks, so i made my own. even sucker.

see the example on how to use it.

its shit on encrypted pdf, so pls watermark first b4 encrypt.

maybe i will add support for encryption too in the future.

example:

```dart
import 'package:pdf_watermark/pdf_watermark.dart';

final out = watermarkPdf(inputBytes, text: 'CONFIDENTIAL');
```

how to use:

clone first
```bash
git clone https://github.com/yujinisshocked/pdf_watermark.git
```

then put into pubspec

```yaml
pdf_watermark:
    path: ../pdf_watermark
```

*idk if i did it correctly basically just let the whole shit exposed to the package*

and then import

```dart
import 'package:pdf_watermark/pdf_watermark.dart';
```

and call it :D

voila, u did it. congrats