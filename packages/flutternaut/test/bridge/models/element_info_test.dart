import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/models/element_info.dart';
import 'package:flutternaut/src/bridge/models/element_rect.dart';

void main() {
  group('ElementInfo', () {
    test('notFound constant returns found: false', () {
      expect(ElementInfo.notFound.found, isFalse);
      expect(ElementInfo.notFound.toJson(), {'found': false});
    });

    test('toJson includes only found when not found', () {
      const info = ElementInfo(found: false);
      expect(info.toJson(), {'found': false});
    });

    test('toJson includes type when found', () {
      const info = ElementInfo(type: 'Text');
      final json = info.toJson();
      expect(json['found'], isTrue);
      expect(json['type'], 'Text');
    });

    test('toJson omits null key and text', () {
      const info = ElementInfo(type: 'Text');
      final json = info.toJson();
      expect(json.containsKey('key'), isFalse);
      expect(json.containsKey('text'), isFalse);
    });

    test('toJson includes key when set', () {
      const info = ElementInfo(type: 'Text', key: 'my_key');
      expect(info.toJson()['key'], 'my_key');
    });

    test('toJson includes text when set', () {
      const info = ElementInfo(type: 'Text', text: 'Hello');
      expect(info.toJson()['text'], 'Hello');
    });

    test('toJson includes rect when set', () {
      const info = ElementInfo(
        type: 'Text',
        rect: ElementRect(x: 1, y: 2, width: 3, height: 4),
      );
      expect(info.toJson()['rect'], isA<Map<String, dynamic>>());
    });

    test('toJson includes enabled when set', () {
      const info = ElementInfo(type: 'Button', enabled: true);
      expect(info.toJson()['enabled'], isTrue);
    });

    test('toJson includes checked when set', () {
      const info = ElementInfo(type: 'Checkbox', checked: false);
      expect(info.toJson()['checked'], isFalse);
    });

    test('equality based on all fields', () {
      const a = ElementInfo(type: 'Text', key: 'x', text: 'hi');
      const b = ElementInfo(type: 'Text', key: 'x', text: 'hi');
      const c = ElementInfo(type: 'Text', key: 'x', text: 'bye');
      expect(a, b);
      expect(a, isNot(c));
    });

    test('hashCode consistent with equality', () {
      const a = ElementInfo(type: 'Text', key: 'x');
      const b = ElementInfo(type: 'Text', key: 'x');
      expect(a.hashCode, b.hashCode);
    });

    test('toString includes type and key', () {
      const info = ElementInfo(type: 'Button', key: 'submit');
      expect(info.toString(), contains('Button'));
      expect(info.toString(), contains('submit'));
    });
  });
}
