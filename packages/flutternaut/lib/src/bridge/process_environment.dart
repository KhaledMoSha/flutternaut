import 'process_environment_stub.dart'
    if (dart.library.ffi) 'process_environment_native.dart' as platform;

/// Reads one variable of the process environment: its value, or null when
/// the variable is not set. An empty string is a set variable.
///
/// This is the bridge's only door to the environment. Production code passes
/// [readProcessEnvironment]; tests pass a fake.
typedef EnvironmentReader = String? Function(String name);

/// The real process environment.
///
///  * iOS — C `getenv` through `dart:ffi` (`Platform.environment` is empty
///    in a Flutter iOS app);
///  * Android, macOS, Linux, Windows — `Platform.environment`;
///  * web — always null: there is no process environment (and no bridge
///    server) in a browser. `dart:ffi` does not exist there, which is why
///    the implementation sits behind a conditional import.
String? readProcessEnvironment(String name) =>
    platform.readProcessEnvironment(name);
