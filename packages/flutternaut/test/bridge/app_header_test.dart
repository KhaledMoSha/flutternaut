import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/bridge_port.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/health_handler.dart';
import 'package:flutternaut/src/bridge/models/action_failure.dart';
import 'package:flutternaut/src/bridge/router.dart';
import 'package:flutternaut/src/bridge/server.dart';

const _own = 'com.example.shop';
const _other = 'com.example.bank';

String? _noEnvironment(String name) => null;

/// One answer from the bridge: status, decoded envelope and the app the
/// response says answered (`X-Flutternaut-App`, null when absent).
typedef _Answer = ({int status, Map<String, dynamic> body, String? app});

/// The real [HttpClient]: flutter_test replaces it with a stub that never
/// reaches a socket.
class _RealHttpOverrides extends HttpOverrides {}

Future<_Answer> _call(
  int port,
  String method,
  String path, {
  Map<String, String> headers = const {},
  String? body,
}) =>
    HttpOverrides.runZoned(
      () => _send(port, method, path, headers: headers, body: body),
      createHttpClient: (context) =>
          _RealHttpOverrides().createHttpClient(context),
    );

Future<_Answer> _send(
  int port,
  String method,
  String path, {
  required Map<String, String> headers,
  String? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client
        .open(method, InternetAddress.loopbackIPv4.address, port, path)
        .timeout(const Duration(seconds: 5));
    headers.forEach(request.headers.set);
    if (body != null) request.write(body);
    final response = await request.close().timeout(const Duration(seconds: 5));
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 5));
    return (
      status: response.statusCode,
      body: jsonDecode(text) as Map<String, dynamic>,
      app: response.headers.value('X-Flutternaut-App'),
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  // `/health` reads the binding (first frame).
  TestWidgetsFlutterBinding.ensureInitialized();

  group('X-Flutternaut-App', () {
    late HttpServer socket;
    late int taps;

    /// Serves a router that knows itself as [app], with `/health`, a
    /// `/tap` that counts and a `/fail` that refuses.
    Future<void> serve(String? app) async {
      taps = 0;
      final router = BridgeRouter(log: (_) {}, app: app)
        ..post('/tap', (_) {
          taps++;
          return {'tapped': true};
        })
        ..post('/fail', (_) => throw ActionFailure('target is covered'));
      HealthHandler(
        walker: TreeWalker(),
        runner: MainThreadRunner(),
        boundPort: () => socket.port,
        environment: _noEnvironment,
        app: app,
      ).register(router);
      socket = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => socket.close(force: true));
      socket.listen(router.handle);
    }

    test('a request meant for this app runs as before', () async {
      await serve(_own);
      final answer = await _call(socket.port, 'POST', '/tap',
          headers: {'X-Flutternaut-App': _own}, body: '{}');

      expect(answer.status, 200);
      expect(answer.body, {
        'success': true,
        'data': {'tapped': true},
      });
      expect(answer.app, _own);
      expect(taps, 1);
    });

    test(
        'a request meant for another app is refused with 409 and nothing '
        'runs', () async {
      await serve(_own);
      final answer = await _call(socket.port, 'POST', '/tap',
          headers: {'X-Flutternaut-App': _other}, body: '{"text": "Pay"}');

      expect(answer.status, 409);
      expect(answer.body['success'], isFalse);
      expect(
        answer.body['error'],
        allOf(
          startsWith('This bridge belongs to $_own, but the request was '
              'meant for $_other: another app holds the bridge port.'),
          contains('Nothing was run'),
        ),
      );
      expect(answer.app, _own);
      expect(taps, 0, reason: 'the handler must not run');
    });

    test('the header name is case-insensitive; the value is exact', () async {
      await serve(_own);
      final lower = await _call(socket.port, 'POST', '/tap',
          headers: {'x-flutternaut-app': ' $_own '}, body: '{}');
      expect(lower.status, 200);
      expect(taps, 1);

      final upper = await _call(socket.port, 'POST', '/tap',
          headers: {'X-Flutternaut-App': _own.toUpperCase()}, body: '{}');
      expect(upper.status, 409);
      expect(taps, 1);
    });

    test('/health answers whoever asks, naming its app', () async {
      await serve(_own);
      final answer = await _call(socket.port, 'GET', '/health',
          headers: {'X-Flutternaut-App': _other});

      expect(answer.status, 200);
      expect((answer.body['data'] as Map<String, dynamic>)['app'], _own);
      expect(answer.app, _own);
    });

    test('no header: as before, and the response names the app', () async {
      await serve(_own);
      final answer = await _call(socket.port, 'POST', '/tap', body: '{}');

      expect(answer.status, 200);
      expect(answer.app, _own);
      expect(taps, 1);
    });

    test('an empty or blank header is no header', () async {
      await serve(_own);
      for (final value in ['', '   ']) {
        final answer = await _call(socket.port, 'POST', '/tap',
            headers: {'X-Flutternaut-App': value}, body: '{}');
        expect(answer.status, 200, reason: 'header "$value"');
      }
      expect(taps, 2);
    });

    test('an unknown route: 404 with the header; another app: 409', () async {
      await serve(_own);
      final missing = await _call(socket.port, 'GET', '/nope');
      expect(missing.status, 404);
      expect(missing.app, _own);

      final elsewhere = await _call(socket.port, 'GET', '/nope',
          headers: {'X-Flutternaut-App': _other});
      expect(elsewhere.status, 409);
      expect(elsewhere.app, _own);
    });

    test('a refused action still names the app', () async {
      await serve(_own);
      final answer = await _call(socket.port, 'POST', '/fail',
          headers: {'X-Flutternaut-App': _own}, body: '{}');

      expect(answer.status, 422);
      expect(answer.body['error'], 'target is covered');
      expect(answer.app, _own);
    });

    test(
        'a bridge that does not know its app cannot compare: it runs the '
        'request and names no app', () async {
      await serve(null);
      final answer = await _call(socket.port, 'POST', '/tap',
          headers: {'X-Flutternaut-App': _other}, body: '{}');

      expect(answer.status, 200);
      expect(answer.app, isNull);
      expect(taps, 1);

      final health = await _call(socket.port, 'GET', '/health');
      expect(health.app, isNull);
      expect(
        (health.body['data'] as Map<String, dynamic>).containsKey('app'),
        isFalse,
      );
    });
  });

  group('BridgeServer', () {
    test('/health and every route carry the app the server read', () async {
      final server = BridgeServer(
        log: (_) {},
        environment: _noEnvironment,
        address: InternetAddress.loopbackIPv4,
        appIdentity: () => _own,
      );
      addTearDown(server.stop);
      await server.start(const BridgePort(0, BridgePortSource.argument));
      final port = server.port;
      if (port == null) fail('the server is not bound');

      final health = await _call(port, 'GET', '/health');
      expect((health.body['data'] as Map<String, dynamic>)['app'], _own);
      expect(health.app, _own);

      final refused = await _call(port, 'GET', '/screen',
          headers: {'X-Flutternaut-App': _other});
      expect(refused.status, 409);
      expect(refused.app, _own);
    });
  });
}
