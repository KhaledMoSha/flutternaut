import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'models/action_failure.dart';

/// A parsed HTTP request with typed accessors for JSON body fields.
class BridgeRequest {
  /// The raw [HttpRequest].
  final HttpRequest raw;

  /// The decoded JSON body.
  final Map<String, dynamic> body;

  /// Creates a [BridgeRequest] from a raw [HttpRequest] and its parsed JSON body.
  const BridgeRequest(this.raw, this.body);

  /// Reads a string field, or null if absent or wrong type.
  String? string(String key) {
    final v = body[key];
    return v is String ? v : null;
  }

  /// Reads a numeric field with a [defaultValue].
  double number(String key, {double defaultValue = 0}) {
    final v = body[key];
    if (v is num) return v.toDouble();
    return defaultValue;
  }

  /// Reads an int field with a [defaultValue].
  int integer(String key, {int defaultValue = 0}) {
    final v = body[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return defaultValue;
  }

  /// Reads a bool field with a [defaultValue].
  bool boolean(String key, {bool defaultValue = false}) {
    final v = body[key];
    if (v is bool) return v;
    return defaultValue;
  }

  /// Reads a nested map field, or null if absent.
  Map<String, dynamic>? map(String key) {
    final v = body[key];
    if (v is Map<String, dynamic>) return v;
    return null;
  }

  /// Whether the body contains at least one element locator (`key`, `text`
  /// or `semantics`).
  bool get hasLocator =>
      string('key') != null ||
      string('text') != null ||
      string('semantics') != null;

  /// Throws [ArgumentError] if no locator field is present.
  void requireLocator() {
    if (!hasLocator) {
      throw ArgumentError('Missing "key", "text" or "semantics" field');
    }
  }

  /// Throws [ArgumentError] if [key] is not present in the body.
  void require(String key) {
    if (body[key] == null) {
      throw ArgumentError('Missing "$key" field');
    }
  }
}

/// Handler function signature: receives a parsed request, returns JSON response data.
typedef RouteHandler = FutureOr<Map<String, dynamic>> Function(
    BridgeRequest req);

/// HTTP method enum for typed route registration.
enum RouteMethod {
  /// HTTP GET.
  get,

  /// HTTP POST.
  post,
}

/// A lightweight HTTP router with typed route registration.
///
/// Routes are stored in a [Map] keyed by `"METHOD /path"` for O(1) lookup.
/// The router handles JSON body parsing, error wrapping, and response
/// serialization so handlers only deal with business logic.
class BridgeRouter {
  final Map<String, RouteHandler> _routes = {};
  final void Function(String) _log;

  /// The app this bridge runs in (the `app` of `/health`), or null when the
  /// platform does not say ([readAppIdentity]).
  final String? app;

  /// Creates a [BridgeRouter] with an optional [log] callback, for the
  /// bridge of [app] (null when unknown).
  BridgeRouter({void Function(String)? log, this.app})
      : _log = log ?? debugPrint;

  /// The header that names an app. On a request: the app the request is
  /// meant for. On every response: the app that answered. Every bridged app
  /// on an Android device binds the same port, so when the app under test
  /// dies and another bridged app takes the port, this is what keeps that
  /// other app from executing — and passing — the test's next step.
  static const String appHeader = 'X-Flutternaut-App';

  /// The route that answers whoever asks: it is how a client finds out
  /// which app holds the port.
  static const String _healthPath = '/health';

  /// Registers a GET route at [path].
  void get(String path, RouteHandler handler) {
    _routes['GET $path'] = handler;
  }

  /// Registers a POST route at [path].
  void post(String path, RouteHandler handler) {
    _routes['POST $path'] = handler;
  }

  /// The number of registered routes.
  int get routeCount => _routes.length;

