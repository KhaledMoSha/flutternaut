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
/// In production builds, pass `enabled: false` to skip starting the server:
///
/// ```dart
/// FlutternautBridge.ensureInitialized(enabled: !kReleaseMode);
/// ```
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

  /// Initializes and starts the bridge server.
  ///
  /// - [port] — the HTTP port to listen on (default [defaultPort], 8500).
  /// - [enabled] — set to `false` to skip starting (no-op).
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
  /// - The port cannot be bound (something else is listening on it). The
  ///   message names the port and where it came from.
  ///
  /// Safe to call multiple times — subsequent calls are ignored if
  /// the server is already running.
  static Future<void> ensureInitialized({
    int? port,
    bool enabled = true,
  }) =>
      start(port: port, enabled: enabled, environment: readProcessEnvironment);

  /// [ensureInitialized] with the process environment passed in, so tests
  /// can supply a fake one.
  @visibleForTesting
  static Future<void> start({
    required EnvironmentReader environment,
    int? port,
    bool enabled = true,
  }) async {
    if (!enabled) return;
    if (instance.isRunning) return;

    final chosen = resolveBridgePort(argument: port, environment: environment);

    WidgetsFlutterBinding.ensureInitialized();

    final server = BridgeServer(environment: environment);
    await server.start(chosen);
    instance._server = server;
  }

  /// Stops the bridge server and releases resources.
  static Future<void> dispose() async {
    await instance._server?.stop();
    instance._server = null;
  }
}
