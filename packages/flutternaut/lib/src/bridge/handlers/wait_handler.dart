import 'dart:async';

import '../engine/main_thread_runner.dart';
import '../engine/tree_walker.dart';
import '../models/wait_result.dart';
import '../router.dart';
import '_locator.dart';

/// Handles wait/poll endpoints.
class WaitHandler {
  final TreeWalker _walker;
  final MainThreadRunner _runner;

  /// Creates a [WaitHandler] that polls [walker] through [runner].
  WaitHandler({required TreeWalker walker, required MainThreadRunner runner})
      : _walker = walker,
        _runner = runner;

  /// Registers the wait-family routes on [router].
  void register(BridgeRouter router) {
    router.post('/wait_for', _waitFor);
    router.post('/wait_until_visible', _waitUntilVisible);
    router.post('/wait_until_gone', _waitUntilGone);
    router.post('/wait_for_text', _waitForText);
    router.post('/wait_for_idle', _waitForIdle);
  }

  Future<Map<String, dynamic>> _waitFor(BridgeRequest req) async {
    final result = await _poll(
      () => resolveLocator(req, _walker) != null,
      timeoutMs: req.integer('timeout_ms', defaultValue: 10000),
    );
    return result.toJson();
  }

  /// Waits until the locator is visible to a person (see
  /// [TreeWalker.checkTextVisible]); on timeout the result's `detail` says
  /// why it was not, as of the last check.
  Future<Map<String, dynamic>> _waitUntilVisible(BridgeRequest req) async {
    final result = await _pollExplained(
      () {
        final v = resolveVisibility(req, _walker);
        return (v.visible, v.reason);
      },
      timeoutMs: req.integer('timeout_ms', defaultValue: 10000),
    );
    return result.toJson();
  }

  /// Waits until no match of the locator is visible — removed from the
  /// tree, faded out, offstage, or hidden behind a dialog/sheet all count
  /// as gone, because a person no longer sees it. (Tree existence is
  /// `assert_not_exists`.)
  Future<Map<String, dynamic>> _waitUntilGone(BridgeRequest req) async {
    final result = await _pollExplained(
      () {
        final v = resolveVisibility(req, _walker);
        return (
          !v.visible,
          v.visible ? 'a match is still visible on screen' : null,
        );
      },
      timeoutMs: req.integer('timeout_ms', defaultValue: 10000),
    );
    return result.toJson();
  }

  Future<Map<String, dynamic>> _waitForText(BridgeRequest req) async {
    req.require('expected');
    final expected = req.string('expected')!;

    final result = await _poll(
      () => resolveLocator(req, _walker)?.text == expected,
      timeoutMs: req.integer('timeout_ms', defaultValue: 10000),
    );
    return result.toJson();
  }

  /// Waits until no route transition is running (see
  /// [TreeWalker.isTransitioning]) — every page push/pop, dialog, sheet and
  /// menu open/close has finished. Continuous content animations (a
  /// spinner, a Lottie loop) never end and are deliberately not waited for.
  Future<Map<String, dynamic>> _waitForIdle(BridgeRequest req) async {
    final result = await _poll(
      () => !_walker.isTransitioning,
      timeoutMs: req.integer('timeout_ms', defaultValue: 10000),
      intervalMs: 50,
    );
    return result.toJson();
  }

  /// Like [_poll], for a check that also explains a miss: the last
  /// explanation is returned as the failed result's `detail`.
  Future<WaitResult> _pollExplained(
    (bool, String?) Function() check, {
    int timeoutMs = 10000,
    int intervalMs = 200,
  }) async {
    final sw = Stopwatch()..start();
    String? detail;
    while (sw.elapsedMilliseconds < timeoutMs) {
      final notDrawing = _runner.notDrawingReason;
      if (notDrawing != null) {
        detail = notDrawing;
      } else {
        final (met, why) = await _runner.run(check);
        if (met) {
          return WaitResult(success: true, elapsedMs: sw.elapsedMilliseconds);
        }
        detail = why;
      }
      await Future<void>.delayed(Duration(milliseconds: intervalMs));
    }
    return WaitResult(
      success: false,
      elapsedMs: sw.elapsedMilliseconds,
      detail: detail,
    );
  }

  /// Polls [check] until it holds or [timeoutMs] passes. While the app
  /// draws no frames (it is in the background) the check cannot run; the
  /// wait keeps going — the app may be on its way back — and a timeout
  /// then reports that as its `detail`.
  Future<WaitResult> _poll(
    bool Function() check, {
    int timeoutMs = 10000,
    int intervalMs = 200,
  }) =>
      _pollExplained(
        () => (check(), null),
        timeoutMs: timeoutMs,
        intervalMs: intervalMs,
      );
}
