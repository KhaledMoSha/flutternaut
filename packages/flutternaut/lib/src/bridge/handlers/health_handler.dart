import '../engine/main_thread_runner.dart';
import '../engine/tree_walker.dart';
import '../router.dart';

/// Handles health check and tree inspection endpoints.
class HealthHandler {
  /// Bridge protocol version. Bump when the request/response shapes change
  /// so clients can detect incompatibility.
  static const String protocolVersion = '1.0.0';

  final TreeWalker _walker;
  final MainThreadRunner _runner;

  HealthHandler({required TreeWalker walker, required MainThreadRunner runner})
      : _walker = walker,
        _runner = runner;

  void register(BridgeRouter router) {
    router.get('/health', _health);
    router.get('/tree', _tree);
    router.get('/screen', _screen);
    router.get('/keyed', _keyed);
  }

  Future<Map<String, dynamic>> _health(BridgeRequest req) async {
    return {
      'status': 'ok',
      'bridge': 'flutternaut',
      'protocol_version': protocolVersion,
    };
  }

  Future<Map<String, dynamic>> _tree(BridgeRequest req) async {
    return _runner.run(() => _walker.dumpTree());
  }

  /// Only the widgets actually displayed on screen right now —
  /// framework scaffolding and off-screen branches pruned.
  Future<Map<String, dynamic>> _screen(BridgeRequest req) async {
    return _runner.run(() => _walker.dumpVisibleTree());
  }

  Future<Map<String, dynamic>> _keyed(BridgeRequest req) async {
    return _runner.run(() {
      final elements = _walker.findAllKeyed();
      return {
        'count': elements.length,
        'elements': elements.map((e) => e.toJson()).toList(),
      };
    });
  }
}
