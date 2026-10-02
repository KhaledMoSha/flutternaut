import 'dart:io';

import 'package:flutter/widgets.dart';

import 'bridge_port.dart';
import 'engine/gesture_dispatcher.dart';
import 'engine/main_thread_runner.dart';
import 'engine/tree_walker.dart';
import 'handlers/handlers.dart';
import 'process_environment.dart';
import 'router.dart';

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
  final InternetAddress _address;
  late final BridgeRouter _router;

  HttpServer? _server;

  /// Creates a [BridgeServer].
  ///
  /// The server owns a single [TreeWalker] that is shared between all
  /// handlers and the internally-constructed [GestureDispatcher]. This
  /// guarantees every component reads from the same tree.
  ///
  /// [runner] and [log] are optional — defaults are provided.
  /// [environment] is where `/health` reads the simulator UDID from;
  /// [address] is the interface to bind (all IPv4 interfaces by default).
  BridgeServer({
    TreeWalker? walker,
    MainThreadRunner? runner,
    void Function(String)? log,
    EnvironmentReader environment = readProcessEnvironment,
    InternetAddress? address,
  })  : _log = log ?? debugPrint,
        _address = address ?? InternetAddress.anyIPv4 {
    _router = _buildBridgeRouter(
      walker: walker ?? TreeWalker(),
      runner: runner ?? MainThreadRunner(),
      log: _log,
      environment: environment,
      boundPort: () => _server?.port,
    );
  }

  /// Whether the server is currently bound and listening.
  bool get isRunning => _server != null;

  /// The port the server is bound to; null while it is not running.
  int? get port => _server?.port;

  /// Routes one request. Exposed so tests can serve the router on a socket
  /// of their own.
  @visibleForTesting
  BridgeRouter get router => _router;

  /// Starts the server on [port].
  ///
  /// No-op if already running. A port that cannot be bound throws a
  /// [FlutternautBridgeException] saying which port, where it came from and
  /// — for the default port — the likely reason; it is logged first.
  Future<void> start(BridgePort port) async {
    if (_server != null) return;

    final HttpServer server;
    try {
      server = await HttpServer.bind(_address, port.port);
    } on SocketException catch (e) {
      final failure = FlutternautBridgeException(
        _bindFailure(port, e),
        cause: e,
      );
      _log('[FlutternautBridge] ${failure.message}');
      throw failure;
    }
    _server = server;
    _log('[FlutternautBridge] Server started on port ${server.port} '
        '(${port.origin})');
    server.listen(_router.handle);
  }

  static String _bindFailure(BridgePort port, SocketException e) {
    final reason = e.osError?.message ?? e.message;
    final base = 'FlutternautBridge could not bind port ${port.port} '
        '(${port.origin}): $reason.';
    return switch (port.source) {
      BridgePortSource.defaultPort =>
        '$base Another app is probably already serving the bridge on '
            '${port.port}: iOS simulators share the Mac\'s network stack, so '
            'only one app across all booted simulators (and the Mac itself) '
            'can hold a port. Stop the other app, or run this one through '
            'the Flutternaut engine, which gives each simulator its own '
            'port through $bridgePortVariable.',
      BridgePortSource.argument =>
        '$base Something else is listening on it; stop that process or '
            'pass a different port.',
      BridgePortSource.environment =>
        '$base Whoever set the variable must choose a port nothing else '
            'is listening on, then relaunch the app.',
    };
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
    required EnvironmentReader environment,
    required int? Function() boundPort,
  }) {
    final dispatcher = GestureDispatcher(walker);
    final router = BridgeRouter(log: log);

    HealthHandler(
      walker: walker,
      runner: runner,
      environment: environment,
      boundPort: boundPort,
    ).register(router);
    FindHandler(walker: walker, runner: runner).register(router);
    GestureHandler(gesture: dispatcher, runner: runner).register(router);
    QueryHandler(walker: walker, runner: runner).register(router);
    AssertHandler(walker: walker, runner: runner).register(router);
    WaitHandler(walker: walker, runner: runner).register(router);
    AppHandler(runner: runner).register(router);

    return router;
  }
}
