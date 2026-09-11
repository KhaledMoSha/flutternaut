import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/models/element_info.dart';
import 'package:flutternaut/src/bridge/models/element_rect.dart';
import 'package:flutternaut/src/bridge/models/visibility_result.dart';

void main() {
  group('VisibilityResult', () {
    test('toJson with no info includes the visibility flags', () {
      const result = VisibilityResult(exists: false, visible: false);
      expect(result.toJson(), {
        'exists': false,
        'visible': false,
        'on_screen': false,
        'obstructed': false,
      });
    });

    test('toJson reflects on_screen and obstructed', () {
      const result = VisibilityResult(
        exists: true,
        visible: false,
        onScreen: true,
        obstructed: true,
      );
      final json = result.toJson();
      expect(json['on_screen'], isTrue);
      expect(json['obstructed'], isTrue);
      expect(json['visible'], isFalse);
    });

    test('toJson includes rect when info has a rect', () {
      const info = ElementInfo(
        type: 'Text',
        rect: ElementRect(x: 1, y: 2, width: 3, height: 4),
      );
      const result = VisibilityResult(exists: true, visible: true, info: info);
      final json = result.toJson();
      expect(json['rect'], isA<Map<String, dynamic>>());
    });

    test('toJson includes text when info has text', () {
      const info = ElementInfo(type: 'Text', text: 'hello');
      const result = VisibilityResult(exists: true, visible: true, info: info);
      expect(result.toJson()['text'], 'hello');
    });

    test('toJson includes type when info has non-empty type', () {
      const info = ElementInfo(type: 'Button');
      const result = VisibilityResult(exists: true, visible: true, info: info);
      expect(result.toJson()['type'], 'Button');
    });

    test('toJson omits type when info has empty type', () {
      const info = ElementInfo();
      const result = VisibilityResult(exists: true, visible: false, info: info);
      final json = result.toJson();
      expect(json.containsKey('type'), isFalse);
    });

    test('toString reflects exists and visible', () {
      const result = VisibilityResult(exists: true, visible: false);
      expect(result.toString(), contains('exists: true'));
      expect(result.toString(), contains('visible: false'));
    });
  });
}
