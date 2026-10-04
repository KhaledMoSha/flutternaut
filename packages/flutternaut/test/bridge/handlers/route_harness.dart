import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
Future<(int, Map<String, dynamic>)> postRoute(
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

