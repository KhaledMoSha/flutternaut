import 'dart:ui';

import '../gesture_dispatcher.dart';
import '../main_thread_runner.dart';
import '../models/action_result.dart';
import '../router.dart';

/// Handles all gesture endpoints: tap, type, scroll, swipe, drag, fling, etc.
class GestureHandler {
  final GestureDispatcher _gesture;
  final MainThreadRunner _runner;

  /// Creates a [GestureHandler] that dispatches gestures via [gesture]
  /// and schedules tree access through [runner].
  GestureHandler({
    required GestureDispatcher gesture,
    required MainThreadRunner runner,
  })  : _gesture = gesture,
        _runner = runner;

  /// Registers the gesture-family routes on [router].
  void register(BridgeRouter router) {
    router.post('/tap', _tap);
    router.post('/tap_text', _tapText);
    router.post('/type', _type);
    router.post('/clear_text', _clearText);
    router.post('/scroll', _scroll);
    router.post('/long_press', _longPress);
    router.post('/multi_tap', _multiTap);
    router.post('/swipe', _swipe);
    router.post('/drag', _drag);
    router.post('/fling', _fling);
  }

  Future<Map<String, dynamic>> _tap(BridgeRequest req) async {
    req.requireLocator();
    final key = req.string('key');
    final text = req.string('text');
    final success = await _runner.run(() => _gesture.tap(key: key, text: text));
    return ActionResult(
      action: 'tap',
      success: success,
      extras: _locatorEcho(key, text),
    ).toJson();
  }

  Future<Map<String, dynamic>> _tapText(BridgeRequest req) async {
    req.require('text');
    final text = req.string('text')!;
    final exact = req.boolean('exact', defaultValue: true);

    final success = await _runner.run(() {
      if (exact) return _gesture.tap(text: text);
      return _gesture.tapByTextContains(text);
    });
    return ActionResult(
      action: 'tap_text',
      success: success,
      extras: {'text': text},
    ).toJson();
  }

  Future<Map<String, dynamic>> _type(BridgeRequest req) async {
    final key = req.string('key');
    final target = req.string('target');
    final input = req.string('text');
    if ((key == null && target == null) || input == null) {
      throw ArgumentError('Missing locator and "text" field');
    }

    final clear = req.boolean('clear');
    final success = await _runner.run(
      () => _gesture.typeText(
        key: key,
        text: target,
        input: input,
        clear: clear,
      ),
    );
    return ActionResult(action: 'type', success: success).toJson();
  }

  Future<Map<String, dynamic>> _clearText(BridgeRequest req) async {
    req.requireLocator();
    final success = await _runner.run(
      () => _gesture.clearText(key: req.string('key'), text: req.string('text')),
    );
    return ActionResult(action: 'clear_text', success: success).toJson();
  }

  Future<Map<String, dynamic>> _scroll(BridgeRequest req) async {
    req.requireLocator();
    final success = await _runner.run(
      () => _gesture.scroll(
        key: req.string('key'),
        text: req.string('text'),
        dx: req.number('dx'),
        dy: req.number('dy'),
      ),
    );
    return ActionResult(action: 'scroll', success: success).toJson();
  }

  Future<Map<String, dynamic>> _longPress(BridgeRequest req) async {
    req.requireLocator();
    final success = await _runner.run(
      () => _gesture.longPress(
        key: req.string('key'),
        text: req.string('text'),
        duration:
            Duration(milliseconds: req.integer('duration_ms', defaultValue: 600)),
      ),
    );
    return ActionResult(action: 'long_press', success: success).toJson();
  }

  Future<Map<String, dynamic>> _multiTap(BridgeRequest req) async {
    req.requireLocator();
    final count = req.integer('count', defaultValue: 2);
    final success = await _runner.run(
      () => _gesture.multiTap(
        key: req.string('key'),
        text: req.string('text'),
        count: count,
        intervalMs: req.integer('interval_ms', defaultValue: 100),
      ),
    );
    return ActionResult(
      action: 'multi_tap',
      success: success,
      extras: {'count': count},
    ).toJson();
  }

  Future<Map<String, dynamic>> _swipe(BridgeRequest req) async {
    // Mode 1: element + direction
    final direction = req.string('direction');
    if (req.hasLocator && direction != null) {
      final success = await _runner.run(
        () => _gesture.swipe(
          key: req.string('key'),
          text: req.string('text'),
          direction: direction,
          distance: req.number('distance', defaultValue: 300),
        ),
      );
      return ActionResult(
        action: 'swipe',
        success: success,
        extras: {'direction': direction},
      ).toJson();
    }

    // Mode 2: absolute coordinates
    final fromTo = _readFromTo(req);
    if (fromTo != null) {
      await _gesture.swipeFromTo(fromTo.$1, fromTo.$2);
      return const ActionResult(action: 'swipe', success: true).toJson();
    }

    throw ArgumentError('Need ("key" or "text")+"direction" or "from"+"to"');
  }

  /// Drags from one element to another. Both endpoints are locators
  /// (`{key}` or `{text}`). Elements are resolved inside the bridge,
  /// and the drag goes from source center to destination center.
  ///
  /// Body shape:
  ///   `{"from": {"key": "card"}, "to": {"key": "zone"}}`
  ///   `{"from": {"text": "Item A"}, "to": {"text": "Trash"}}`
  ///   Mixed key/text is allowed.
  Future<Map<String, dynamic>> _drag(BridgeRequest req) async {
    final from = req.map('from');
    final to = req.map('to');
    if (from == null || to == null) {
      throw ArgumentError('Missing "from" or "to" field');
    }

    final success = await _runner.run(() async {
      final fromCenter = _resolveEndpoint(from);
      final toCenter = _resolveEndpoint(to);
      if (fromCenter == null || toCenter == null) return false;
      await _gesture.dragFromTo(fromCenter, toCenter);
      return true;
    });

    return ActionResult(action: 'drag', success: success).toJson();
  }

  Future<Map<String, dynamic>> _fling(BridgeRequest req) async {
    req.requireLocator();
    final success = await _runner.run(
      () => _gesture.fling(
        key: req.string('key'),
        text: req.string('text'),
        dx: req.number('dx'),
        dy: req.number('dy'),
      ),
    );
    return ActionResult(action: 'fling', success: success).toJson();
  }

  // --- helpers -------------------------------------------------------------

  /// Resolves a locator endpoint (`{key}` or `{text}`) to a screen center.
  /// Returns null if the element can't be found or has no rect.
  Offset? _resolveEndpoint(Map<String, dynamic> endpoint) {
    final key = endpoint['key'] as String?;
    final text = endpoint['text'] as String?;
    final info = key != null
        ? _gesture.walker.findByKey(key)
        : (text != null ? _gesture.walker.findByText(text) : null);
    return info?.rect?.center;
  }

  /// Returns `{key: ..., text: ...}` map echoing back the locator, or null.
  Map<String, dynamic>? _locatorEcho(String? key, String? text) {
    if (key == null && text == null) return null;
    return {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
    };
  }

  /// Parses `from`/`to` coordinate maps if present, returns null otherwise.
  (Offset, Offset)? _readFromTo(BridgeRequest req) {
    final from = req.map('from');
    final to = req.map('to');
    if (from == null || to == null) return null;
    return (
      Offset((from['x'] as num).toDouble(), (from['y'] as num).toDouble()),
      Offset((to['x'] as num).toDouble(), (to['y'] as num).toDouble()),
    );
  }
}
