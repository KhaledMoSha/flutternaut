import 'dart:io';

import 'package:flutter/widgets.dart';

import 'bridge_port.dart';
import 'process_environment.dart';
import 'server.dart';

/// The Flutternaut bridge server — enables external test engines to
/// interact with the Flutter widget tree directly.
///
/// Call [ensureInitialized] in your app's `main()` before [runApp]:
///
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   FlutternautBridge.ensureInitialized();
///   runApp(const MyApp());
/// }
/// ```
///
/// The bridge starts an HTTP server inside the app that exposes endpoints
/// for finding widgets, dispatching gestures, checking assertions, and more.
/// The Flutternaut test engine connects to this server to drive tests.
///
/// The bridge works in debug, profile and release builds. It gives full
/// control of the app to whoever can reach it, so remove the call (or pass
/// `enabled: false`) in a build you publish to a store. It listens on the
/// device's loopback only unless you pass [ensureInitialized]'s
/// `bindAddress`.
///
/// On Android, a release build needs the `INTERNET` permission in
/// `android/app/src/main/AndroidManifest.xml` — Flutter adds it only to the
/// debug and profile manifests, and without it the bridge cannot open its
/// socket.
///
/// The bridge listens on port 8500 unless the Flutternaut engine chooses
/// another at launch through the `FLUTTERNAUT_BRIDGE_PORT` environment
/// variable (it does so to run several iOS simulators side by side). That
/// needs nothing from the app: the call above stays as it is.
class FlutternautBridge {
  FlutternautBridge._();

  /// The port the bridge listens on when neither the
  /// `FLUTTERNAUT_BRIDGE_PORT` environment variable nor the `port:`
  /// argument chooses another.
  static const int defaultPort = defaultBridgePort;

  static FlutternautBridge? _instance;
  BridgeServer? _server;

  /// The singleton instance. Created on first [ensureInitialized] call.
  static FlutternautBridge get instance => _instance ??= FlutternautBridge._();

  /// Whether the bridge server is currently running.
  bool get isRunning => _server?.isRunning ?? false;

  /// The port the bridge server is bound to; null while it is not running.
  int? get port => _server?.port;

  /// The interface the bridge listens on (IPv4 loopback unless
  /// [ensureInitialized] was given a `bindAddress`); null while it is not
  /// running.
  InternetAddress? get address => _server?.address;

  /// Initializes and starts the bridge server.
  ///
  /// - [port] — the HTTP port to listen on (default [defaultPort], 8500).
  /// - [enabled] — set to `false` to skip starting (no-op).
  /// - [bindAddress] — the interface to listen on. Default: IPv4 loopback,
  ///   which is what `adb forward`, iOS simulators and `iproxy` reach. Pass
  ///   `InternetAddress.anyIPv4` only to drive a device over its network
  ///   (Wi-Fi): anyone on that network can then control the app.
  ///
  /// **Port precedence.** The `FLUTTERNAUT_BRIDGE_PORT` environment variable
  /// wins over [port], which wins over the default. The Flutternaut engine
  /// sets the variable when it launches the app (on iOS simulators, which
  /// share the Mac's ports, each simulator gets its own), and your `main()`
  /// was compiled long before that — so the environment has the last word.
  /// You do not need to read the variable or change this call.
  ///
  /// **Failures are loud.** Both throw a [FlutternautBridgeException] and
  /// leave the bridge stopped:
  ///
  /// - `FLUTTERNAUT_BRIDGE_PORT` is set but is not a TCP port (digits only,
  ///   1–65535). The bridge never falls back to [port] or 8500 in that
  ///   case — the engine would be driving a different app.
  /// - The port cannot be bound (something else is listening on it, or —
  ///   an Android release build without the `INTERNET` permission — the
  ///   app may not open sockets). The message names the port, where it came
  ///   from and the likely cause.
  ///
  /// Safe to call multiple times — subsequent calls are ignored if
  /// the server is already running.
  static Future<void> ensureInitialized({
    int? port,
    bool enabled = true,
    InternetAddress? bindAddress,
  }) =>
      start(
        port: port,
        enabled: enabled,
        bindAddress: bindAddress,
        environment: readProcessEnvironment,
      );

  /// [ensureInitialized] with the process environment passed in, so tests
  /// can supply a fake one.
  @visibleForTesting
  static Future<void> start({
    required EnvironmentReader environment,
    int? port,
    bool enabled = true,
    InternetAddress? bindAddress,
  }) async {
    if (!enabled) return;
    if (instance.isRunning) return;

    final chosen = resolveBridgePort(argument: port, environment: environment);

    WidgetsFlutterBinding.ensureInitialized();

    final server = BridgeServer(environment: environment, address: bindAddress);
    await server.start(chosen);
    instance._server = server;
  }

  /// Stops the bridge server and releases resources.
  static Future<void> dispose() async {
    await instance._server?.stop();
    instance._server = null;
  }
}
