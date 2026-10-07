import 'dart:typed_data';

/// Web fallback. Only uncompressed PDFs will work.
Uint8List inflateBytes(Uint8List input) => throw UnsupportedError(
      'FlateDecode requires a zlib decoder. Native platforms use dart:io; '
      'on web, only uncompressed PDFs are supported.',
    );