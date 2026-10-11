// The native core on platforms with dart:ffi, a stub elsewhere (the web).
export 'native_stub.dart' if (dart.library.ffi) 'native.dart';
