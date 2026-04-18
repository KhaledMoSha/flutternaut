import 'package:flutter/widgets.dart';

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
class FlutternautBridge {
  FlutternautBridge._();

  static FlutternautBridge? _instance;
  BridgeServer? _server;

  /// The singleton instance. Created on first [ensureInitialized] call.
  static FlutternautBridge get instance {
    _instance ??= FlutternautBridge._();
    return _instance!;
  }

  /// Whether the bridge server is currently running.
  bool get isRunning => _server?.isRunning ?? false;

  /// Initializes and starts the bridge server.
  ///
  /// - [port] — the HTTP port to listen on (default 8500).
  /// - [enabled] — set to `false` to skip starting (no-op).
  ///
  /// Safe to call multiple times — subsequent calls are ignored if
  /// the server is already running.
  static Future<void> ensureInitialized({
    int port = 8500,
    bool enabled = true,
  }) async {
    if (!enabled) return;
    if (instance.isRunning) return;

    WidgetsFlutterBinding.ensureInitialized();

    instance._server = BridgeServer();
    await instance._server!.start(port: port);
  }

  /// Stops the bridge server and releases resources.
  static Future<void> dispose() async {
    await instance._server?.stop();
    instance._server = null;
  }
}
