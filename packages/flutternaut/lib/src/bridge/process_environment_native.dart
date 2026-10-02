import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// The process environment on platforms with `dart:ffi` (iOS, Android,
/// macOS, Linux, Windows). Reached only through `process_environment.dart`.
///
/// `Platform.environment` is **empty** in a Flutter iOS app (simulator and
/// device), so on iOS the variable is read with C `getenv` through
/// `dart:ffi`. Everywhere else `Platform.environment` is the process
/// environment and is used as is.
String? readProcessEnvironment(String name) {
  if (Platform.isIOS) return _getenv(name);
  return Platform.environment[name];
}

typedef _GetenvNative = Pointer<Uint8> Function(Pointer<Uint8>);
typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

/// `getenv(3)` from the C library already loaded in this process — no
/// `package:ffi` dependency.
///
/// Memory: the NUL-terminated copy of [name] is ours (malloc) and is freed
/// before returning. The pointer `getenv` returns belongs to the C runtime's
/// environment block and must never be freed; its bytes are copied into a
/// Dart string before this function returns, so nothing keeps pointing at it.
String? _getenv(String name) {
  final process = DynamicLibrary.process();
  final getenv = process.lookupFunction<_GetenvNative, _GetenvNative>('getenv');
  final malloc = process.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = process.lookupFunction<_FreeNative, _FreeDart>('free');

  final nameBytes = utf8.encode(name);
  final cName = malloc(nameBytes.length + 1);
  if (cName == nullptr) {
    throw StateError(
      'FlutternautBridge: out of memory reading the environment variable '
      '$name (malloc of ${nameBytes.length + 1} bytes failed)',
    );
  }
  try {
    cName.asTypedList(nameBytes.length + 1)
      ..setAll(0, nameBytes)
      ..[nameBytes.length] = 0;
    final value = getenv(cName);
    if (value == nullptr) return null;
    var length = 0;
    while ((value + length).value != 0) {
      length++;
    }
    // utf8.decode copies the bytes out of the C environment block.
    return utf8.decode(value.asTypedList(length), allowMalformed: true);
  } finally {
    free(cName);
  }
}
