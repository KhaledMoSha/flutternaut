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