  /// Dispatches [request] to the matching handler and wraps the result in
  /// a uniform envelope.
  ///
  /// Success: `{"success": true, "data": {...handler output...}}`
  /// Failure: `{"success": false, "error": "..."}`
  ///
  /// Handlers return just the data map — the envelope is added here.
  /// This gives every endpoint a consistent response shape.
  ///
  /// A request whose [appHeader] names another app than [app] is refused
  /// with 409 before anything else — no route lookup, no body parsing, no
  /// handler — except `/health`. Every response carries [appHeader] with
  /// [app] when it is known.
  Future<void> handle(HttpRequest request) async {
    final key = '${request.method} ${request.uri.path}';
    final meantFor = _meantFor(request);
    if (meantFor != null && request.uri.path != _healthPath) {
      // Read and drop the body so the connection stays usable; nothing in
      // it is looked at.
      await request.drain<void>();
      _fail(
        request,
        'This bridge belongs to $app, but the request was meant for '
        '$meantFor: another app holds the bridge port. $meantFor is not '
        'serving it (it may have stopped or crashed); stop $app and launch '
        '$meantFor again. Nothing was run.',
        status: HttpStatus.conflict,
      );
      return;
    }

    final handler = _routes[key];

    if (handler == null) {
      _fail(request, 'Not found: $key', status: 404);
      return;
    }

    try {
      final body = await _parseBody(request);
      final data = await handler(BridgeRequest(request, body));
      _ok(request, data);
    } on ActionFailure catch (e) {
      // A gesture could not be performed safely (missing / ambiguous /
      // occluded target). Surface the descriptive reason — not a generic
      // failure — so the test engine reports what actually went wrong.
      _fail(request, e.message, status: 422);
    } on ArgumentError catch (e) {
      _fail(request, e.message.toString(), status: 400);
    } on FormatException catch (e) {
      _fail(request, 'Invalid JSON: $e', status: 400);
    } on Exception catch (e, stack) {
      _log('[FlutternautBridge] $key: $e\n$stack');
      _fail(request, e.toString(), status: 500);
    } on JsonUnsupportedObjectError catch (e, stack) {
      // The handler returned a value JSON cannot carry (a non-finite number,
      // an object with no `toJson`). The encoder's partial output ends at
      // the offending field, so the answer names it.
      final message = 'internal bridge error: the response holds a value '
          'JSON cannot encode (${e.unsupportedObject})'
          '${_encodedTail(e.partialResult)}';
      _log('[FlutternautBridge] $key: $message\n$stack');
      _fail(request, message, status: 500);
    } on Error catch (e, stack) {
      // `Error`s are not `Exception`s: a failed cast, a state error or a
      // non-object JSON body would otherwise escape, leave the request
      // unanswered and surface on the engine as a 15 s "the app is busy" —
      // indistinguishable from a blocked UI thread. Answer it with what
      // actually went wrong.
      _log('[FlutternautBridge] $key: $e\n$stack');
      _fail(request, 'internal bridge error: ${_describeError(e)}',
          status: 500);
    }
  }

  /// [error] as text that reads the same in every build mode. In a release
  /// build `FlutterError.toString()` keeps only its first summary line; its
  /// summary, description and hint entries stay readable, so they are joined.
  static String _describeError(Error error) {
    if (error is! FlutterError) return '$error';
    final parts = [
      for (final node in error.diagnostics)
        if ((node is ErrorSummary ||
                node is ErrorDescription ||
                node is ErrorHint) &&
            node is DiagnosticsProperty)
          node.valueToString(),
    ];
    return parts.isEmpty ? '$error' : parts.join(' ');
  }

  /// How many characters of the encoder's partial output an encoding
  /// failure reports — enough to show the field and the node it sits in.
  static const int _encodedTailLength = 160;

  /// The end of the JSON written before an encoding failure, phrased for an
  /// error message; empty when the encoder reported none.
  static String _encodedTail(String? partial) {
    if (partial == null || partial.isEmpty) return '';
    final tail = partial.length <= _encodedTailLength
        ? partial
        : '…${partial.substring(partial.length - _encodedTailLength)}';
    return ' after: $tail';
  }

  /// The app [request] names in [appHeader] when it is not this one, or
  /// null when it may run here: no header, an empty one, the same app
  /// (exact match after trimming), or a bridge that does not know its own
  /// app and so cannot compare.
  String? _meantFor(HttpRequest request) {
    final own = app;
    if (own == null) return null;
    final named = request.headers.value(appHeader)?.trim();
    if (named == null || named.isEmpty || named == own) return null;
    return named;
  }

  void _ok(HttpRequest request, Map<String, dynamic> data) {
    _respond(request, {'success': true, 'data': data});
  }

  void _fail(HttpRequest request, String error, {int status = 400}) {
    _respond(request, {'success': false, 'error': error}, status: status);
  }

  Future<Map<String, dynamic>> _parseBody(HttpRequest request) async {
    final content = await utf8.decoder.bind(request).join();
    if (content.isEmpty) return const {};
    return jsonDecode(content) as Map<String, dynamic>;
  }

  void _respond(HttpRequest request, Map<String, dynamic> data,
      {int status = 200}) {
    final encoded = jsonEncode(data);
    final bytes = utf8.encode(encoded);
    final own = app;
    if (own != null) request.response.headers.set(appHeader, own);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..contentLength = bytes.length
      ..add(bytes)
      ..close();
  }
}
