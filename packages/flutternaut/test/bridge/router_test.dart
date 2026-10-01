import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/router.dart';

/// Fake HttpRequest — we only exercise BridgeRequest's body accessors,
/// never the raw HttpRequest API, so noSuchMethod is sufficient.
class _FakeHttpRequest implements HttpRequest {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BridgeRequest _req(Map<String, dynamic> body) =>
    BridgeRequest(_FakeHttpRequest(), body);

void main() {
  group('BridgeRequest', () {
    group('string()', () {
      test('returns string when present', () {
        expect(_req({'key': 'btn'}).string('key'), 'btn');
      });

      test('returns null when absent', () {
        expect(_req(const {}).string('key'), isNull);
      });

      test('returns null when wrong type', () {
        expect(_req({'key': 42}).string('key'), isNull);
      });
    });

    group('number()', () {
      test('reads int as double', () {
        expect(_req({'x': 10}).number('x'), 10.0);
      });

      test('reads double directly', () {
        expect(_req({'x': 3.14}).number('x'), 3.14);
      });

      test('uses default when absent', () {
        expect(_req(const {}).number('x', defaultValue: 99), 99.0);
      });
    });

    group('integer()', () {
      test('reads int', () {
        expect(_req({'n': 5}).integer('n'), 5);
      });

      test('truncates double', () {
        expect(_req({'n': 5.9}).integer('n'), 5);
      });

      test('uses default when absent', () {
        expect(_req(const {}).integer('n', defaultValue: 7), 7);
      });
    });

    group('boolean()', () {
      test('reads bool', () {
        expect(_req({'b': true}).boolean('b'), isTrue);
      });

      test('uses default when absent', () {
        expect(_req(const {}).boolean('b', defaultValue: true), isTrue);
      });
    });

    group('map()', () {
      test('returns nested map', () {
        final nested = {'x': 1};
        expect(_req({'from': nested}).map('from'), nested);
      });

      test('returns null when not a map', () {
        expect(_req({'from': 'nope'}).map('from'), isNull);
      });
    });

    group('locators', () {
      test('hasLocator true when key present', () {
        expect(_req({'key': 'x'}).hasLocator, isTrue);
      });

      test('hasLocator true when text present', () {
        expect(_req({'text': 'x'}).hasLocator, isTrue);
      });

      test('hasLocator false when neither', () {
        expect(_req(const {}).hasLocator, isFalse);
      });

      test('requireLocator throws when missing', () {
        expect(() => _req(const {}).requireLocator(), throwsArgumentError);
      });

      test('requireLocator passes when key present', () {
        expect(() => _req({'key': 'x'}).requireLocator(), returnsNormally);
      });
    });

    test('require() throws when field missing', () {
      expect(() => _req(const {}).require('expected'), throwsArgumentError);
    });

    test('require() passes when field present', () {
      expect(() => _req({'expected': 'x'}).require('expected'), returnsNormally);
    });
  });

  // Every request must be answered: an unanswered one reaches the engine as
  // a 15 s timeout that reads like a blocked app.
  group('BridgeRouter.handle over a real socket', () {
    late HttpServer server;
    late HttpClient client;
    final logged = <String>[];

    Future<(int, Map<String, dynamic>)> call(
      BridgeRouter router,
      String method,
      String path, {
      String? body,
    }) async {
      server.listen(router.handle);
      final request = await client
          .open(method, InternetAddress.loopbackIPv4.address, server.port, path)
          .timeout(const Duration(seconds: 5));
      if (body != null) request.write(body);
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 5));
      return (response.statusCode, jsonDecode(text) as Map<String, dynamic>);
    }

    setUp(() async {
      logged.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });

    test('wraps handler data in the success envelope', () async {
      final router = BridgeRouter(log: logged.add)
        ..get('/screen', (_) => {'count': 1});

      final (status, body) = await call(router, 'GET', '/screen');

      expect(status, 200);
      expect(body, {
        'success': true,
        'data': {'count': 1},
      });
    });

    test(
        'a non-finite number in the response is answered with a 500 that '
        'names the field — not left unanswered', () async {
      final router = BridgeRouter(log: logged.add)
        ..get(
          '/screen',
          (_) => {
            'elements': [
              {
                'type': 'PageView',
                'children': [
                  {'type': 'Scrollable', 'maxScrollExtent': double.infinity},
                ],
              },
            ],
          },
        );

      final (status, body) = await call(router, 'GET', '/screen');

      expect(status, 500);
      expect(body['success'], isFalse);
      final error = body['error'] as String;
      expect(error, startsWith('internal bridge error: '));
      expect(error, contains('Infinity'));
      expect(error, contains('"type":"Scrollable","maxScrollExtent":'));
      expect(logged.single, contains('GET /screen'));
    });

    test('NaN is reported the same way', () async {
      final router = BridgeRouter(log: logged.add)
        ..get('/find', (_) => {'rect': {'x': double.nan}});

      final (status, body) = await call(router, 'GET', '/find');

      expect(status, 500);
      expect(body['error'], contains('NaN'));
      expect(body['error'], contains('"x":'));
    });

    test('an Error thrown by a handler is answered with a 500', () async {
      final router = BridgeRouter(log: logged.add)
        ..get('/screen', (_) => throw StateError('walker broke'));

      final (status, body) = await call(router, 'GET', '/screen');

      expect(status, 500);
      expect(body['success'], isFalse);
      expect(body['error'], 'internal bridge error: Bad state: walker broke');
      expect(logged.single, contains('GET /screen'));
    });

    test('a JSON body that is not an object is answered with a 500',
        () async {
      var reached = false;
      final router = BridgeRouter(log: logged.add)
        ..post('/tap', (_) {
          reached = true;
          return {};
        });

      final (status, body) = await call(router, 'POST', '/tap', body: '[1,2]');

      expect(status, 500);
      expect(body['error'], startsWith('internal bridge error: '));
      expect(reached, isFalse);
    });

    test('malformed JSON stays a 400', () async {
      final router = BridgeRouter(log: logged.add)..post('/tap', (_) => {});

      final (status, body) = await call(router, 'POST', '/tap', body: '{nope');

      expect(status, 400);
      expect(body['error'], startsWith('Invalid JSON'));
    });

    test('an unknown route is a 404', () async {
      final (status, body) =
          await call(BridgeRouter(log: logged.add), 'GET', '/nope');

      expect(status, 404);
      expect(body['error'], 'Not found: GET /nope');
    });
  });

  group('BridgeRouter', () {
    test('starts with zero routes', () {
      final router = BridgeRouter();
      expect(router.routeCount, 0);
    });

    test('get() registers a route', () {
      final router = BridgeRouter()..get('/health', (_) async => {});
      expect(router.routeCount, 1);
    });

    test('post() registers a route', () {
      final router = BridgeRouter()..post('/tap', (_) async => {});
      expect(router.routeCount, 1);
    });

    test('multiple routes accumulate', () {
      final router = BridgeRouter()
        ..get('/health', (_) async => {})
        ..post('/tap', (_) async => {})
        ..post('/find', (_) async => {});
      expect(router.routeCount, 3);
    });
  });
}
