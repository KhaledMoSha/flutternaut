import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/models/action_failure.dart';

/// The 402x874 logical-pixel screen of the device the sliver was found on
/// (an iPhone 17 simulator), at a device pixel ratio of 1.
const _screen = Size(402, 874);

/// The width of the sliver a fractional `PageView` offset leaves of the next
/// page at the screen's right edge (seen live: x=401.99998, w=0.00002).
const _sliver = 0.00002;

/// Runs a dispatcher call to completion under fake time (see the same
/// helper in gesture_dispatcher_test.dart). A failure is marked handled at
/// once so the test zone does not report it before the caller's matcher.
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

/// Sets the test view to [_screen] for the rest of the test.
void _useScreen(WidgetTester tester) {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A controller disposed when the test ends.
ScrollController _controller() {
  final c = ScrollController();
  addTearDown(c.dispose);
  return c;
}

/// A vertical list of 40 rows of 60 px, `<name> 0` … `<name> 39`.
Widget _list(String name, ScrollController controller) => ListView(
      key: ValueKey('${name}_list'),
      controller: controller,
      children: [
        for (var i = 0; i < 40; i++)
          SizedBox(height: 60, child: Text('$name $i')),
      ],
    );

/// A list [_sliver] px wide at the screen's right edge, first in tree order,
/// beside a real 300 px list — the shape of a wrapper positioned at the edge.
Widget _edgeSliverBesideRealList(
  ScrollController sliver,
  ScrollController real,
) =>
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: _screen.width - _sliver,
              top: 0,
              bottom: 0,
              width: _sliver,
              child: _list('log', sliver),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 300,
              child: _list('row', real),
            ),
          ],
        ),
      ),
    );

/// A root `PageView` the app cannot page (a debug overlay such as
/// `requests_inspector` wraps the app in one), its offset left [_sliver] px
/// past page 0, so page 1 — an inspector list and a button — sits at
/// x = 401.99998 with [_sliver] px of it on screen. Page snapping is off so
/// the fractional offset stays put (a snapping `PageView` settles it back
/// onto page 0 at once).
Widget _pagedApp(
  PageController pages,
  ScrollController real,
  ScrollController hidden,
) =>
    MaterialApp(
      home: PageView(
        controller: pages,
        pageSnapping: false,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          Scaffold(body: _list('row', real)),
          Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  key: const ValueKey('inspector_clear'),
                  onPressed: () {},
                  child: const Text('Clear'),
                ),
                Expanded(child: _list('log', hidden)),
              ],
            ),
          ),
        ],
      ),
    );

List<Map<String, dynamic>> _flatten(List<dynamic> nodes) {
  final out = <Map<String, dynamic>>[];
  void visit(Map<String, dynamic> n) {
    out.add(n);
    for (final c in (n['children'] as List?) ?? const []) {
      visit(c as Map<String, dynamic>);
    }
  }

  for (final n in nodes) {
    visit(n as Map<String, dynamic>);
  }
  return out;
}

