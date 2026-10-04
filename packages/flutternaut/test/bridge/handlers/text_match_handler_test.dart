import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/assert_handler.dart';
import 'package:flutternaut/src/bridge/handlers/gesture_handler.dart';
import 'package:flutternaut/src/bridge/handlers/query_handler.dart';
import 'package:flutternaut/src/bridge/handlers/wait_handler.dart';
import 'package:flutternaut/src/bridge/router.dart';

import 'route_harness.dart';

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

const _unknownMatch =
    'match must be "exact", "contains" or "starts_with", got "fuzzy"';

void main() {
  late BridgeRouter router;

  setUp(() {
    final walker = TreeWalker();
    final runner = MainThreadRunner();
    router = BridgeRouter(log: (_) {});
    GestureHandler(gesture: GestureDispatcher(walker), runner: runner)
        .register(router);
    QueryHandler(walker: walker, runner: runner).register(router);
    AssertHandler(walker: walker, runner: runner).register(router);
    WaitHandler(walker: walker, runner: runner).register(router);
  });

  group('/tap', () {
    testWidgets('match starts_with taps the label with that prefix',
        (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(_app(Column(children: [
        GestureDetector(
          onTap: () => taps.add('infix'),
          child: const Text('Start Free Trial'),
        ),
        GestureDetector(
          onTap: () => taps.add('prefix'),
          child: const Text('Free Trial · 7 days'),
        ),
      ])));

      final (status, body) = await postRoute(tester, router, '/tap', {
        'text': 'free trial',
        'match': 'starts_with',
      });

      expect(status, 200, reason: '$body');
      final data = body['data'] as Map<String, dynamic>;
      expect(data['success'], isTrue);
      expect(data['hit'], contains('"Free Trial · 7 days"'));
      expect(taps, ['prefix']);
    });

    testWidgets('an unknown match is a 400 and taps nothing', (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(_app(GestureDetector(
        onTap: () => taps.add('tapped'),
        child: const Text('Sign In'),
      )));

      final (status, body) = await postRoute(tester, router, '/tap', {
        'text': 'Sign In',
        'match': 'fuzzy',
      });

      expect(status, 400);
      expect(body, {'success': false, 'error': _unknownMatch});
      expect(taps, isEmpty);
    });

    testWidgets('a whitespace-only text with starts_with is a 400',
        (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(_app(GestureDetector(
        onTap: () => taps.add('tapped'),
        child: const Text('Sign In'),
      )));

      final (status, body) = await postRoute(tester, router, '/tap', {
        'text': '  ',
        'match': 'starts_with',
      });

      expect(status, 400);
      expect(body['error'], contains('needs at least one visible character'));
      expect(taps, isEmpty);
    });

    testWidgets('a match that is not a string is a 400 as well',
        (tester) async {
      await tester.pumpWidget(_app(const Text('Sign In')));

      final (status, body) = await postRoute(tester, router, '/tap', {
        'text': 'Sign In',
        'match': 1,
      });

      expect(status, 400);
      expect(
        body['error'],
        'match must be "exact", "contains" or "starts_with", got "1"',
      );
    });
  });

  group('/long_press', () {
    Widget pressables(List<String> pressed) => _app(Column(children: [
          GestureDetector(
            onLongPress: () => pressed.add('order'),
            child: const Text('Order #1042 · pending'),
          ),
          GestureDetector(
            onLongPress: () => pressed.add('other'),
            child: const Text('Archive'),
          ),
        ]));

    testWidgets('match contains reaches the widget (it used to be ignored)',
        (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(pressables(pressed));

      final (status, body) = await postRoute(tester, router, '/long_press', {
        'text': '#1042',
        'match': 'contains',
      });

      expect(status, 200, reason: '$body');
      expect((body['data'] as Map<String, dynamic>)['hit'],
          contains('"Order #1042 · pending"'));
      expect(pressed, ['order']);
    });

    testWidgets('match starts_with reaches the widget', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(pressables(pressed));

      final (status, body) = await postRoute(tester, router, '/long_press', {
        'text': 'ORDER #',
        'match': 'starts_with',
      });

      expect(status, 200, reason: '$body');
      expect(pressed, ['order']);
    });

    testWidgets('an unknown match is a 400 and presses nothing',
        (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(pressables(pressed));

      final (status, body) = await postRoute(tester, router, '/long_press', {
        'text': 'Archive',
        'match': 'fuzzy',
      });

      expect(status, 400);
      expect(body, {'success': false, 'error': _unknownMatch});
      expect(pressed, isEmpty);
    });
  });

  group('visibility routes', () {
    testWidgets('/is_visible honours starts_with', (tester) async {
      await tester.pumpWidget(_app(const Text('Bag · 3')));

      final (status, body) = await postRoute(tester, router, '/is_visible', {
        'text': 'bag',
        'match': 'starts_with',
      });

      expect(status, 200, reason: '$body');
      expect((body['data'] as Map<String, dynamic>)['visible'], isTrue);
    });

    testWidgets('/assert_visible names the starts_with comparison on a miss',
        (tester) async {
      await tester.pumpWidget(_app(const Text('Your Bag · 3')));

      final (status, body) = await postRoute(tester, router, '/assert_visible', {
        'text': 'Bag',
        'match': 'starts_with',
      });

      expect(status, 200, reason: '$body');
      final data = body['data'] as Map<String, dynamic>;
      expect(data['passed'], isFalse);
      expect('$data', contains('text starting with "Bag"'));
    });

    for (final path in ['/is_visible', '/assert_visible', '/get_text']) {
      testWidgets('$path rejects an unknown match with a 400', (tester) async {
        await tester.pumpWidget(_app(const Text('Bag · 3')));

        final (status, body) = await postRoute(tester, router, path, {
          'text': 'Bag · 3',
          'match': 'fuzzy',
        });

        expect(status, 400);
        expect(body, {'success': false, 'error': _unknownMatch});
      });
    }

    testWidgets(
        '/wait_until_visible rejects an unknown match at once, even while '
        'the app is in the background', (tester) async {
      addTearDown(() => tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

      final (status, body) = await postRoute(tester, router, '/wait_until_visible',
          {'text': 'Bag', 'match': 'fuzzy', 'timeout_ms': 5000});

      expect(status, 400);
      expect(body, {'success': false, 'error': _unknownMatch});
    });
  });
}
