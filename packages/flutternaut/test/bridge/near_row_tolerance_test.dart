import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/tree_walker.dart';

/// Pins the row band of reading order (`_kNearRowTolerance` in
/// lib/src/bridge/engine/tree_walker/near.dart, 12.0 logical px) through the
/// public [TreeWalkerNear.inReadingOrder]. The engine catalog numbers `near`
/// and duplicate-text `nth` values with the same band (`nearRowTolerance` in
/// engine/catalog/catalog.go, pinned there by near_row_tolerance_test.go
/// with the same fixture): if the two values drift apart, a recorded `nth`
/// resolves to another widget.
const _syncNote = 'the bridge row band (_kNearRowTolerance) must equal '
    'engine/catalog/catalog.go nearRowTolerance (12.0); change both, and '
    'both pin tests, together';

/// Two 10x10 boxes: `right` at x=100 on top, `left` at x=0 whose
/// y-centre sits [gap] below the right box's. In one row reading order is
/// left to right ([left, right]); in two rows it is top to bottom
/// ([right, left]).
Widget _twoBoxes(double gap) => MaterialApp(
      home: Stack(
        children: [
          const Positioned(
            left: 100,
            top: 0,
            child: SizedBox(key: ValueKey('right'), width: 10, height: 10),
          ),
          Positioned(
            left: 0,
            top: gap,
            child: const SizedBox(
              key: ValueKey('left'),
              width: 10,
              height: 10,
            ),
          ),
        ],
      ),
    );

void main() {
  final walker = TreeWalker();

  List<String?> order() {
    final right = walker.findElementByKey('right');
    final left = walker.findElementByKey('left');
    expect(right, isNotNull);
    expect(left, isNotNull);
    return walker
        .inReadingOrder([right!, left!])
        .map((e) => TreeWalker.keyOf(e.widget))
        .toList();
  }

  testWidgets('y-centres 12.0 apart are one row', (tester) async {
    await tester.pumpWidget(_twoBoxes(12.0));
    expect(order(), ['left', 'right'], reason: _syncNote);
  });

  testWidgets('y-centres 12.5 apart are two rows', (tester) async {
    await tester.pumpWidget(_twoBoxes(12.5));
    expect(order(), ['right', 'left'], reason: _syncNote);
  });
}
