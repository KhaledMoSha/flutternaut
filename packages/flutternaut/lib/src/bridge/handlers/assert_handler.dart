import '../main_thread_runner.dart';
import '../models/assert_result.dart';
import '../router.dart';
import '../tree_walker.dart';
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
      final passed = resolveVisibility(req, _walker).visible;
      return _result(
        passed,
        passed ? 'Element is visible' : 'Element is not visible',
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
  // These are text-existence checks, not element-specific. They search the
  // entire tree for any widget whose text matches.

  Future<Map<String, dynamic>> _assertTextEquals(BridgeRequest req) async {
    req.require('text');
    final text = req.string('text')!;

    return _runner.run(() {
      final passed = _walker.findByText(text) != null;
      return _result(
        passed,
        passed ? 'Text "$text" was found' : 'No element with text "$text"',
      );
    });
  }

  Future<Map<String, dynamic>> _assertTextContains(BridgeRequest req) async {
    req.require('text');
    final text = req.string('text')!;

    return _runner.run(() {
      final passed = _walker.findByTextContains(text) != null;
      return _result(
        passed,
        passed
            ? 'Text containing "$text" was found'
            : 'No element contains "$text"',
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

  /// Asserts the element's enabled state matches [expectEnabled].
  Map<String, dynamic> _stateAssert(BridgeRequest req,
      {required bool expectEnabled}) {
    final info = resolveLocator(req, _walker);
    if (info == null) return _result(false, 'Element not found');

    final enabled = info.enabled ?? true;
    final passed = enabled == expectEnabled;
    final stateLabel = enabled ? 'enabled' : 'disabled';
    return _result(passed, 'Element is $stateLabel');
  }

  Map<String, dynamic> _result(bool passed, String message) {
    return AssertResult(passed: passed, message: message).toJson();
  }
}
