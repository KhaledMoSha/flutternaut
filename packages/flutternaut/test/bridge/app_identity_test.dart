import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/app_identity.dart';

void main() {
  const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Runner</string>
  <key>CFBundleIdentifier</key><string>com.example.radar</string>
</dict></plist>''';

  test('reads a string from an XML plist', () {
    expect(
      plistString(Uint8List.fromList(xml.codeUnits), 'CFBundleIdentifier'),
      'com.example.radar',
    );
  });

  test('reads a string from a binary plist (plutil -convert binary1)', () {
    final dir = Directory.systemTemp.createTempSync('plist');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/Info.plist')..writeAsStringSync(xml);
    final result = Process.runSync(
      'plutil',
      ['-convert', 'binary1', file.path],
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final bytes = file.readAsBytesSync();
    expect(String.fromCharCodes(bytes.sublist(0, 6)), 'bplist');

    expect(plistString(bytes, 'CFBundleIdentifier'), 'com.example.radar');
    expect(plistString(bytes, 'CFBundleName'), 'Runner');
    expect(plistString(bytes, 'Missing'), isNull);
  }, skip: !Platform.isMacOS ? 'plutil is macOS-only' : false);

  test('garbage is not a plist', () {
    expect(
      plistString(Uint8List.fromList(List.filled(64, 7)), 'CFBundleIdentifier'),
      isNull,
    );
    final truncated = Uint8List.fromList('bplist00'.codeUnits + [0, 1, 2]);
    expect(plistString(truncated, 'CFBundleIdentifier'), isNull);
  });
}
