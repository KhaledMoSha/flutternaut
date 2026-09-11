import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/models/action_result.dart';

void main() {
  group('ActionResult', () {
    test('toJson includes success and action', () {
      const result = ActionResult(action: 'tap', success: true);
      expect(result.toJson(), {'success': true, 'action': 'tap'});
    });

    test('toJson spreads extras into top-level', () {
      const result = ActionResult(
        action: 'swipe',
        success: true,
        extras: {'direction': 'up'},
      );
      expect(result.toJson(), {
        'success': true,
        'action': 'swipe',
        'direction': 'up',
      });
    });

    test('toJson handles multiple extras', () {
      const result = ActionResult(
        action: 'multi_tap',
        success: true,
        extras: {'count': 3, 'key': 'btn'},
      );
      final json = result.toJson();
      expect(json['count'], 3);
      expect(json['key'], 'btn');
      expect(json['action'], 'multi_tap');
    });

    test('toString reflects action and success', () {
      const result = ActionResult(action: 'tap', success: false);
      expect(result.toString(), contains('tap'));
      expect(result.toString(), contains('false'));
    });
  });
}
