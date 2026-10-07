import '../engine/main_thread_runner.dart';
import '../engine/tree_walker.dart';
import '../models/assert_result.dart';
import '../router.dart';
import '_locator.dart';

/// Handles assertion endpoints.
///
/// All tree-access operations are scheduled on the main UI thread via
/// [MainThreadRunner] so they run after layout/paint and see a stable tree.
class AssertHandler {
  final TreeWalker _walker;
  final MainThreadRunner _runner;

  AssertHandler({required TreeWalker walker, required MainThreadRunner runner})
      : _walker = walker,
        _runner = runner;

  void register(BridgeRouter router) {
    router.post('/assert_visible', _assertVisible);
    router.post('/assert_not_visible', _assertNotVisible);
    router.post('/assert_exists', _assertExists);
    router.post('/assert_not_exists', _assertNotExists);
    router.post('/assert_text_equals', _assertTextEquals);
    router.post('/assert_text_contains', _assertTextContains);
    router.post('/assert_enabled', _assertEnabled);
    router.post('/assert_disabled', _assertDisabled);
  }

  // --- visibility assertions -----------------------------------------------

  Future<Map<String, dynamic>> _assertVisible(BridgeRequest req) async {
    req.requireLocator();
    return _runner.run(() {
      final v = resolveVisibility(req, _walker);
      return _result(
        v.visible,
        v.visible
            ? 'Element is visible'
            : 'Element is not visible: ${v.reason ?? 'no visible match'}',
      );
    });
  }

  Future<Map<String, dynamic>> _assertNotVisible(BridgeRequest req) async {
    req.requireLocator();
    return _runner.run(() {
      final passed = !resolveVisibility(req, _walker).visible;
      return _result(
        passed,
        passed ? 'Element is not visible' : 'Element is visible',
      );
    });
  }

  // --- existence assertions ------------------------------------------------

  Future<Map<String, dynamic>> _assertExists(BridgeRequest req) async {
    req.requireLocator();
    return _runner.run(() {
      final passed = resolveLocator(req, _walker) != null;
      return _result(
        passed,
        passed ? 'Element exists' : 'Element not found',
      );
    });
  }

  Future<Map<String, dynamic>> _assertNotExists(BridgeRequest req) async {
    req.requireLocator();
    return _runner.run(() {
      final passed = resolveLocator(req, _walker) == null;
      return _result(
        passed,
        passed ? 'Element does not exist' : 'Element still exists',
      );
    });
  }

  // --- text presence assertions --------------------------------------------
  //
  // Screen-wide: is any widget a person can see showing this text? Text on
  // a page hidden under a dialog, in an offstage tab or faded out does not
  // count — the same visibility rule as `/assert_visible` (protocol 1.5.0).

  Future<Map<String, dynamic>> _assertTextEquals(BridgeRequest req) async {
    req.require('text');
    final text = req.string('text')!;

    return _runner.run(() {
      final v = _walker.checkTextMatchVisible(text, TextMatch.exact);
      return _result(
        v.visible,
        v.visible
            ? 'Text "$text" is visible'
            : 'No visible widget has text "$text"'
                '${v.exists && v.reason != null ? ' (${v.reason})' : ''}',
      );
    });
  }

  Future<Map<String, dynamic>> _assertTextContains(BridgeRequest req) async {
    req.require('text');
    final text = req.string('text')!;

    return _runner.run(() {
      final v = _walker.checkTextMatchVisible(text, TextMatch.contains);
      return _result(
        v.visible,
        v.visible
            ? 'Text containing "$text" is visible'
            : 'No visible widget contains "$text"'
                '${v.exists && v.reason != null ? ' (${v.reason})' : ''}',
      );
    });
  }

  // --- state assertions ----------------------------------------------------

  Future<Map<String, dynamic>> _assertEnabled(BridgeRequest req) async {
    req.requireLocator();
    return _runner.run(() => _stateAssert(req, expectEnabled: true));
  }

  Future<Map<String, dynamic>> _assertDisabled(BridgeRequest req) async {
    req.requireLocator();
    return _runner.run(() => _stateAssert(req, expectEnabled: false));
  }

  // --- helpers -------------------------------------------------------------

  /// Asserts that the control the locator names is enabled
  /// ([expectEnabled]) or disabled — the control that owns the matched
  /// widget, so a button's label answers with the button's state (see
  /// [TreeWalkerControls.resolveStateTarget]). A locator that names no
  /// control at all fails both ways, and finally: it is neither enabled nor
  /// disabled.
  Map<String, dynamic> _stateAssert(BridgeRequest req,
      {required bool expectEnabled}) {
    return switch (resolveStateLocator(req, _walker)) {
      StateFound(:final enabled, :final description) => AssertResult(
          passed: enabled == expectEnabled,
          message: '$description is ${enabled ? 'enabled' : 'disabled'}',
          control: description,
        ).toJson(),
      StateMissing(:final reason) => _result(false, reason),
      final StateNotAControl notAControl => AssertResult(
          passed: false,
          message: notAControl.reason,
          isFinal: true,
        ).toJson(),
    };
  }

  Map<String, dynamic> _result(bool passed, String message) {
    return AssertResult(passed: passed, message: message).toJson();
  }
}
