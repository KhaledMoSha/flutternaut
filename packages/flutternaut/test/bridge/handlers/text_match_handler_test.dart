import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// An in-memory [HttpRequest] carrying a JSON [body]. The router only reads
/// the method, the path, the body stream and the response; everything else
/// is unreachable here.
///
/// A real socket cannot be used for these routes: their work runs in a
/// post-frame callback, so the test must pump frames while the request is
/// in flight — and pumping is not possible inside `tester.runAsync`, which
/// real I/O needs. An in-memory request stays in the test's fake-async zone.
class _FakeRequest extends Stream<Uint8List> implements HttpRequest {
  _FakeRequest(this.method, String path, Map<String, dynamic> body)
      : uri = Uri.parse(path),
        _bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));

  @override
  final String method;

  @override
  final Uri uri;

  final Uint8List _bytes;

  @override
  final _FakeResponse response = _FakeResponse();

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<Uint8List>.value(_bytes).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Collects what the router writes and completes [done] when it closes.
class _FakeResponse implements HttpResponse {
  @override
  int statusCode = HttpStatus.ok;

  @override
  int contentLength = -1;

  @override
  final HttpHeaders headers = _FakeHeaders();

  final BytesBuilder _written = BytesBuilder();
  final Completer<void> _closed = Completer<void>();

  /// Completes once the router has answered.
  Future<void> get answered => _closed.future;

  /// The decoded response envelope.
  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(_written.toBytes())) as Map<String, dynamic>;

  @override
  void add(List<int> data) => _written.add(data);

  @override
  Future<void> close() async => _closed.complete();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  @override
  ContentType? contentType;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// POSTs [body] to [path] on [router], pumping frames until it answers, and
/// returns the status and envelope. Pumps at a fixed cadence for the same
/// reason as the gesture tests: a long press waits on fake time as well as
/// on frames.
Future<(int, Map<String, dynamic>)> _post(
  WidgetTester tester,
  BridgeRouter router,
  String path,
  Map<String, dynamic> body,
) async {
  final request = _FakeRequest('POST', path, body);
  var answered = false;
  unawaited(router.handle(request));
  unawaited(request.response.answered.then((_) => answered = true));
  const step = Duration(milliseconds: 50);
  for (var i = 0; i < 200 && !answered; i++) {
    await tester.pump(step);
  }
  if (!answered) fail('POST $path was not answered within 10 s of fake time');
  return (request.response.statusCode, request.response.json);
}

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

      final (status, body) = await _post(tester, router, '/tap', {
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

      final (status, body) = await _post(tester, router, '/tap', {
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

      final (status, body) = await _post(tester, router, '/tap', {
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

      final (status, body) = await _post(tester, router, '/tap', {
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

      final (status, body) = await _post(tester, router, '/long_press', {
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

      final (status, body) = await _post(tester, router, '/long_press', {
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

      final (status, body) = await _post(tester, router, '/long_press', {
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

      final (status, body) = await _post(tester, router, '/is_visible', {
        'text': 'bag',
        'match': 'starts_with',
      });

      expect(status, 200, reason: '$body');
      expect((body['data'] as Map<String, dynamic>)['visible'], isTrue);
    });

    testWidgets('/assert_visible names the starts_with comparison on a miss',
        (tester) async {
      await tester.pumpWidget(_app(const Text('Your Bag · 3')));

      final (status, body) = await _post(tester, router, '/assert_visible', {
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

        final (status, body) = await _post(tester, router, path, {
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

      final (status, body) = await _post(tester, router, '/wait_until_visible',
          {'text': 'Bag', 'match': 'fuzzy', 'timeout_ms': 5000});

      expect(status, 400);
      expect(body, {'success': false, 'error': _unknownMatch});
    });
  });
}
