import '../engine/main_thread_runner.dart';
import '../engine/tree_walker.dart';
import '../router.dart';
import '_locator.dart';

/// Handles query endpoints: read, get_text, is_visible, is_enabled,
/// is_selected.
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
    router.post('/is_selected', _isSelected);
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

  /// Whether the widget the locator names is visible to a person
  /// ([TreeWalkerVisibility] — the `/screen` dump's own rule): `visible`,
  /// `exists`, `on_screen`, `obstructed`, and — when it is not visible —
  /// `reason`, why not (`… exists but is off-screen or clipped to under
  /// 1 px`, `… is on a route hidden behind a dialog/sheet/page …`, `no
  /// widget matches …`).
  Future<Map<String, dynamic>> _isVisible(BridgeRequest req) async {
    return _runner.run<Map<String, dynamic>>(() {
      final result = resolveVisibility(req, _walker);
      final reason = result.visible ? null : result.reason;
      return {
        'visible': result.visible,
        'exists': result.exists,
        'on_screen': result.onScreen,
        'obstructed': result.obstructed,
        if (reason != null) 'reason': reason,
      };
    });
  }

  /// The enabled state of the control the locator names (see
  /// [TreeWalkerControls.resolveStateTarget]): `found` with `enabled` and
  /// `control`, or `found: false` with the `reason` there is none to read.
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

  /// The selection state of the control the locator names (the control
  /// [TreeWalkerControls.resolveStateTarget] picks, read by
  /// [TreeWalkerSelection.selectionOf]): `found` with `selected` (true /
  /// false) or `mixed: true`, and `control`; `found: false` with the
  /// `reason` — retryable when nothing matches right now, `final` when the
  /// locator names no control or a control that declares no selection.
  Future<Map<String, dynamic>> _isSelected(BridgeRequest req) async {
    req.requireLocator();
    return _runner.run<Map<String, dynamic>>(() {
      return switch (resolveStateLocator(req, _walker)) {
        StateFound(:final control, :final description) => switch (
              _walker.selectionOf(control)) {
            SelectedState(:final value) => {
                'found': true,
                'selected': value,
                'control': description,
              },
            MixedState() => {
                'found': true,
                'mixed': true,
                'control': description,
              },
            NoSelection() => {
                'found': false,
                'final': true,
                'control': description,
                'reason': _walker.notSelectableReason(control),
              },
          },
        StateMissing(:final reason) => {'found': false, 'reason': reason},
        final StateNotAControl notAControl => {
            'found': false,
            'final': true,
            'reason': notAControl.reason,
          },
      };
    });
  }
}
