import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/app_handler.dart';
import 'package:flutternaut/src/bridge/handlers/assert_handler.dart';
import 'package:flutternaut/src/bridge/handlers/find_handler.dart';
import 'package:flutternaut/src/bridge/handlers/gesture_handler.dart';
import 'package:flutternaut/src/bridge/handlers/health_handler.dart';
import 'package:flutternaut/src/bridge/handlers/query_handler.dart';
import 'package:flutternaut/src/bridge/handlers/wait_handler.dart';
import 'package:flutternaut/src/bridge/router.dart';

void main() {
  late TreeWalker walker;
  late GestureDispatcher gesture;
  late MainThreadRunner runner;
  late BridgeRouter router;

  setUp(() {
    walker = TreeWalker();
    gesture = GestureDispatcher(walker);
    runner = MainThreadRunner();
    router = BridgeRouter();
  });

  group('route registration counts', () {
    test('HealthHandler registers 4 routes', () {
      HealthHandler(walker: walker, runner: runner).register(router);
      expect(router.routeCount, 4);
    });

    test('FindHandler registers 2 routes', () {
      FindHandler(walker: walker, runner: runner).register(router);
      expect(router.routeCount, 2);
    });

    test('GestureHandler registers 9 routes', () {
      GestureHandler(gesture: gesture, runner: runner).register(router);
      expect(router.routeCount, 9);
    });

    test('QueryHandler registers 4 routes', () {
      QueryHandler(walker: walker, runner: runner).register(router);
      expect(router.routeCount, 4);
    });

    test('AssertHandler registers 8 routes', () {
      AssertHandler(walker: walker, runner: runner).register(router);
      expect(router.routeCount, 8);
    });

    test('WaitHandler registers 5 routes', () {
      WaitHandler(walker: walker, runner: runner).register(router);
      expect(router.routeCount, 5);
    });

    test('AppHandler registers 1 route', () {
      AppHandler(runner: runner).register(router);
      expect(router.routeCount, 1);
    });
  });

  test('all handlers register without path collisions', () {
    HealthHandler(walker: walker, runner: runner).register(router);
    FindHandler(walker: walker, runner: runner).register(router);
    GestureHandler(gesture: gesture, runner: runner).register(router);
    QueryHandler(walker: walker, runner: runner).register(router);
    AssertHandler(walker: walker, runner: runner).register(router);
    WaitHandler(walker: walker, runner: runner).register(router);
    AppHandler(runner: runner).register(router);

    // Total: 4 + 2 + 9 + 4 + 8 + 5 + 1 = 33. If any duplicate path existed,
    // the Map in BridgeRouter would collapse them and the count would be less.
    expect(router.routeCount, 33);
  });
}
