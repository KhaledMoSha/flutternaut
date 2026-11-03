import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/models/action_failure.dart';

/// Runs a dispatcher call to completion under fake time (see the same
/// helper in gesture_dispatcher_test.dart).
Future<T> _pumpAndAwait<T>(
  WidgetTester tester,
  Future<T> Function() work,
) async {
  final completer = Completer<T>();
  work().then(completer.complete, onError: completer.completeError);
  completer.future.ignore();
  for (var i = 0; i < 200 && !completer.isCompleted; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return completer.future;
}

/// Named like the framework's private slot enum, so its `toString()` is
/// `_ScaffoldSlot.statusBar` — what the bridge recognises the status-bar
/// tap area of a `Scaffold` by.
enum _ScaffoldSlot { body, statusBar }

/// Height of the iOS top safe area the status-bar tap area covers.
const double _statusBarHeight = 62;

/// Lays out the body full-size and the status-bar slot over its top
/// [_statusBarHeight] px, after the body — so it is hit-tested first, as in
/// `Scaffold`.
class _ScaffoldLikeLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    layoutChild(_ScaffoldSlot.body, BoxConstraints.tight(size));
    positionChild(_ScaffoldSlot.body, Offset.zero);
    layoutChild(
      _ScaffoldSlot.statusBar,
      BoxConstraints.tight(Size(size.width, _statusBarHeight)),
    );
    positionChild(_ScaffoldSlot.statusBar, Offset.zero);
  }

  @override
  bool shouldRelayout(_ScaffoldLikeLayout oldDelegate) => false;
}

/// The page shape of an iOS `Scaffold` before Flutter 3.41 (Beanz pins
/// 3.32.8): an opaque, child-less `GestureDetector` with its own `onTap`
/// over the top safe area, in front of the body.
Widget _scaffoldBefore341({
  required Widget body,
  required VoidCallback onStatusBarTap,
}) {
  return MaterialApp(
    home: Material(
      child: CustomMultiChildLayout(
        delegate: _ScaffoldLikeLayout(),
        children: [
          LayoutId(id: _ScaffoldSlot.body, child: body),
          LayoutId(
            id: _ScaffoldSlot.statusBar,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onStatusBarTap,
              excludeFromSemantics: true,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Rows of 60 px, each a `GestureDetector` (its control) around a short
/// text label at its top — like a settings row ("Country"), whose label is
/// far smaller than the row.
List<Widget> _rows(List<int> taps) => [
      for (var i = 0; i < 30; i++)
        GestureDetector(
          onTap: () => taps[i]++,
          child: SizedBox(
            height: 60,
            width: double.infinity,
            child: Align(
              alignment: Alignment.topLeft,
              child: Text('row $i'),
            ),
          ),
        ),
    ];

void main() {
  final walker = TreeWalker();
  late GestureDispatcher dispatcher;
  setUp(() => dispatcher = GestureDispatcher(walker));

  Future<String> failureOf(
    WidgetTester tester,
    Future<Object?> Function() work,
  ) async {
    try {
      await _pumpAndAwait(tester, work);
    } on ActionFailure catch (e) {
      return e.message;
    }
    fail('expected an ActionFailure, but the call succeeded');
  }

  group('a row under the iOS status-bar tap area (Scaffold before 3.41)', () {
    testWidgets(
        'a scrollable row under it is centred, then tapped — the status bar '
        'never gets the tap', (tester) async {
      final taps = List.filled(30, 0);
      var statusBarTaps = 0;
      final list = ScrollController();
      addTearDown(list.dispose);
      await tester.pumpWidget(_scaffoldBefore341(
        body: ListView(controller: list, children: _rows(taps)),
        onStatusBarTap: () => statusBarTaps++,
      ));
      // Row 3 (top at 180) scrolled to y 25: its label sits wholly inside
      // the 62 px band, where the replay left "Country".
      list.jumpTo(155);
      await tester.pump();

      final reached =
          await _pumpAndAwait(tester, () => dispatcher.tap(text: 'row 3'));

      expect(statusBarTaps, 0, reason: 'the status bar must not take it');
      expect(taps[3], 1, reason: 'the row the step names is the one tapped');
      expect(reached, contains('GestureDetector "row 3"'));
      final rowTop = tester.getTopLeft(find.text('row 3')).dy;
      expect(rowTop, greaterThan(_statusBarHeight),
          reason: 'revealed clear of the band, not put back under it');
    });

    testWidgets(
        'a row that cannot be scrolled out from under it is refused, naming '
        'the status-bar tap area', (tester) async {
      final taps = List.filled(30, 0);
      var statusBarTaps = 0;
      await tester.pumpWidget(_scaffoldBefore341(
        body: Padding(
          padding: const EdgeInsets.only(top: 25),
          child: Column(children: _rows(taps).take(5).toList()),
        ),
        onStatusBarTap: () => statusBarTaps++,
      ));

      final message =
          await failureOf(tester, () => dispatcher.tap(text: 'row 0'));

      expect(message, contains('status-bar tap area'));
      expect(statusBarTaps, 0);
      expect(taps[0], 0);
      // Seen is not tappable: the row still shows (a person sees it under
      // the status bar), as a banner tap layer's button does.
      expect(walker.checkTextVisible('row 0').visible, isTrue);
      // A row below the band is unaffected.
      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'row 2'));
      expect(taps[2], 1);
    });
  });

  testWidgets(
      'Flutter 3.41+ iOS Scaffold: its status-bar area takes no taps, so a '
      'row under it is tapped where it is', (tester) async {
    final taps = List.filled(30, 0);
    final list = ScrollController();
    addTearDown(list.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: _statusBarHeight),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(
          controller: list,
          padding: EdgeInsets.zero,
          children: _rows(taps),
        ),
      ),
    ));
    list.jumpTo(155);
    await tester.pump();

    await _pumpAndAwait(tester, () => dispatcher.tap(text: 'row 3'));

    expect(taps[3], 1);
    expect(list.offset, 155, reason: 'nothing to reveal: the row was reached');
  });

  group('a translucent layer with its own onTap in front of a button (KI-6)',
      () {
    Widget page({
      required VoidCallback onPay,
      required VoidCallback onLayer,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Center(
                  child: ElevatedButton(
                    onPressed: onPay,
                    child: const Text('Pay'),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: onLayer,
                  ),
                ),
              ],
            ),
          ),
        );

    testWidgets('premise: a real tap there goes to the layer, not the button',
        (tester) async {
      var payTaps = 0;
      var layerTaps = 0;
      await tester.pumpWidget(
        page(onPay: () => payTaps++, onLayer: () => layerTaps++),
      );

      await tester.tapAt(tester.getCenter(find.text('Pay')));
      await tester.pump();

      expect(layerTaps, 1);
      expect(payTaps, 0);
    });

    testWidgets('the tap gate refuses the button instead of passing',
        (tester) async {
      var payTaps = 0;
      var layerTaps = 0;
      await tester.pumpWidget(
        page(onPay: () => payTaps++, onLayer: () => layerTaps++),
      );

      final message =
          await failureOf(tester, () => dispatcher.tap(text: 'Pay'));

      expect(message, contains('GestureDetector'));
      expect(payTaps, 0);
      expect(layerTaps, 0);
    });
  });

  testWidgets(
      'a page-wide tap handler AROUND the page (dismiss the keyboard) still '
      'lets its controls be tapped', (tester) async {
    var payTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: GestureDetector(
        onTap: () {},
        child: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => payTaps++,
              child: const Text('Pay'),
            ),
          ),
        ),
      ),
    ));

    await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Pay'));

    expect(payTaps, 1);
  });
}
