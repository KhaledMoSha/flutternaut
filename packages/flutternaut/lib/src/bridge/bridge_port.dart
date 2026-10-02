import 'process_environment.dart';

/// The environment variable a test engine sets to choose the bridge port at
/// launch — on an iOS simulator with `launchctl setenv` inside that
/// simulator (`xcrun simctl spawn`), before the app is launched.
const String bridgePortVariable = 'FLUTTERNAUT_BRIDGE_PORT';

/// The environment variable an iOS simulator sets in every process it runs:
/// that simulator's UDID. Absent on a physical device and on Android.
const String simulatorUdidVariable = 'SIMULATOR_UDID';

/// The port the bridge binds when nothing chooses another.
const int defaultBridgePort = 8500;

/// Where the bridge's port came from.
enum BridgePortSource {
  /// Neither the environment nor the caller chose: [defaultBridgePort].
  defaultPort,

  /// The `port:` argument of `FlutternautBridge.ensureInitialized`.
  argument,

  /// The [bridgePortVariable] environment variable.
  environment,
}

/// The port the bridge is to bind, and who chose it.
class BridgePort {
  const BridgePort(this.port, this.source);

  final int port;
  final BridgePortSource source;

  /// The origin, worded for an error message.
  String get origin => switch (source) {
        BridgePortSource.defaultPort =>
          'the default port; neither $bridgePortVariable nor a port: '
              'argument chose another',
        BridgePortSource.argument =>
          'from the port: argument of FlutternautBridge.ensureInitialized',
        BridgePortSource.environment =>
          'from the $bridgePortVariable environment variable',
      };
}

/// The bridge could not start. [message] says which port, where it came
/// from and what to do; [cause] is the underlying failure when there is one.
class FlutternautBridgeException implements Exception {
  const FlutternautBridgeException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'FlutternautBridgeException: $message';
}

final RegExp _decimal = RegExp(r'^[0-9]+$');

/// Chooses the bridge port. Precedence, highest first:
///
///  1. [bridgePortVariable] in the environment — the engine chooses the port
///     at launch, and the app's `main()` was compiled before that;
///  2. the [argument] passed to `ensureInitialized(port:)`;
///  3. [defaultBridgePort].
///
/// A variable that is set but is not a TCP port (plain decimal digits,
/// 1–65535) throws [FlutternautBridgeException] naming the variable and its
/// value. It never falls back to the argument or the default: the engine
/// that set it would then talk to whichever app does hold the default port.
BridgePort resolveBridgePort({
  required int? argument,
  required EnvironmentReader environment,
}) {
  final raw = environment(bridgePortVariable);
  if (raw == null) {
    return argument == null
        ? const BridgePort(defaultBridgePort, BridgePortSource.defaultPort)
        : BridgePort(argument, BridgePortSource.argument);
  }
  final port = _decimal.hasMatch(raw) ? int.tryParse(raw) : null;
  if (port == null || port < 1 || port > 65535) {
    throw FlutternautBridgeException(
      'The environment variable $bridgePortVariable is set to "$raw", which '
      'is not a TCP port (expected a whole number from 1 to 65535, digits '
      'only). The bridge was not started: it does not fall back to '
      '${argument ?? defaultBridgePort}, because whoever set the variable '
      'expects the bridge on the port it names. Fix the value or unset the '
      'variable, then relaunch the app.',
    );
  }
  return BridgePort(port, BridgePortSource.environment);
}

/// The iOS simulator this process runs in ([simulatorUdidVariable]), or null
/// when the variable is absent or empty — a physical iOS device, Android,
/// desktop. Never a guess.
String? readSimulatorUdid(EnvironmentReader environment) {
  final udid = environment(simulatorUdidVariable);
  return udid == null || udid.isEmpty ? null : udid;
}
