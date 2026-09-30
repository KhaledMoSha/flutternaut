import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Which app this bridge runs in, as reported on `/health` so a test engine
/// can tell its own app from a stale one still holding the bridge port:
///
///  * Android — the package name (the app process's name);
///  * iOS / macOS — `CFBundleIdentifier` from the running bundle's
///    `Info.plist` (binary or XML).
///
/// Null when the platform exposes neither — never a guess: every Flutter
/// iOS bundle is named `Runner.app`, so the folder name identifies nothing.
String? readAppIdentity() {
  if (Platform.isAndroid) {
    final cmdline = File('/proc/self/cmdline').readAsStringSync();
    final name = cmdline.split('\u0000').first.trim();
    // A secondary process is "<package>:<process>".
    return name.isEmpty ? null : name.split(':').first;
  }
  if (Platform.isIOS || Platform.isMacOS) {
    final plist = _infoPlistOf(Platform.resolvedExecutable);
    if (plist == null || !plist.existsSync()) return null;
    return plistString(plist.readAsBytesSync(), 'CFBundleIdentifier');
  }
  return null;
}

/// The `Info.plist` of the bundle containing [executable]:
/// `X.app/Info.plist` on iOS, `X.app/Contents/Info.plist` on macOS.
File? _infoPlistOf(String executable) {
  final parts = executable.split('/');
  final appIndex = parts.lastIndexWhere((p) => p.endsWith('.app'));
  if (appIndex < 0) return null;
  final bundle = parts.sublist(0, appIndex + 1).join('/');
  final ios = File('$bundle/Info.plist');
  if (ios.existsSync()) return ios;
  return File('$bundle/Contents/Info.plist');
}

/// The string value of top-level [key] in a property list — binary
/// (`bplist00`) or XML — or null when the key is absent, not a string, or
/// the data is not a property list this reader understands.
String? plistString(Uint8List bytes, String key) {
  if (bytes.length >= 8 && ascii.decode(bytes.sublist(0, 6)) == 'bplist') {
    return _BinaryPlist(bytes).topLevelString(key);
  }
  final xml = utf8.decode(bytes, allowMalformed: true);
  final match = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
  ).firstMatch(xml);
  return match?.group(1);
}

/// A minimal reader for Apple's binary property list format, enough to read
/// one string from the top-level dictionary. Malformed input yields null.
class _BinaryPlist {
  _BinaryPlist(this._b);

  final Uint8List _b;

  String? topLevelString(String key) {
    if (_b.length < 40) return null;
    final trailer = _b.length - 32;
    final offsetSize = _b[trailer + 6];
    final refSize = _b[trailer + 7];
    final numObjects = _uint(trailer + 8, 8);
    final topObject = _uint(trailer + 16, 8);
    final tableOffset = _uint(trailer + 24, 8);
    if (offsetSize < 1 || offsetSize > 8 || refSize < 1 || refSize > 8) {
      return null;
    }
    if (numObjects <= 0 || topObject >= numObjects) return null;
    if (tableOffset + numObjects * offsetSize > trailer) return null;

    int offsetOf(int ref) {
      if (ref < 0 || ref >= numObjects) return -1;
      final off = _uint(tableOffset + ref * offsetSize, offsetSize);
      return off < 8 || off >= trailer ? -1 : off;
    }

    final top = offsetOf(topObject);
    if (top < 0 || _b[top] >> 4 != 0xD) return null; // not a dict
    final (count, start) = _lengthAt(top);
    if (count < 0 || start + 2 * count * refSize > trailer) return null;
    for (var i = 0; i < count; i++) {
      final k = _stringAt(offsetOf(_uint(start + i * refSize, refSize)));
      if (k != key) continue;
      final vRef = _uint(start + (count + i) * refSize, refSize);
      return _stringAt(offsetOf(vRef));
    }
    return null;
  }

  /// Big-endian unsigned integer of [size] bytes at [at].
  int _uint(int at, int size) {
    var v = 0;
    for (var i = 0; i < size; i++) {
      v = (v << 8) | _b[at + i];
    }
    return v;
  }

  /// The object length encoded in the marker at [at] and the offset where
  /// its payload starts; (-1, -1) when malformed.
  (int, int) _lengthAt(int at) {
    final low = _b[at] & 0x0F;
    if (low != 0x0F) return (low, at + 1);
    final intMarker = _b[at + 1];
    if (intMarker >> 4 != 0x1) return (-1, -1);
    final size = 1 << (intMarker & 0x0F);
    if (size > 8) return (-1, -1);
    return (_uint(at + 2, size), at + 2 + size);
  }

  String? _stringAt(int at) {
    if (at < 0) return null;
    final type = _b[at] >> 4;
    final (len, start) = _lengthAt(at);
    if (len < 0) return null;
    if (type == 0x5) {
      if (start + len > _b.length) return null;
      return ascii.decode(_b.sublist(start, start + len), allowInvalid: true);
    }
    if (type == 0x6) {
      if (start + 2 * len > _b.length) return null;
      final units = <int>[
        for (var i = 0; i < len; i++) _uint(start + 2 * i, 2),
      ];
      return String.fromCharCodes(units);
    }
    return null;
  }
}
