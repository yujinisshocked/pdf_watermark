import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

/// Decompress a zlib stream (PDF `/FlateDecode`).
Uint8List inflateBytes(Uint8List input) =>
    Uint8List.fromList(ZLibCodec().decode(input));