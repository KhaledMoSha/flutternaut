import 'dart:io';

import 'package:flutter/widgets.dart';

import 'gesture_dispatcher.dart';
import 'handlers/handlers.dart';
import 'main_thread_runner.dart';
import 'router.dart';
import 'tree_walker.dart';

/// HTTP server that runs inside a Flutter app and exposes the widget tree
/// and gesture dispatch to external test engines.
///
/// Binds to [InternetAddress.anyIPv4] so it's reachable from the host
/// machine (important for emulators/simulators and real device port forwarding).
///
/// The server delegates all request handling to the [BridgeRouter], which
/// dispatches to focused handler classes. The server itself only manages
/// the [HttpServer] lifecycle.
class BridgeServer {
  final void Function(String) _log;
  final BridgeRouter _router;

  HttpServer? _server;

  /// Creates a [BridgeServer].
  ///
  /// The server owns a single [TreeWalker] that is shared between all
  /// handlers and the internally-constructed [GestureDispatcher]. This
  /// guarantees every component reads from the same tree.
  ///
  /// [runner] and [log] are optional — defaults are provided.
  BridgeServer({
    TreeWalker? walker,
    MainThreadRunner? runner,
    void Function(String)? log,
  }) : _log = log ?? debugPrint,
       _router = _buildBridgeRouter(
         walker: walker ?? TreeWalker(),
         runner: runner ?? MainThreadRunner(),
         log: log ?? debugPrint,
       );

  /// Whether the server is currently bound and listening.
  bool get isRunning => _server != null;

  /// Starts the server on the given [port].
  ///
  /// No-op if already running. Rethrows any bind failure after logging.
  Future<void> start({int port = 8500}) async {
    if (_server != null) return;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _log('[FlutternautBridge] Server started on port $port');
      _server!.listen(_router.handle);
    } catch (e, stack) {
      _log('[FlutternautBridge] Failed to start on port $port: $e\n$stack');
      _server = null;
      rethrow;
    }
  }

  /// Stops the server and releases the port.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _log('[FlutternautBridge] Server stopped');
  }

  /// Builds the router and registers all handler groups.
  ///
  /// All handlers share the same [walker] and [runner] — guarantees
  /// consistent reads of the widget tree.
  static BridgeRouter _buildBridgeRouter({
    required TreeWalker walker,
    required MainThreadRunner runner,
    required void Function(String) log,
  }) {
    final dispatcher = GestureDispatcher(walker);
    final router = BridgeRouter(log: log);

    HealthHandler(walker: walker, runner: runner).register(router);
    FindHandler(walker: walker, runner: runner).register(router);
    GestureHandler(gesture: dispatcher, runner: runner).register(router);
    QueryHandler(walker: walker, runner: runner).register(router);
    AssertHandler(walker: walker, runner: runner).register(router);
    WaitHandler(walker: walker, runner: runner).register(router);
    AppHandler(runner: runner).register(router);

    return router;
  }
}
