import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/tree_walker.dart';

/// Pins the smallest visible side (`TreeWalkerGeometry.minVisibleSide` in
/// lib/src/bridge/engine/tree_walker/geometry.dart, 1.0 logical px). The
/// engine catalog hides a node under the same size (`MinVisibleSide` in
/// engine/catalog/visible_size.go, pinned there by min_visible_side_test.go,
/// which reads the Dart declaration): if the two values drift apart, the
/// catalog and the bridge disagree on which widgets, lists and `nth`s exist.
const _syncNote = 'the bridge visible side (TreeWalkerGeometry.minVisibleSide) '
    'must equal engine/catalog/visible_size.go MinVisibleSide (1.0); change both, '
    'and both pin tests, together';

/// A [width] x 40 box at (10, 10), keyed `box`.
Widget _box(double width) => MaterialApp(
      home: Stack(
        children: [
          Positioned(
            left: 10,
            top: 10,
            width: width,
            height: 40,
            child: const ColoredBox(
              key: ValueKey('box'),
              color: Color(0xFF000000),
            ),
          ),
        ],
      ),
    );

void main() {
  final walker = TreeWalker();

  test('minVisibleSide is 1.0 logical px', () {
    expect(TreeWalkerGeometry.minVisibleSide, 1.0, reason: _syncNote);
  });

  testWidgets('a side of exactly minVisibleSide is visible', (tester) async {
    await tester.pumpWidget(_box(TreeWalkerGeometry.minVisibleSide));
    expect(walker.checkVisibleByKey('box').visible, isTrue, reason: _syncNote);
  });

  testWidgets('a side just under minVisibleSide is not', (tester) async {
    await tester.pumpWidget(_box(TreeWalkerGeometry.minVisibleSide - 0.01));
    final result = walker.checkVisibleByKey('box');
    expect(result.visible, isFalse, reason: _syncNote);
    expect(result.reason,
        'key "box" exists but is off-screen or clipped to under 1 px');
  });
}
