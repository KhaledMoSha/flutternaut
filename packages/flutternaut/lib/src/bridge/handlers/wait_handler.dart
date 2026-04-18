import 'dart:async';

import 'package:flutter/scheduler.dart';

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

  Future<Map<String, dynamic>> _waitUntilVisible(BridgeRequest req) async {
    final result = await _poll(
      () => resolveVisibility(req, _walker).visible,
      timeoutMs: req.integer('timeout_ms', defaultValue: 10000),
    );
    return result.toJson();
  }

  Future<Map<String, dynamic>> _waitUntilGone(BridgeRequest req) async {
    final result = await _poll(
      () => resolveLocator(req, _walker) == null,
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

  Future<Map<String, dynamic>> _waitForIdle(BridgeRequest req) async {
    final result = await _poll(
      () => !SchedulerBinding.instance.hasScheduledFrame,
      timeoutMs: req.integer('timeout_ms', defaultValue: 10000),
      intervalMs: 50,
    );
    return result.toJson();
  }

  Future<WaitResult> _poll(
    bool Function() check, {
    int timeoutMs = 10000,
    int intervalMs = 200,
  }) async {
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < timeoutMs) {
      final met = await _runner.run(check);
      if (met) {
        return WaitResult(success: true, elapsedMs: sw.elapsedMilliseconds);
      }
      await Future<void>.delayed(Duration(milliseconds: intervalMs));
    }
    return WaitResult(success: false, elapsedMs: sw.elapsedMilliseconds);
  }
}