void main() {
  final walker = TreeWalker();
  late GestureDispatcher dispatcher;
  setUp(() => dispatcher = GestureDispatcher(walker));

  List<Map<String, dynamic>> dumpNodes() =>
      _flatten(walker.dumpVisibleTree()['elements'] as List);

  /// The element keyed [key] — failing the test when the fixture did not
  /// build it, so a sliver that was never laid out cannot pass as hidden.
  Element keyed(String key) {
    final element = walker.findElementByKey(key);
    expect(element, isNotNull, reason: 'the fixture must build "$key"');
    return element!;
  }

  /// Asserts [element] really is a sub-pixel sliver at the screen's right
  /// edge: laid out, with a positive visible width under one pixel.
  void expectSliver(Element element) {
    final visible = walker.visibleRectOf(element);
    expect(visible, isNotNull);
    expect(visible!.left, closeTo(_screen.width - _sliver, 1e-6));
    expect(visible.width, greaterThan(0));
    expect(visible.width, lessThan(TreeWalkerGeometry.minVisibleSide));
  }

  group('a list at the screen edge under 1 px wide', () {
    testWidgets(
        'is no dump node, takes no scrollIndex, and index 0 is the '
        'real list', (tester) async {
      _useScreen(tester);
      final sliver = _controller();
      final real = _controller();
      await tester.pumpWidget(_edgeSliverBesideRealList(sliver, real));
      expectSliver(keyed('log_list'));

      final nodes = dumpNodes();
      expect(nodes.where((n) => n['key'] == 'log_list'), isEmpty);
      expect(nodes.where((n) => n['text'] == 'log 0'), isEmpty,
          reason: 'the rows of the sliver are judged on their own rects');
      final scrollables = nodes.where((n) => n['scrollable'] == true).toList();
      expect(scrollables.map((n) => (n['key'], n['scrollIndex'])),
          [('row_list', 0)]);
      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(1));

      final move = await _pumpAndAwait(
        tester,
        () => dispatcher.swipeAtIndex(0, 'up', 300, fling: false),
      );
      expect(real.offset, greaterThan(0), reason: 'index 0 is the real list');
      expect(sliver.offset, 0, reason: 'the sliver is never swiped');
      expect(move?.moved, closeTo(real.offset, 0.001));
    });

    testWidgets('index 1 is out of range: the sliver is not swipe-resolvable',
        (tester) async {
      _useScreen(tester);
      await tester.pumpWidget(
        _edgeSliverBesideRealList(_controller(), _controller()),
      );

      // Pumped, so a bridge that wrongly swipes the sliver finishes the
      // gesture and fails here instead of waiting on a frame forever.
      final message = await _pumpAndAwait(
        tester,
        () => dispatcher.swipeAtIndex(1, 'up', 300),
      ).then<String>(
        (_) => fail('scrollIndex 1 must not resolve to the sliver'),
        onError: (Object e) => (e as ActionFailure).message,
      );
      expect(message, contains('1 vertical scrollable(s) are visible'));
    });

    testWidgets('its text is not visible, with the under-1-px reason',
        (tester) async {
      _useScreen(tester);
      await tester.pumpWidget(
        _edgeSliverBesideRealList(_controller(), _controller()),
      );

      final result = walker.checkTextVisible('log 0');
      expect(result.exists, isTrue);
      expect(result.visible, isFalse);
      expect(result.onScreen, isFalse);
      expect(result.reason,
          'text "log 0" exists but is off-screen or clipped to under 1 px');
      expect(walker.checkTextVisible('row 0').visible, isTrue);
    });
  });

  group('a PageView page with 0.00002 px on screen', () {
    Future<(ScrollController, ScrollController)> pumpPaged(
      WidgetTester tester,
    ) async {
      _useScreen(tester);
      final pages = PageController();
      addTearDown(pages.dispose);
      final real = _controller();
      final hidden = _controller();
      await tester.pumpWidget(_pagedApp(pages, real, hidden));
      pages.jumpTo(_sliver);
      await tester.pump();
      expectSliver(keyed('log_list'));
      return (real, hidden);
    }

    testWidgets('shows nothing of its page in the dump', (tester) async {
      await pumpPaged(tester);

      final nodes = dumpNodes();
      expect(nodes.where((n) => n['key'] == 'log_list'), isEmpty);
      expect(nodes.where((n) => n['key'] == 'inspector_clear'), isEmpty);
      expect(nodes.where((n) => n['text'] == 'row 0'), isNotEmpty,
          reason: 'page 0, all but 0.00002 px of it, is on screen');
      final vertical = nodes
          .where((n) => n['scrollable'] == true && n['axis'] == 'vertical')
          .map((n) => (n['key'], n['scrollIndex']))
          .toList();
      expect(vertical, [('row_list', 0)]);
    });

    testWidgets('the auto-pick scrolls page 0, never the sliver',
        (tester) async {
      final (real, hidden) = await pumpPaged(tester);

      final move = await _pumpAndAwait(
        tester,
        () => dispatcher.swipeAuto('up', 300, fling: false),
      );
      expect(real.offset, greaterThan(0));
      expect(hidden.offset, 0);
      expect(move?.room, isTrue);
    });

    testWidgets('a tap on its button is refused as off screen', (tester) async {
      await pumpPaged(tester);

      final message = await _pumpAndAwait(
        tester,
        () => dispatcher.tap(key: 'inspector_clear'),
      ).then<String>(
        (_) => fail('a tap on a 0.00002 px button must be refused'),
        onError: (Object e) => (e as ActionFailure).message,
      );
      expect(message, contains('key "inspector_clear" is present'));
      expect(message, contains('but not on screen'));
      expect(message, contains('shows under 1 px of itself'));
    });
  });

  testWidgets('a duplicate 0.5 px wide takes no nth', (tester) async {
    _useScreen(tester);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            // First in reading order: before the rule it was nth 0 and the
            // real label nth 1.
            Positioned(
              left: 0,
              top: 0,
              width: 0.5,
              height: 20,
              child: Text('Save', key: ValueKey('sliver_save')),
            ),
            Positioned(
              left: 100,
              top: 200,
              child: Text('Save', key: ValueKey('real_save')),
            ),
          ],
        ),
      ),
    ));
    final sliverRect = walker.visibleRectOf(keyed('sliver_save'));
    expect(sliverRect?.width, 0.5);

    final visible = walker.visibleMatches(walker.findAllElementsByText('Save'));
    expect(visible.map((e) => TreeWalker.keyOf(e.widget)), ['real_save']);
    final saves = dumpNodes().where((n) => n['text'] == 'Save').toList();
    expect(saves, hasLength(1));
    expect(saves.single['key'], 'real_save');
    expect(saves.single.containsKey('text_nth'), isFalse,
        reason: 'one visible "Save" needs no nth');
    expect(walker.checkTextVisible('Save', nth: 1).visible, isFalse);
    expect(walker.checkTextVisible('Save', nth: 0).visible, isTrue);
  });

  group('the auto-pick ranks lists by their visible area (KI-7)', () {
    testWidgets('a list mostly off screen loses to a smaller one that shows',
        (tester) async {
      _useScreen(tester);
      final wide = _controller();
      final shown = _controller();
      // `wide` is 2000 px wide but only 102 px of it is on screen (89,148
      // px²); `shown` is 250 px, all on screen (218,500 px²). By the whole
      // rect `wide` dominated; by what shows `shown` does.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 300,
                top: 0,
                bottom: 0,
                width: 2000,
                child: _list('wide', wide),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 250,
                child: _list('shown', shown),
              ),
            ],
          ),
        ),
      ));
      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(2));

      final chosen = dispatcher.resolveScrollable('up');
      expect(walker.visibleRectOf(chosen)?.width, 250);

      await _pumpAndAwait(
        tester,
        () => dispatcher.swipeAuto('up', 300, fling: false),
      );
      expect(shown.offset, greaterThan(0));
      expect(wide.offset, 0);
    });
  });
}
