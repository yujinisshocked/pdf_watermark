/// Platform shim for zlib compression and decompression.
export 'zlib_stub.dart' if (dart.library.io) 'zlib_io.dart';
