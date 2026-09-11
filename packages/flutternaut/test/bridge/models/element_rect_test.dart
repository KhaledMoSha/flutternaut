import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/models/element_rect.dart';

void main() {
  group('ElementRect', () {
    test('toJson emits x/y/w/h keys', () {
      const rect = ElementRect(x: 10, y: 20, width: 100, height: 50);
      expect(rect.toJson(), {'x': 10.0, 'y': 20.0, 'w': 100.0, 'h': 50.0});
    });

    test('fromJson round-trip', () {
      const original = ElementRect(x: 1, y: 2, width: 3, height: 4);
      final json = original.toJson();
      final restored = ElementRect.fromJson(json);
      expect(restored, original);
    });

    test('center calculates midpoint', () {
      const rect = ElementRect(x: 0, y: 0, width: 100, height: 200);
      expect(rect.center, const Offset(50, 100));
    });

    test('center with offset rect', () {
      const rect = ElementRect(x: 10, y: 20, width: 100, height: 200);
      expect(rect.center, const Offset(60, 120));
    });

    test('equality based on all fields', () {
      const a = ElementRect(x: 1, y: 2, width: 3, height: 4);
      const b = ElementRect(x: 1, y: 2, width: 3, height: 4);
      const c = ElementRect(x: 1, y: 2, width: 3, height: 5);
      expect(a, b);
      expect(a, isNot(c));
    });

    test('hashCode consistent with equality', () {
      const a = ElementRect(x: 1, y: 2, width: 3, height: 4);
      const b = ElementRect(x: 1, y: 2, width: 3, height: 4);
      expect(a.hashCode, b.hashCode);
    });

    test('toString includes dimensions', () {
      const rect = ElementRect(x: 1, y: 2, width: 3, height: 4);
      expect(rect.toString(), contains('1'));
      expect(rect.toString(), contains('4'));
    });
  });
}
