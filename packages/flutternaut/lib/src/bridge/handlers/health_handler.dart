import 'dart:math';

import 'package:flutter/widgets.dart';

import '../app_identity.dart';
import '../engine/main_thread_runner.dart';
import '../engine/tree_walker.dart';
import '../router.dart';

/// Handles health check and tree inspection endpoints.
class HealthHandler {
  /// Bridge protocol version. Bump when the request/response shapes change
  /// so clients can detect incompatibility.
  static const String protocolVersion = '1.1.0';

  final TreeWalker _walker;
  final MainThreadRunner _runner;

  /// Random per bridge start. A client that saw one instance answer the
  /// port before launching an app, and sees the same instance after, knows
  /// the new app never bound the port — an older app still holds it.
  final String _instanceId = _randomId();

  /// Which app this bridge runs in (see [readAppIdentity]).
  final String? _app = readAppIdentity();

  HealthHandler({required TreeWalker walker, required MainThreadRunner runner})
      : _walker = walker,
        _runner = runner;

  static String _randomId() {
    final rnd = Random.secure();
    return List.generate(
        8, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

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
      'instance_id': _instanceId,
      if (_app != null) 'app': _app,
      // False until the app has put its first frame on screen: a screen
      // read before then is empty (or a splash), not the app.
      'first_frame': WidgetsBinding.instance.firstFrameRasterized,
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
