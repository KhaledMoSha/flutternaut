/// The process environment on platforms without `dart:ffi` — the web.
/// Reached only through `process_environment.dart`.
///
/// A browser page has no process environment, so no variable is ever set:
/// this answers null for every name, which is the truth rather than a
/// fallback. Nothing is hidden by it — the bridge cannot run on the web at
/// all (it is an HTTP *server*), and `FlutternautBridge.ensureInitialized`
/// still fails loudly there when `dart:io` refuses to bind a socket. This
/// file exists so that an app which also targets the web keeps compiling
/// with the package in its dependencies.
String? readProcessEnvironment(String name) => null;
