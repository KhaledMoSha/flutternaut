import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';

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
