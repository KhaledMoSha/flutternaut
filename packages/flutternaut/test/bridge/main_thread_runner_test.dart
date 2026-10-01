import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/models/action_failure.dart';

void main() {
  group('MainThreadRunner', () {
    testWidgets('returns sync result', (tester) async {
      final runner = MainThreadRunner();

      final future = runner.run<int>(() => 42);
      await tester.pump(); // allow the post-frame callback to fire

      expect(await future, 42);
    });

    testWidgets('awaits async result', (tester) async {
      final runner = MainThreadRunner();

      final future = runner.run<String>(() async {
        return 'done';
      });
      await tester.pump();

      expect(await future, 'done');
    });

    testWidgets('propagates Exception', (tester) async {
      final runner = MainThreadRunner();

      final future = runner.run<void>(() {
        throw Exception('boom');
      });
      // Attach the expectation BEFORE pumping — otherwise the error
      // reaches the test zone as "unhandled" before a listener is added.
      final expectation = expectLater(future, throwsException);
      await tester.pump();

      await expectation;
    });

    testWidgets(
        'fails at once, naming the lifecycle state, when the app draws no '
        'frames', (tester) async {
      final runner = MainThreadRunner();
      addTearDown(() => tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

      var ran = false;
      expect(runner.notDrawingReason, contains('lifecycle state: paused'));
      await expectLater(
        runner.run<void>(() {
          ran = true;
        }),
        throwsA(isA<ActionFailure>().having(
          (f) => f.message,
          'message',
          allOf(contains('in the background'), contains('paused')),
        )),
      );
      expect(ran, isFalse);
    });

    testWidgets('runs again once the app is back in the foreground',
        (tester) async {
      final runner = MainThreadRunner();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      expect(runner.notDrawingReason, isNull);
      final future = runner.run<int>(() => 7);
      await tester.pump();
      expect(await future, 7);
    });

    testWidgets('schedules a frame to fire the callback', (tester) async {
      final runner = MainThreadRunner();
      var ran = false;

      final future = runner.run<void>(() {
        ran = true;
      });
      await tester.pump();
      await future;

      expect(ran, isTrue);
    });
  });
}
