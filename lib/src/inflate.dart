/// Platform shim for zlib decompression.
///
/// On native platforms this re-exports a `dart:io`-backed implementation.
/// On web (where `dart:io` is unavailable) it re-exports a stub that throws.
export 'inflate_stub.dart' if (dart.library.io) 'inflate_io.dart';