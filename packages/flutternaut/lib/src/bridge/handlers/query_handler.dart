import '../engine/main_thread_runner.dart';
import '../engine/tree_walker.dart';
import '../router.dart';
import '_locator.dart';

/// Handles query endpoints: read, get_text, is_visible, is_enabled.
class QueryHandler {
  final TreeWalker _walker;
  final MainThreadRunner _runner;

  QueryHandler({required TreeWalker walker, required MainThreadRunner runner})
      : _walker = walker,
        _runner = runner;

  void register(BridgeRouter router) {
    router.post('/read', _read);
    router.post('/get_text', _getText);
    router.post('/is_visible', _isVisible);
    router.post('/is_enabled', _isEnabled);
  }

  Future<Map<String, dynamic>> _read(BridgeRequest req) async {
    return _runner.run<Map<String, dynamic>>(() {
      final info = resolveLocator(req, _walker);
      if (info == null) return {'found': false};
      return {
        'found': true,
        'text': info.text,
        'type': info.type,
        'enabled': info.enabled,
        if (info.key != null) 'key': info.key,
      };
    });
  }

  Future<Map<String, dynamic>> _getText(BridgeRequest req) async {
    return _runner.run<Map<String, dynamic>>(() {
      final info = resolveLocator(req, _walker);
      if (info == null) return {'found': false};
      return {'found': true, 'text': info.text, 'type': info.type};
    });
  }

  Future<Map<String, dynamic>> _isVisible(BridgeRequest req) async {
    return _runner.run<Map<String, dynamic>>(() {
      final result = resolveVisibility(req, _walker);
      return {
        'visible': result.visible,
        'exists': result.exists,
        'on_screen': result.onScreen,
        'obstructed': result.obstructed,
      };
    });
  }

  /// The enabled state of the control the locator names (see
  /// [TreeWalker.resolveStateTarget]): `found` with `enabled` and `control`,
  /// or `found: false` with the `reason` there is none to read.
  Future<Map<String, dynamic>> _isEnabled(BridgeRequest req) async {
    req.requireLocator();
    return _runner.run<Map<String, dynamic>>(() {
      return switch (resolveStateLocator(req, _walker)) {
        StateFound(:final enabled, :final description) => {
            'found': true,
            'enabled': enabled,
            'control': description,
          },
        StateMissing(:final reason) => {'found': false, 'reason': reason},
        final StateNotAControl notAControl => {
            'found': false,
            'reason': notAControl.reason,
          },
      };
    });
  }
}
