import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/health_handler.dart';
import 'package:flutternaut/src/bridge/handlers/wait_handler.dart';
import 'package:flutternaut/src/bridge/router.dart';

/// Sends one request to [router] over a real loopback socket and returns the
/// status and decoded envelope. Must run inside `tester.runAsync`.
Future<(int, Map<String, dynamic>)> _call(
  BridgeRouter router,
  String method,
  String path, {
  Map<String, dynamic>? body,
}) {
  // flutter_test replaces HttpClient with a stub that never reaches a
  // socket; these tests need the real one.
  return HttpOverrides.runZoned(
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      try {
        server.listen(router.handle);
        final request = await client
            .open(
                method, InternetAddress.loopbackIPv4.address, server.port, path)
            .timeout(const Duration(seconds: 5));
        if (body != null) request.write(jsonEncode(body));
        final response =
            await request.close().timeout(const Duration(seconds: 5));
        final text = await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 5));
        return (
          response.statusCode,
          jsonDecode(text) as Map<String, dynamic>,
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
    createHttpClient: (context) =>
        _RealHttpOverrides().createHttpClient(context),
  );
}

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  // While the app is hidden or paused Flutter draws no frames, so a
  // post-frame callback never fires. Before the guard these calls were left
  // unanswered and reached the engine as a 15 s "the app is busy".
  group('an app in the background', () {
    late BridgeRouter router;

    setUp(() {
      final walker = TreeWalker();
      final runner = MainThreadRunner();
      router = BridgeRouter(log: (_) {});
      HealthHandler(walker: walker, runner: runner).register(router);
      WaitHandler(walker: walker, runner: runner).register(router);
    });

    testWidgets('a screen read is refused at once with the lifecycle state',
        (tester) async {
      addTearDown(() => tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

      final result =
          await tester.runAsync(() => _call(router, 'GET', '/screen'));

      final (status, body) = result!;
      expect(status, 422);
      expect(body['success'], isFalse);
      expect(
        body['error'],
        allOf(contains('in the background'), contains('paused')),
      );
    });

    testWidgets(
        'a wait keeps polling and, on timeout, reports the background as '
        'its detail', (tester) async {
      addTearDown(() => tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

      final result = await tester.runAsync(() => _call(
            router,
            'POST',
            '/wait_for_idle',
            body: {'timeout_ms': 200},
          ));

      final (status, body) = result!;
      expect(status, 200);
      final data = body['data'] as Map<String, dynamic>;
      expect(data['success'], isFalse);
      expect(data['elapsed_ms'], greaterThanOrEqualTo(200));
      expect(
        data['detail'],
        allOf(contains('in the background'), contains('hidden')),
      );
    });

    testWidgets('/health still answers', (tester) async {
      addTearDown(() => tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

      final result =
          await tester.runAsync(() => _call(router, 'GET', '/health'));

      final (status, body) = result!;
      expect(status, 200);
      expect((body['data'] as Map<String, dynamic>)['status'], 'ok');
    });
  });
}
