import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'models/element_info.dart';
import 'pointer_session.dart';
import 'tree_walker.dart';

/// Dispatches synthetic gestures through Flutter's [GestureBinding].
///
/// All gestures go through the real pointer event pipeline — the same
/// path as actual touch input. The app cannot distinguish synthetic
/// events from real user touches.
class GestureDispatcher {
  /// The tree walker used to resolve elements by key or text.
  final TreeWalker walker;

  int _nextPointer = 100;

  /// Creates a [GestureDispatcher] backed by the given [walker].
  GestureDispatcher(this.walker);

  // ---------------------------------------------------------------------------
  // Public gesture methods (all accept key OR text locators)
  // ---------------------------------------------------------------------------

  /// Taps a widget found by [key] or [text].
  Future<bool> tap({String? key, String? text}) async {
    final center = _centerOf(_resolve(key: key, text: text));
    if (center == null) return false;

    final session = _beginPointer(center);
    await _pumpFrames();
    await session.end(center);
    return true;
  }

  /// Taps a widget whose text contains [substring].
  Future<bool> tapByTextContains(String substring) async {
    final center = _centerOf(walker.findByTextContains(substring));
    if (center == null) return false;

    final session = _beginPointer(center);
    await _pumpFrames();
    await session.end(center);
    return true;
  }

  /// Types [input] into a text field found by [key] or [text].
  ///
  /// If [clear] is true, replaces existing content; otherwise appends.
  Future<bool> typeText({
    String? key,
    String? text,
    required String input,
    bool clear = false,
  }) async {
    final tapped = await tap(key: key, text: text);
    if (!tapped) return false;
    await _pumpFrames(count: 3);

    final controller =
        key != null ? _findControllerByKey(key) : _focusedController();
    if (controller == null) return false;

    if (clear) {
      controller.value = TextEditingValue(
        text: input,
        selection: TextSelection.collapsed(offset: input.length),
      );
    } else {
      controller.value = TextEditingValue(
        text: controller.text + input,
        selection: TextSelection.collapsed(
          offset: controller.text.length + input.length,
        ),
      );
    }
    return true;
  }

  /// Clears the text content of a text field found by [key] or [text].
  Future<bool> clearText({String? key, String? text}) async {
    final tapped = await tap(key: key, text: text);
    if (!tapped) return false;
    await _pumpFrames(count: 3);

    final controller =
        key != null ? _findControllerByKey(key) : _focusedController();
    if (controller == null) return false;

    controller.value = const TextEditingValue(
      text: '',
      selection: TextSelection.collapsed(offset: 0),
    );
    return true;
  }

  /// Scrolls a widget found by [key] or [text] by [dx] and [dy] pixels.
  Future<bool> scroll({
    String? key,
    String? text,
    required double dx,
    required double dy,
  }) async {
    final center = _centerOf(_resolve(key: key, text: text));
    if (center == null) return false;
    await _dispatchMovement(center, Offset(dx, dy));
    return true;
  }

  /// Long-presses a widget found by [key] or [text].
  Future<bool> longPress({
    String? key,
    String? text,
    Duration duration = const Duration(milliseconds: 600),
  }) async {
    final center = _centerOf(_resolve(key: key, text: text));
    if (center == null) return false;

    final session = _beginPointer(center);
    await Future<void>.delayed(duration);
    await session.end(center, timeOffset: duration);
    return true;
  }

  /// Taps a widget [count] times with [intervalMs] between each tap.
  Future<bool> multiTap({
    String? key,
    String? text,
    int count = 2,
    int intervalMs = 100,
  }) async {
    final center = _centerOf(_resolve(key: key, text: text));
    if (center == null) return false;

    for (var i = 0; i < count; i++) {
      final session = _beginPointer(center);
      await _pumpFrames();
      await session.end(center);
      if (i < count - 1) {
        await Future<void>.delayed(Duration(milliseconds: intervalMs));
      }
    }
    return true;
  }

  /// Swipes a widget found by [key] or [text] in the given [direction].
  Future<bool> swipe({
    String? key,
    String? text,
    required String direction,
    double distance = 300,
  }) async {
    final center = _centerOf(_resolve(key: key, text: text));
    if (center == null) return false;

    final delta = _directionToDelta(direction, distance);
    await _dispatchMovement(center, delta);
    return true;
  }

  /// Swipes between two absolute screen coordinates.
  Future<bool> swipeFromTo(Offset from, Offset to) {
    return _dispatchMovement(from, to - from).then((_) => true);
  }

  /// Drags between two absolute screen coordinates.
  ///
  /// Used for drag-and-drop between two elements (handler resolves each
  /// endpoint's center before calling this).
  Future<bool> dragFromTo(Offset from, Offset to) {
    return _dispatchMovement(from, to - from, steps: 40).then((_) => true);
  }

