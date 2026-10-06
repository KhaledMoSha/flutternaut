import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app_identity.dart';
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
/// Binds to [InternetAddress.loopbackIPv4] by default: the engine reaches it
/// through `adb forward` (Android emulators and devices), the Mac's own
/// loopback (iOS simulators share it) or usbmux/`iproxy` (iPhones) — all of
/// which arrive on the device's loopback. Nothing on the device's network
/// can reach it, which matters because the bridge serves unauthenticated
/// control of the app in any build mode. Pass `address:
/// InternetAddress.anyIPv4` to drive a device over Wi-Fi instead.
///
/// The server delegates all request handling to the [BridgeRouter], which
/// dispatches to focused handler classes. The server itself only manages
/// the [HttpServer] lifecycle.
class BridgeServer {
  final void Function(String) _log;
  final InternetAddress _address;
  final EnvironmentReader _environment;
  late final BridgeRouter _router;

  HttpServer? _server;

  /// Creates a [BridgeServer].
  ///
  /// The server owns a single [TreeWalker] that is shared between all
  /// handlers and the internally-constructed [GestureDispatcher]. This
  /// guarantees every component reads from the same tree.
  ///
  /// [runner] and [log] are optional — defaults are provided.
  /// [environment] is where `/health` reads the simulator UDID from (and
  /// a failed bind, to tell a simulator from a device);
  /// [address] is the interface to bind (IPv4 loopback by default);
  /// [appIdentity] reads the app this bridge runs in, once (tests pass a
  /// fixed one: under `flutter test` the platform names no app).
  BridgeServer({
    TreeWalker? walker,
    MainThreadRunner? runner,
    void Function(String)? log,
    EnvironmentReader environment = readProcessEnvironment,
    InternetAddress? address,
    @visibleForTesting String? Function() appIdentity = readAppIdentity,
  })  : _log = log ?? debugPrint,
        _address = address ?? InternetAddress.loopbackIPv4,
        _environment = environment {
    _router = _buildBridgeRouter(
      walker: walker ?? TreeWalker(),
      runner: runner ?? MainThreadRunner(),
      log: _log,
      environment: environment,
      boundPort: () => _server?.port,
      app: appIdentity(),
    );
  }

  /// Whether the server is currently bound and listening.
  bool get isRunning => _server != null;

  /// The port the server is bound to; null while it is not running.
  int? get port => _server?.port;

  /// The interface the server listens on; null while it is not running.
  InternetAddress? get address => _server?.address;

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
        _bindFailure(port, e, host: BridgeHost.detect(_environment)),
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

  @visibleForTesting
  static String bindFailure(
    BridgePort port,
    SocketException e, {
    required BridgeHost host,
  }) =>
      _bindFailure(port, e, host: host);

  static String _bindFailure(
    BridgePort port,
    SocketException e, {
    required BridgeHost host,
  }) {
    final reason = e.osError?.message ?? e.message;
    final base = 'FlutternautBridge could not bind port ${port.port} '
        '(${port.origin}): $reason.';
    // EACCES / EPERM: the process may not open sockets at all. On Android
    // that is a missing INTERNET permission — Flutter adds it only to the
    // debug and profile manifests, so a release build needs it declared in
    // the main one.
    final code = e.osError?.errorCode;
    if (code == _eacces || code == _eperm) {
      return '$base The app is not allowed to open a network socket. On '
          'Android, a release build needs '
          '<uses-permission android:name="android.permission.INTERNET"/> in '
          'android/app/src/main/AndroidManifest.xml (Flutter adds it only to '
          'the debug and profile manifests).';
    }
    return switch (port.source) {
      BridgePortSource.defaultPort => '$base ${_takenDefault(port.port, host)}',
      BridgePortSource.argument =>
        '$base Something else is listening on it; stop that process or '
            'pass a different port.',
      BridgePortSource.environment =>
        '$base Whoever set the variable must choose a port nothing else '
            'is listening on, then relaunch the app.',
    };
  }

  /// Who most likely holds the default [port] on [host], and what to do.
  /// On a device every app built with the bridge binds the same port, so
  /// the usual cause is a second bridged app; a simulator shares the Mac's
  /// ports with every booted simulator and the Mac itself.
  static String _takenDefault(int port, BridgeHost host) => switch (host) {
        BridgeHost.device =>
          'Another app with the Flutternaut bridge is probably already '
              'running on this device and holds port $port: every app built '
              'with the bridge listens on port $port unless it chooses '
              'another, and only one app on a device can listen on a port. '
              'Stop the other app (close it or force-stop it), or give this '
              'build a port of its own with '
              'FlutternautBridge.ensureInitialized(port: …) and set '
              '`bridge_port` to the same number in the Flutternaut engine '
              'config.',
        BridgeHost.iosSimulator =>
          'Another app is probably already serving the bridge on $port: iOS '
              'simulators share the Mac\'s network stack, so only one app '
              'across all booted simulators (and the Mac itself) can hold a '
              'port. Stop the other app, or run this one through the '
              'Flutternaut engine, which gives each simulator its own port '
              'through $bridgePortVariable.',
        BridgeHost.mac =>
          'Another app on this Mac is probably already serving the bridge on '
              '$port — a macOS app, or an app in a booted simulator (iOS '
              'simulators share the Mac\'s network stack). Stop the other '
              'app, or give this one another port with $bridgePortVariable '
              'or FlutternautBridge.ensureInitialized(port: …).',
        BridgeHost.computer =>
          'Another app on this computer is probably already serving the '
              'bridge on $port. Stop the other app, or give this one another '
              'port with $bridgePortVariable or '
              'FlutternautBridge.ensureInitialized(port: …).',
      };

  /// errno values for "permission denied" (Linux/Android, macOS/iOS).
  static const int _eacces = 13;
  static const int _eperm = 1;

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
    required String? app,
  }) {
    final dispatcher = GestureDispatcher(walker);
    // One reading of the app's identity: `/health` reports it, and the
    // router compares requests with it and names it on every response.
    final router = BridgeRouter(log: log, app: app);

    HealthHandler(
      walker: walker,
      runner: runner,
      environment: environment,
      boundPort: boundPort,
      app: app,
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
