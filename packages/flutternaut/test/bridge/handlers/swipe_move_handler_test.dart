import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/gesture_handler.dart';
import 'package:flutternaut/src/bridge/handlers/query_handler.dart';
import 'package:flutternaut/src/bridge/router.dart';

import 'route_harness.dart';

/// A full-screen vertical list of 40 rows of 60 px, keyed `list`.
Widget _listApp(
  ScrollController controller, {
  ScrollPhysics? physics,
}) =>
    MaterialApp(
      home: Scaffold(
        body: ListView(
          key: const ValueKey('list'),
          controller: controller,
          physics: physics,
          children: [
            for (var i = 0; i < 40; i++)
              SizedBox(height: 60, child: Text('row $i')),
          ],
        ),
      ),
    );

/// A controller disposed when the test ends.
ScrollController _controller() {
  final c = ScrollController();
  addTearDown(c.dispose);
  return c;
}

void main() {
  late BridgeRouter router;

  setUp(() {
    final walker = TreeWalker();
    final runner = MainThreadRunner();
    router = BridgeRouter(log: (_) {});
    GestureHandler(gesture: GestureDispatcher(walker), runner: runner)
        .register(router);
    QueryHandler(walker: walker, runner: runner).register(router);
  });

  /// POSTs /swipe and returns the response's `data`, failing on any
  /// status but 200.
  Future<Map<String, dynamic>> swipe(
    WidgetTester tester,
    Map<String, dynamic> body,
  ) async {
    final (status, envelope) = await postRoute(tester, router, '/swipe', body);
    expect(status, 200, reason: '$envelope');
    expect(envelope['success'], isTrue);
    return envelope['data'] as Map<String, dynamic>;
  }

  group('/swipe reports moved and room', () {
    testWidgets('direction only: a list that moves reports ~distance, room',
        (tester) async {
      final controller = _controller();
      await tester.pumpWidget(_listApp(controller));

      final data = await swipe(tester, {
        'direction': 'up',
        'distance': 300,
        'fling': false,
      });

      expect(data['success'], isTrue);
      expect(data['action'], 'swipe');
      expect(data['direction'], 'up');
      expect(controller.offset, greaterThan(250),
          reason: 'a 300 px drag moves the list about 300 px less the slop');
      expect(data['moved'], closeTo(controller.offset, 0.001));
      expect(data['moved'], lessThanOrEqualTo(300));
      expect(data['room'], isTrue);
    });

    testWidgets('by scrollIndex: echoes the index next to moved and room',
        (tester) async {
      final controller = _controller();
      await tester.pumpWidget(_listApp(controller));

      final data = await swipe(tester, {
        'scrollIndex': 0,
        'direction': 'up',
        'distance': 200,
        'fling': false,
      });

      expect(data['scrollIndex'], 0);
      expect(data['moved'], closeTo(controller.offset, 0.001));
      expect(data['moved'], greaterThan(0));
      expect(data['room'], isTrue);
    });

    testWidgets('a list whose physics refuse drags: moved 0 with room',
        (tester) async {
      final controller = _controller();
      await tester.pumpWidget(_listApp(
        controller,
        physics: const NeverScrollableScrollPhysics(),
      ));

      final data = await swipe(tester, {
        'scrollIndex': 0,
        'direction': 'up',
        'distance': 300,
        'fling': false,
      });

      expect(data['success'], isTrue,
          reason: 'a swipe that moved nothing is reported, never refused');
      expect(data['moved'], 0);
      expect(data['room'], isTrue);
      expect(controller.offset, 0);
    });

    testWidgets('by key, at the end of the list: moved 0, no room',
        (tester) async {
      final controller = _controller();
      await tester.pumpWidget(_listApp(controller));
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();

      final data = await swipe(tester, {
        'key': 'list',
        'direction': 'up',
        'distance': 300,
        'fling': false,
      });

      expect(data['success'], isTrue);
      expect(data['moved'], 0);
      expect(data['room'], isFalse);
    });

    testWidgets('half a pixel short of the end: no room, so 0 px is no refusal',
        (tester) async {
      final controller = _controller();
      await tester.pumpWidget(_listApp(controller));
      // A ballistic or bouncing scroll can come to rest a fraction of a
      // pixel short of its extent; the list cannot move a pixel further.
      controller.jumpTo(controller.position.maxScrollExtent - 0.5);
      await tester.pump();

      final data = await swipe(tester, {
        'key': 'list',
        'direction': 'up',
        'distance': 300,
        'fling': false,
      });

      expect(data['room'], isFalse,
          reason: 'room needs more than 1 px left, the engine catalog rule');
      expect(data['moved'], lessThan(1));
    });

    testWidgets(
        'a NestedScrollView: the inner list stays while the header list moves',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NestedScrollView(
            headerSliverBuilder: (context, _) => const [
              SliverAppBar(expandedHeight: 300, title: Text('header')),
            ],
            body: ListView(
              key: const ValueKey('inner'),
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(height: 60, child: Text('item $i')),
              ],
            ),
          ),
        ),
      ));
      ScrollPosition positionOf(Finder of) => tester
          .state<ScrollableState>(
              find.descendant(of: of, matching: find.byType(Scrollable)).first)
          .position;
      final inner = positionOf(find.byKey(const ValueKey('inner')));

      final data = await swipe(tester, {
        'scrollIndex': 1,
        'direction': 'up',
        'distance': 120,
        'fling': false,
      });

      expect(inner.pixels, 0,
          reason: 'the drag collapses the header before the inner list moves');
      expect(data['moved'], greaterThan(50),
          reason: 'moved counts the outer list the drag scrolled');
      expect(data['room'], isTrue);
    });

    testWidgets('by key on a row: measures the list the row is in',
        (tester) async {
      final controller = _controller();
      await tester.pumpWidget(_listApp(controller));

      final data = await swipe(tester, {
        'text': 'row 3',
        'direction': 'up',
        'distance': 300,
        'fling': false,
      });

      expect(data['moved'], closeTo(controller.offset, 0.001));
      expect(data['moved'], greaterThan(0));
      expect(data['room'], isTrue);
    });

    testWidgets('a coordinate swipe resolves no scrollable: no moved, no room',
        (tester) async {
      final controller = _controller();
      await tester.pumpWidget(_listApp(controller));

      final data = await swipe(tester, {
        'from': {'x': 200, 'y': 500},
        'to': {'x': 200, 'y': 200},
      });

      expect(data['success'], isTrue);
      expect(data.containsKey('moved'), isFalse);
      expect(data.containsKey('room'), isFalse);
    });

    testWidgets('a locator swipe with no scrollable on the axis: no moved',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: Text('card'))),
      ));

      final data = await swipe(tester, {
        'text': 'card',
        'direction': 'left',
        'distance': 100,
      });

      expect(data['success'], isTrue);
      expect(data.containsKey('moved'), isFalse);
      expect(data.containsKey('room'), isFalse);
    });

    testWidgets('a locator that matches nothing: success false, no moved',
        (tester) async {
      await tester.pumpWidget(_listApp(_controller()));

      final data = await swipe(tester, {
        'key': 'missing',
        'direction': 'up',
      });

      expect(data['success'], isFalse);
      expect(data.containsKey('moved'), isFalse);
    });
  });

  group('/is_visible reports why not', () {
    testWidgets('a text clipped to under 1 px carries the reason',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                width: 0.5,
                height: 20,
                child: Text('sliver'),
              ),
            ],
          ),
        ),
      ));

      final (status, envelope) =
          await postRoute(tester, router, '/is_visible', {'text': 'sliver'});

      expect(status, 200, reason: '$envelope');
      expect(envelope['data'], {
        'visible': false,
        'exists': true,
        'on_screen': false,
        'obstructed': false,
        'reason':
            'text "sliver" exists but is off-screen or clipped to under 1 px',
      });
    });

    testWidgets('a missing widget says that nothing matches', (tester) async {
      await tester.pumpWidget(_listApp(_controller()));

      final (_, envelope) =
          await postRoute(tester, router, '/is_visible', {'key': 'nope'});

      final data = envelope['data'] as Map<String, dynamic>;
      expect(data['exists'], isFalse);
      expect(data['reason'], 'no widget matches key "nope"');
    });

    testWidgets('a visible widget carries no reason', (tester) async {
      await tester.pumpWidget(_listApp(_controller()));

      final (_, envelope) =
          await postRoute(tester, router, '/is_visible', {'text': 'row 0'});

      final data = envelope['data'] as Map<String, dynamic>;
      expect(data['visible'], isTrue);
      expect(data.containsKey('reason'), isFalse);
    });
  });
}
