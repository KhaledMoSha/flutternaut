/// Flutternaut — Flutter E2E test automation bridge.
///
/// Public API:
/// - [FlutternautBridge] — starts the bridge HTTP server inside the app.
/// - [FlutternautBridgeException] — why the bridge could not start.
/// - [FlutternautView] — build-time annotation for the keys generator.
library;

export 'src/bridge/bridge_port.dart' show FlutternautBridgeException;
export 'src/bridge/flutternaut_bridge.dart' show FlutternautBridge;
export 'src/flutternaut_view.dart' show FlutternautView;
