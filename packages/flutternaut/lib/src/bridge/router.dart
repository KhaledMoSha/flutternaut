import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

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

  /// Whether the body contains at least one element locator (`key` or `text`).
  bool get hasLocator => string('key') != null || string('text') != null;

  /// Throws [ArgumentError] if neither `key` nor `text` is present.
  void requireLocator() {
    if (!hasLocator) {
      throw ArgumentError('Missing "key" or "text" field');
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
typedef RouteHandler = FutureOr<Map<String, dynamic>> Function(BridgeRequest req);

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

  /// Creates a [BridgeRouter] with an optional [log] callback.
  BridgeRouter({void Function(String)? log}) : _log = log ?? debugPrint;

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
  Future<void> handle(HttpRequest request) async {
    final key = '${request.method} ${request.uri.path}';
    final handler = _routes[key];

    if (handler == null) {
      _fail(request, 'Not found: $key', status: 404);
      return;
    }

    try {
      final body = await _parseBody(request);
      final data = await handler(BridgeRequest(request, body));
      _ok(request, data);
    } on ArgumentError catch (e) {
      _fail(request, e.message.toString(), status: 400);
    } on FormatException catch (e) {
      _fail(request, 'Invalid JSON: $e', status: 400);
    } on Exception catch (e, stack) {
      _log('[FlutternautBridge] $key: $e\n$stack');
      _fail(request, e.toString(), status: 500);
    }
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

  void _respond(HttpRequest request, Map<String, dynamic> data, {int status = 200}) {
    final encoded = jsonEncode(data);
    final bytes = utf8.encode(encoded);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..contentLength = bytes.length
      ..add(bytes)
      ..close();
  }
}
