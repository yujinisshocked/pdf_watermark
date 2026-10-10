import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

Uint8List inflateBytes(Uint8List input) =>
    Uint8List.fromList(ZLibCodec().decode(input));

Uint8List deflateBytes(Uint8List input) =>
    Uint8List.fromList(ZLibCodec().encode(input));