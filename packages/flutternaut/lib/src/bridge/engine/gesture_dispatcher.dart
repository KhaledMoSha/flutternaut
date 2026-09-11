import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../models/action_failure.dart';
import '../models/element_info.dart';
import '../models/element_rect.dart';
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
  ///
  /// Throws [ActionFailure] — never silently fails — when the target is
  /// missing, ambiguous, or not visible and tappable. See [resolveActable].
  Future<bool> tap({String? key, String? text}) async {
    final center = await resolveActable(key: key, text: text);

    final session = _beginPointer(center);
    await _pumpFrames();
    await session.end(center);
    return true;
  }

  /// Taps the [nth] unlabeled interactive control (icon-only button) in
  /// the row of the unique on-screen text [anchorText] — the `near`
  /// locator, for controls that carry no key and no text of their own
  /// (e.g. a per-row trash button).
  ///
  /// Throws [ActionFailure] when the anchor is missing or ambiguous, [nth]
  /// is out of range, or the control is not actually tappable.
  Future<bool> tapNear(String anchorText, int nth) async {
    final center = await resolveNearActable(anchorText, nth);

    final session = _beginPointer(center);
    await _pumpFrames();
    await session.end(center);
    return true;
  }

  /// Long-presses the [nth] unlabeled interactive control in the row of
  /// the unique on-screen text [anchorText] (see [tapNear]).
  Future<bool> longPressNear(
    String anchorText,
    int nth, {
    Duration duration = const Duration(milliseconds: 600),
  }) async {
    final center = await resolveNearActable(anchorText, nth);

    final session = _beginPointer(center);
    await Future<void>.delayed(duration);
    await session.end(center, timeOffset: duration);
    return true;
  }

  /// Resolves the point to act on for a `near` locator: the [nth]
  /// unlabeled interactive element (left-to-right) in the row of the
  /// unique on-screen [anchorText]. Every failure is loud and explains
  /// itself; the resolved control passes the same hit-test gate as any
  /// ordinary tap target.
  Future<Offset> resolveNearActable(String anchorText, int nth) async {
    final anchors = walker.findOnScreenElementsByText(anchorText);
    if (anchors.isEmpty) {
      throw ActionFailure(
        'No on-screen text "$anchorText" to anchor near.',
      );
    }
    if (anchors.length > 1) {
      throw ActionFailure(
        'Anchor text "$anchorText" is ambiguous: ${anchors.length} on-screen '
        'matches — ${_describeCandidates(anchors)}. A near anchor must be '
        'unique on screen.',
      );
    }

    final candidates = walker.unlabeledInteractiveNear(anchors.single);
    if (candidates.isEmpty) {
      throw ActionFailure(
        'No unlabeled interactive control shares the row of "$anchorText".',
      );
    }
    if (nth < 0 || nth >= candidates.length) {
      throw ActionFailure(
        'nth $nth is out of range: ${candidates.length} unlabeled control(s) '
        'share the row of "$anchorText".',
      );
    }

    final element = candidates[nth];
    await _ensureVisible(element);
    return _confirmHittable(
      element,
      'control near "$anchorText" (nth $nth)',
    );
  }

  /// Taps a widget whose text contains [substring] (case-insensitive).
  ///
  /// Goes through the same [resolveActable] confirm pipeline as [tap], so
  /// a substring match that is occluded or off-screen fails loudly rather
  /// than reporting a false success.
  Future<bool> tapByTextContains(String substring) async {
    final center = await resolveActable(text: substring, contains: true);

    final session = _beginPointer(center);
    await _pumpFrames();
    await session.end(center);
    return true;
  }

  /// Types [input] into a text field found by [key] or [text].
  ///
  /// If [clear] is true, replaces existing content; otherwise appends.
  ///
  /// The *field* — not the locator label — is gated for visibility and
  /// tappability (see [_resolveActableField]); a label is only a means of
  /// finding the field. Throws [ActionFailure] when no editable field is
  /// associated, or it is occluded / off-screen.
  Future<bool> typeText({
    String? key,
    String? text,
    required String input,
    bool clear = false,
  }) async {
    final (focusPoint, state) = await _resolveActableField(key: key, text: text);
    await _focusField(focusPoint);

    final current = state.textEditingValue.text;
    final newText = clear ? input : current + input;
    // Drive through the real input pipeline so inputFormatters run and
    // TextField.onChanged fires (a plain `controller.value =` does not).
    state.userUpdateTextEditingValue(
      TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      ),
      SelectionChangedCause.keyboard,
    );
    return true;
  }

  /// Clears the text content of a text field found by [key] or [text].
  ///
  /// Gates the field for visibility/tappability via [_resolveActableField]
  /// so an off-screen or occluded field fails loudly rather than silently
  /// clearing nothing.
  Future<bool> clearText({String? key, String? text}) async {
    final (focusPoint, state) = await _resolveActableField(key: key, text: text);
    await _focusField(focusPoint);

    state.userUpdateTextEditingValue(
      const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      ),
      SelectionChangedCause.keyboard,
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

    await swipeAt(center, direction, distance);
    return true;
  }

  /// Swipes by [distance] in [direction] starting from [center]. Shared by
  /// the element-targeted [swipe] and the auto-resolved [swipeAuto].
  Future<void> swipeAt(Offset center, String direction, double distance) {
    return _dispatchMovement(center, _directionToDelta(direction, distance));
  }

  /// Swipes the single on-screen [Scrollable] whose axis matches
  /// [direction], for a screen-level scroll when no scroll container is
  /// specified. Throws [ActionFailure] if none or more than one match
  /// (see [resolveScrollable]).
  Future<bool> swipeAuto(String direction, double distance) async {
    final scrollable = resolveScrollable(direction);
    final center = walker.centerOfElement(scrollable);
    if (center == null) {
      throw ActionFailure(
        'The scrollable to scroll "$direction" has no on-screen geometry.',
      );
    }
    await swipeAt(center, direction, distance);
    return true;
  }

  /// Swipes the [index]-th on-screen [Scrollable] — element-tree DFS order,
  /// exactly the `scrollIndex` the `/screen` dump reports — whose axis
  /// matches [direction]. Throws [ActionFailure] when the index is out of
  /// range, so a stale recorded index fails loudly instead of scrolling the
  /// wrong container.
  Future<bool> swipeAtIndex(
    int index,
    String direction,
    double distance,
  ) async {
    final axis = _axisForDirection(direction);
    final axisName = axis == Axis.vertical ? 'vertical' : 'horizontal';
    final matches = walker.findVisibleScrollables(axis);
    if (index < 0 || index >= matches.length) {
      throw ActionFailure(
        'scrollIndex $index is out of range: ${matches.length} $axisName '
        'scrollable(s) are visible.',
      );
    }
    final center = walker.centerOfElement(matches[index]);
    if (center == null) {
      throw ActionFailure(
        'The $axisName scrollable at scrollIndex $index has no on-screen '
        'geometry.',
      );
    }
    await swipeAt(center, direction, distance);
    return true;
  }

  /// Maps a swipe [direction] to the scroll axis it moves along.
  Axis _axisForDirection(String direction) =>
      (direction == 'up' || direction == 'down')
          ? Axis.vertical
          : Axis.horizontal;

  /// Resolves the single visible [Scrollable] to scroll for [direction],
  /// or throws [ActionFailure]. Direction maps to an axis (up/down →
  /// vertical, left/right → horizontal); zero matches means there is
  /// nothing to scroll, and more than one means the choice is ambiguous —
  /// the author must pass an explicit scroll target rather than have the
  /// engine guess and scroll the wrong list.
  Element resolveScrollable(String direction) {
    final axis = _axisForDirection(direction);
    final axisName = axis == Axis.vertical ? 'vertical' : 'horizontal';

    final matches = walker.findVisibleScrollables(axis);
    if (matches.isEmpty) {
      throw ActionFailure(
        'No $axisName scrollable is visible to scroll "$direction" — pass a '
        'scroll target (the scrollable\'s key).',
      );
    }
    if (matches.length > 1) {
      throw ActionFailure(
        'Ambiguous scroll: ${matches.length} $axisName scrollables are '
        'visible — ${_describeCandidates(matches)}. Pass a scroll target '
        '(the scrollable\'s key) to disambiguate.',
      );
    }
    return matches.single;
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

  // ---------------------------------------------------------------------------
  // Pre-action confirm pipeline (tap / type) — fail loudly, never falsely
  // ---------------------------------------------------------------------------

  /// Resolves the on-screen center to act on for a `tap`/`type` target,
  /// throwing [ActionFailure] with a precise reason when the action
  /// cannot be performed safely. This is what stops the bridge from
  /// reporting success when nothing — or the wrong widget — was hit.
  ///
  /// Pipeline:
  ///   1. Resolve every element matching [key] or [text] (exact, unless
  ///      [contains] for the text-substring path).
  ///   2. Single match → scroll it into view (best-effort), settle, then
  ///      confirm it is genuinely tappable via a real hit-test.
  ///   3. Multiple matches → only those currently on-screen AND hittable
  ///      count. Exactly one wins; zero → fail (nothing visible to act
  ///      on); two or more → fail as ambiguous, listing the candidates.
  Future<Offset> resolveActable({
    String? key,
    String? text,
    bool contains = false,
  }) async {
    final desc = _describeLocator(key: key, text: text);
    final matches = _matchingElements(key: key, text: text, contains: contains);

    if (matches.isEmpty) {
      throw ActionFailure('No element found matching $desc.');
    }

    if (matches.length == 1) {
      final element = matches.single;
      await _ensureVisible(element);
      return _confirmHittable(element, desc);
    }

    // More than one element matches. Disambiguate by what is actually
    // tappable right now — duplicates that are off-screen or hidden are not
    // real conflicts. Uses the same tappability policy as the single-match
    // path (strict for interactive targets, lenient for plain labels).
    final visible = <(Element, Offset)>[];
    for (final element in matches) {
      final point = walker.reachableTapPoint(element);
      if (point != null) {
        visible.add((element, point));
      }
    }

    if (visible.isEmpty) {
      throw ActionFailure(
        '${matches.length} elements match $desc, but none are visible and '
        'tappable on screen. Scroll the target into view, or disambiguate '
        'with a ValueKey.',
      );
    }
    if (visible.length > 1) {
      final candidates = _describeCandidates([for (final v in visible) v.$1]);
      throw ActionFailure(
        'Ambiguous locator $desc: ${visible.length} matching elements are '
        'visible and tappable — $candidates. Disambiguate with a ValueKey.',
      );
    }
    return visible.single.$2;
  }

  /// Resolves the editable field for a `type`/`clear` target and confirms
  /// it is on-screen and tappable, returning the point to tap to focus it
  /// and its [EditableTextState]. Throws [ActionFailure] when the locator
  /// resolves to no editable field, or the field is occluded / off-screen.
  ///
  /// Unlike [tap], the gate is applied to the *field*, since a label
  /// locator (e.g. `InputDecoration.labelText`) is not itself the
  /// interactive target — it merely identifies the field to type into.
  Future<(Offset, EditableTextState)> _resolveActableField({
    String? key,
    String? text,
  }) async {
    final desc = _describeLocator(key: key, text: text);
    final element = key != null
        ? walker.findEditableElementByKey(key)
        : (text != null ? walker.findEditableElementByText(text) : null);
    if (element == null) {
      throw ActionFailure('No editable text field found for $desc.');
    }
    final state = walker.editableStateOf(element);
    if (state == null) {
      throw ActionFailure(
        '$desc resolved to a widget that is not an editable text field.',
      );
    }

    await _ensureVisible(element);
    return (_confirmHittable(element, desc), state);
  }

  /// Taps [point] to focus a field before driving its text value.
  Future<void> _focusField(Offset point) async {
    final session = _beginPointer(point);
    await _pumpFrames();
    await session.end(point);
    await _pumpFrames(count: 3);
  }

  /// All elements matching the given locator (every match, for ambiguity
  /// detection).
  List<Element> _matchingElements({
    String? key,
    String? text,
    bool contains = false,
  }) {
    if (key != null) return walker.findAllElementsByKey(key);
    if (text != null) {
      return contains
          ? walker.findAllElementsByTextContains(text)
          : walker.findAllElementsByText(text);
    }
    return const [];
  }

  /// Confirms the single matched [element] is tappable, returning the point
  /// to tap, or throwing [ActionFailure] explaining why it is not.
  Offset _confirmHittable(Element element, String desc) {
    final point = walker.reachableTapPoint(element);
    if (point != null) return point;

    final center = walker.centerOfElement(element);
    if (center == null) {
      throw ActionFailure(
        '$desc exists but has no on-screen geometry (not laid out).',
      );
    }
    final blocker = walker.topmostHitTypeAt(element, center);
    throw ActionFailure(
      '$desc is present at ${_fmtOffset(center)} but a tap there would '
      'reach ${blocker ?? 'nothing'} instead — it is occluded or '
      'off-screen.',
    );
  }

  /// Best-effort scroll of [target] into its enclosing [Scrollable]'s
  /// viewport. No-op when there is no scrollable ancestor or the target
  /// has no laid-out box (e.g. not yet built in a lazy list — that stays
  /// the job of `scroll_until_visible`). The hit-test gate that follows
  /// is the authority on whether the target ended up reachable.
  Future<void> _ensureVisible(Element target) async {
    final renderObject = target.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    if (Scrollable.maybeOf(target) == null) return;

    await Scrollable.ensureVisible(
      target,
      duration: Duration.zero,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
    );
    await _pumpFrames(count: 3);
  }

  String _describeLocator({String? key, String? text}) {
    if (key != null) return 'key "$key"';
    if (text != null) return 'text "$text"';
    return 'locator';
  }

  String _describeCandidates(List<Element> elements) {
    return elements.map((e) {
      final key = e.widget.key;
      final keyPart = key is ValueKey ? ' key "${key.value}"' : '';
      final label = walker.textOfElement(e);
      final labelPart = label != null ? ' "$label"' : '';
      final rect = walker.rectOfElement(e);
      final rectPart = rect != null ? ' @ ${_fmtRect(rect)}' : '';
      return '[${e.widget.runtimeType}$keyPart$labelPart$rectPart]';
    }).join(', ');
  }

  String _fmtOffset(Offset o) =>
      '(${o.dx.toStringAsFixed(1)}, ${o.dy.toStringAsFixed(1)})';

  String _fmtRect(ElementRect r) =>
      '(${r.x.toStringAsFixed(1)}, ${r.y.toStringAsFixed(1)} '
      '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)})';

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