  /// Flings a widget with high velocity to generate scroll momentum.
  Future<bool> fling({
    String? key,
    String? text,
    required double dx,
    required double dy,
  }) async {
    final center = _centerOf(_resolve(key: key, text: text));
    if (center == null) return false;
    await _dispatchMovement(
      center,
      Offset(dx, dy),
      steps: 8,
      stepIntervalMs: 4,
      settleFrames: 10,
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // Element resolution
  // ---------------------------------------------------------------------------

  ElementInfo? _resolve({String? key, String? text}) {
    if (key != null) return walker.findByKey(key);
    if (text != null) return walker.findByText(text);
    return null;
  }

  Offset? _centerOf(ElementInfo? info) {
    if (info == null || info.rect == null) return null;
    return info.rect!.center;
  }

  /// Finds the [TextEditingController] for a text field located by [ValueKey].
  ///
  /// Walks the tree to the keyed element, then searches its children for
  /// [EditableText]. Works because the ValueKey is on the TextField itself,
  /// which is an ancestor of EditableText.
  TextEditingController? _findControllerByKey(String key) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return null;

    Element? target;
    void findTarget(Element element) {
      if (target != null) return;
      final k = element.widget.key;
      if (k is ValueKey && k.value.toString() == key) {
        target = element;
        return;
      }
      element.visitChildren(findTarget);
    }

    rootElement.visitChildren(findTarget);
    if (target == null) return null;

    TextEditingController? controller;
    void findEditable(Element element) {
      if (controller != null) return;
      if (element.widget is EditableText) {
        controller = (element.widget as EditableText).controller;
        return;
      }
      element.visitChildren(findEditable);
    }

    target!.visitChildren(findEditable);
    return controller;
  }

  /// Finds the [TextEditingController] of the currently focused text field.
  ///
  /// Used when targeting by text (e.g. tapping a label like "Email").
  /// After the tap focuses the field, [FocusManager.primaryFocus] points
  /// to a node whose context may be the [EditableText] itself, one of its
  /// descendants, or one of its ancestors. We check all three.
  TextEditingController? _focusedController() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;

    final element = context as Element;

    // 1. The focused element itself may be the EditableText.
    if (element.widget is EditableText) {
      return (element.widget as EditableText).controller;
    }

    // 2. Walk descendants.
    final fromDescendants = _findEditableControllerIn(element);
    if (fromDescendants != null) return fromDescendants;

    // 3. Walk ancestors.
    TextEditingController? fromAncestors;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is EditableText) {
        fromAncestors = (ancestor.widget as EditableText).controller;
        return false; // stop
      }
      return true;
    });
    return fromAncestors;
  }

  /// Depth-first search for the first [EditableText] in [root]'s descendants.
  TextEditingController? _findEditableControllerIn(Element root) {
    TextEditingController? controller;
    void walk(Element element) {
      if (controller != null) return;
      if (element.widget is EditableText) {
        controller = (element.widget as EditableText).controller;
        return;
      }
      element.visitChildren(walk);
    }

    root.visitChildren(walk);
    return controller;
  }

  static Offset _directionToDelta(String direction, double distance) {
    return switch (direction) {
      'up' => Offset(0, -distance),
      'down' => Offset(0, distance),
      'left' => Offset(-distance, 0),
      'right' => Offset(distance, 0),
      _ => Offset(0, -distance),
    };
  }

  // ---------------------------------------------------------------------------
  // Pointer session — eliminates duplicated lifecycle boilerplate
  // ---------------------------------------------------------------------------

  /// Begins a new pointer interaction at [position].
  ///
  /// Sends [PointerAddedEvent] + [PointerDownEvent] and returns a session
  /// that can be used to move and end the pointer.
  PointerSession _beginPointer(Offset position) {
    final pointer = _nextPointer++;
    final startTime =
        Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);

    GestureBinding.instance.handlePointerEvent(PointerAddedEvent(
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
    ));
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(
      pointer: pointer,
      position: position,
      timeStamp: startTime,
      kind: PointerDeviceKind.touch,
    ));

    return PointerSession(pointer: pointer, startTime: startTime);
  }

  /// Dispatches a movement gesture (scroll, swipe, drag, fling).
  ///
  /// All movement gestures share the same structure: begin → move N steps → end.
  /// Only the [steps], [stepIntervalMs], and [settleFrames] differ.
  Future<void> _dispatchMovement(
    Offset start,
    Offset delta, {
    int steps = 30,
    int stepIntervalMs = 8,
    int settleFrames = 5,
  }) async {
    final session = _beginPointer(start);
    await _pumpFrames();

    final stepDelta = delta / steps.toDouble();
    for (var i = 1; i <= steps; i++) {
      session.moveTo(
        start + delta * (i / steps),
        stepDelta,
        Duration(milliseconds: stepIntervalMs * i),
      );
      if (i % 3 == 0) await _pumpFrames();
    }
    await _pumpFrames();

    await session.end(start + delta,
        timeOffset: Duration(milliseconds: stepIntervalMs * (steps + 1)));
    await _pumpFrames(count: settleFrames);
  }

  Future<void> _pumpFrames({int count = 1}) async {
    for (var i = 0; i < count; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
  }
}
