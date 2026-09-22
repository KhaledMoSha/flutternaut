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

  /// Taps a widget found by [key], [text] or [semantics] (accessibility
  /// label). When several visible widgets match, [nth] picks one in
  /// reading order (0-based, rows top→bottom then left→right).
  ///
  /// Throws [ActionFailure] — never silently fails — when the target is
  /// missing, ambiguous, or not visible and tappable. See [resolveActable].
  Future<bool> tap({
    String? key,
    String? text,
    String? semantics,
    int? nth,
  }) async {
    final center = await resolveActable(
      key: key,
      text: text,
      semantics: semantics,
      nth: nth,
    );

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
  Future<bool> tapByTextContains(String substring, {int? nth}) async {
    final center = await resolveActable(
      text: substring,
      contains: true,
      nth: nth,
    );

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
  /// associated, or it is occluded / off-screen. A field that already
  /// holds keyboard focus is written to without the tap-to-focus.
  Future<bool> typeText({
    String? key,
    String? text,
    required String input,
    bool clear = false,
  }) async {
    final (focusPoint, state) = await _resolveActableField(key: key, text: text);
    if (focusPoint != null) await _focusField(focusPoint);
    _writeInto(state, input, clear: clear);
    return true;
  }

  /// Types [input] into whichever text field currently holds keyboard
  /// focus — what the OS keyboard would do. This is the way into inputs
  /// the app deliberately hides from the pointer (an OTP/PIN widget keeps
  /// its real `TextField` invisible under a row of digit boxes and focuses
  /// it when a box is tapped): focus is the app's own proof that the field
  /// accepts keystrokes, so no hit-test applies. Throws [ActionFailure]
  /// when no field has focus.
  Future<bool> typeFocused(String input, {bool clear = false}) async {
    final state = walker.focusedEditableState();
    if (state == null) {
      throw ActionFailure(
        'No text field has keyboard focus — tap the field (or the control '
        'that focuses it, e.g. an OTP digit box) first, then type_focused.',
      );
    }
    _writeInto(state, input, clear: clear);
    return true;
  }

  /// Drives [input] into [state] through the real input pipeline so
  /// inputFormatters run and `TextField.onChanged` fires (a plain
  /// `controller.value =` does not). Appends unless [clear].
  void _writeInto(EditableTextState state, String input, {required bool clear}) {
    final current = state.textEditingValue.text;
    final newText = clear ? input : current + input;
    state.userUpdateTextEditingValue(
      TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  /// Clears the text content of a text field found by [key] or [text].
  ///
  /// Gates the field for visibility/tappability via [_resolveActableField]
  /// so an off-screen or occluded field fails loudly rather than silently
  /// clearing nothing.
  Future<bool> clearText({String? key, String? text}) async {
    final (focusPoint, state) = await _resolveActableField(key: key, text: text);
    if (focusPoint != null) await _focusField(focusPoint);
    _writeInto(state, '', clear: true);
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

  /// Long-presses a widget found by [key], [text] or [semantics]; [nth]
  /// disambiguates duplicates in reading order. Goes through the same
  /// confirm pipeline as [tap] — an occluded or ambiguous target throws
  /// [ActionFailure] instead of pressing the wrong pixel.
  Future<bool> longPress({
    String? key,
    String? text,
    String? semantics,
    int? nth,
    Duration duration = const Duration(milliseconds: 600),
  }) async {
    final center = await resolveActable(
      key: key,
      text: text,
      semantics: semantics,
      nth: nth,
    );

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

  /// Resolves the visible [Scrollable] to scroll for [direction], or
  /// throws [ActionFailure]. Direction maps to an axis (up/down →
  /// vertical, left/right → horizontal). Among the on-screen scrollables
  /// on that axis:
  ///
  ///  1. only those that can still move in [direction] count — a list
  ///     already at its end, or a bottom nav bar that never overflows,
  ///     is not a candidate;
  ///  2. one remaining candidate wins;
  ///  3. several: the one with the clearly largest visible area (at least
  ///     [_dominantAreaRatio]× the runner-up) is the screen's main list
  ///     and wins; otherwise the choice is genuinely ambiguous and the
  ///     author must pass a scroll target or `scrollIndex` — listed in
  ///     the error — rather than have the engine scroll the wrong list.
  ///
  /// Never scrolls a random candidate: every choice is either the only
  /// one that can move or dominant by area, and the alternative is loud.
  Element resolveScrollable(String direction) {
    final axis = _axisForDirection(direction);
    final axisName = axis == Axis.vertical ? 'vertical' : 'horizontal';

    final visible = walker.findVisibleScrollables(axis);
    if (visible.isEmpty) {
      throw ActionFailure(
        'No $axisName scrollable is visible to scroll "$direction" — pass a '
        'scroll target (the scrollable\'s key).',
      );
    }

    final movable = visible.where((e) => _canScroll(e, direction)).toList();
    if (movable.isEmpty) {
      throw ActionFailure(
        'None of the ${visible.length} visible $axisName scrollable(s) can '
        'scroll "$direction" (at the end of its content, or nothing to '
        'scroll) — ${_describeScrollables(visible, visible)}.',
      );
    }
    if (movable.length == 1) return movable.single;

    final byArea = [...movable]
      ..sort((a, b) => _visibleArea(b).compareTo(_visibleArea(a)));
    final first = _visibleArea(byArea[0]);
    final second = _visibleArea(byArea[1]);
    if (second > 0 && first >= second * _dominantAreaRatio) return byArea[0];

    throw ActionFailure(
      'Ambiguous scroll: ${movable.length} $axisName scrollables are visible '
      'and can scroll "$direction" — ${_describeScrollables(movable, visible)}. '
      'Pass a scroll target (the scrollable\'s key) or its scrollIndex to '
      'disambiguate.',
    );
  }

  /// A scrollable must be at least this many times larger (visible area)
  /// than the next candidate to be chosen as the screen's main list.
  static const double _dominantAreaRatio = 2.0;

  /// Whether the [Scrollable] element can move further in [direction] —
  /// it has content dimensions and is not already at the edge the swipe
  /// pushes it toward. Swiping "up"/"left" advances the scroll offset;
  /// "down"/"right" retreats it.
  bool _canScroll(Element scrollable, String direction) {
    final position = walker.scrollPositionOf(scrollable);
    if (position == null ||
        !position.hasPixels ||
        !position.hasContentDimensions) {
      return false;
    }
    final forward = direction == 'up' || direction == 'left';
    return forward
        ? position.pixels < position.maxScrollExtent
        : position.pixels > position.minScrollExtent;
  }

  double _visibleArea(Element element) {
    final rect = walker.rectOfElement(element);
    return rect == null ? 0 : rect.width * rect.height;
  }

  /// Describes scrollable candidates with the `scrollIndex` a caller can
  /// pass back — the index into [all], the same DFS order as the `/screen`
  /// dump — so an ambiguity error is directly actionable.
  String _describeScrollables(List<Element> shown, List<Element> all) {
    return shown.map((e) {
      final index = all.indexOf(e);
      final rect = walker.rectOfElement(e);
      final rectPart = rect != null ? ' @ ${_fmtRect(rect)}' : '';
      return '[scrollIndex $index ${e.widget.runtimeType}$rectPart]';
    }).join(', ');
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
  ///   1. Resolve every element matching [key], [text] (exact, unless
  ///      [contains] for the text-substring path) or [semantics].
  ///   2. Single match → scroll it into view (best-effort), settle, then
  ///      confirm it is genuinely tappable via a real hit-test.
  ///   3. Multiple matches → only those currently on-screen AND hittable
  ///      count, ordered in reading order. With [nth], that index wins
  ///      (out of range → fail, naming the count). Without it, exactly
  ///      one must remain; zero → fail (nothing visible to act on); two
  ///      or more → fail as ambiguous, listing the candidates with the
  ///      `nth` each one would take.
  Future<Offset> resolveActable({
    String? key,
    String? text,
    String? semantics,
    bool contains = false,
    int? nth,
  }) async {
    final desc = _describeLocator(key: key, text: text, semantics: semantics);
    final matches = _matchingElements(
      key: key,
      text: text,
      semantics: semantics,
      contains: contains,
    );

    if (matches.isEmpty) {
      throw ActionFailure('No element found matching $desc.');
    }

    if (matches.length == 1 && (nth == null || nth == 0)) {
      final element = matches.single;
      await _ensureVisible(element);
      return _confirmHittable(element, desc);
    }

    // More than one element matches. Disambiguate by what is actually
    // tappable right now — duplicates that are off-screen or hidden are not
    // real conflicts. Uses the same tappability policy as the single-match
    // path (strict for interactive targets, lenient for plain labels).
    // Reading order makes `nth` stable and identical to the numbering the
    // engine catalog shows next to duplicate labels.
    final visible = <(Element, Offset)>[];
    for (final element in walker.inReadingOrder(matches)) {
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
    if (nth != null) {
      if (nth < 0 || nth >= visible.length) {
        throw ActionFailure(
          'nth $nth is out of range for $desc: ${visible.length} matching '
          'element(s) are visible and tappable — '
          '${_describeCandidates([for (final v in visible) v.$1], numbered: true)}.',
        );
      }
      return visible[nth].$2;
    }
    if (visible.length > 1) {
      final candidates =
          _describeCandidates([for (final v in visible) v.$1], numbered: true);
      throw ActionFailure(
        'Ambiguous locator $desc: ${visible.length} matching elements are '
        'visible and tappable — $candidates. Pass nth (0-based, reading '
        'order: rows top to bottom, then left to right) or disambiguate '
        'with a ValueKey.',
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
  ///
  /// A field that already holds keyboard focus skips the gate and the
  /// focus tap (the returned point is null): the app focused it, so it
  /// accepts keystrokes wherever its pixels are — this is how a hidden
  /// OTP input, focused by tapping its visible digit box, is typed into.
  Future<(Offset?, EditableTextState)> _resolveActableField({
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
    if (state.widget.focusNode.hasFocus) return (null, state);

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
    String? semantics,
    bool contains = false,
  }) {
    if (key != null) return walker.findAllElementsByKey(key);
    if (text != null) {
      return contains
          ? walker.findAllElementsByTextContains(text)
          : walker.findAllElementsByText(text);
    }
    if (semantics != null) return walker.findAllElementsBySemantics(semantics);
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
    if (walker.pointersIgnoredAt(element, center)) {
      throw ActionFailure(
        '$desc is present at ${_fmtOffset(center)} but no widget receives '
        'pointers there right now: a route transition is in progress and '
        'Flutter ignores pointer events until it ends. Run wait_idle, then '
        'retry.',
      );
    }
    final blocker = walker.topmostHitTypeAt(element, center);
    throw ActionFailure(
      '$desc is present at ${_fmtOffset(center)} but a tap there would '
      'reach ${blocker ?? 'nothing'} instead — it is occluded or '
      'off-screen.',
    );
  }

  /// Best-effort scroll of [target] into view, the way a user could. No-op
  /// when the target has no laid-out box (e.g. not yet built in a lazy list —
  /// that stays the job of `scroll_until_visible`). The hit-test gate that
  /// follows is the authority on whether the target ended up reachable.
  ///
  /// Two rules keep this from moving the screen under the test:
  ///
  ///  * A target that is already reachable is left exactly where it is.
  ///  * Only ancestors the **user** could scroll are scrolled. An ancestor
  ///    whose physics refuse user offsets (`NeverScrollableScrollPhysics`) is
  ///    app-controlled: debug overlays such as `requests_inspector` wrap the
  ///    whole app in such a `PageView`, and `Scrollable.ensureVisible` — which
  ///    scrolls *every* ancestor so the target sits at its leading edge —
  ///    dragged the hidden overlay page into view on every tap.
  Future<void> _ensureVisible(Element target) async {
    final renderObject = target.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    if (walker.reachableTapPoint(target) != null) return;

    // Same ancestor walk as Scrollable.ensureVisible: the first scrollable
    // reveals the target, each outer one reveals the scrollable inside it.
    // Collected synchronously, so no BuildContext crosses an async gap.
    final reveals = <(ScrollPosition, RenderObject, RenderObject?)>[];
    BuildContext context = target;
    RenderObject? targetRenderObject;
    var scrollable = Scrollable.maybeOf(context);
    while (scrollable != null) {
      final position = scrollable.position;
      final object = context.findRenderObject();
      if (object != null &&
          position.physics.shouldAcceptUserOffset(position)) {
        reveals.add((position, object, targetRenderObject));
      }
      targetRenderObject ??= object;
      context = scrollable.context;
      scrollable = Scrollable.maybeOf(context);
    }

    final scrolled = reveals.isNotEmpty;
    for (final (position, object, innerTarget) in reveals) {
      await position.ensureVisible(
        object,
        duration: Duration.zero,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        targetRenderObject: innerTarget,
      );
    }
    if (scrolled) await _pumpFrames(count: 3);
  }

  String _describeLocator({String? key, String? text, String? semantics}) {
    if (key != null) return 'key "$key"';
    if (text != null) return 'text "$text"';
    if (semantics != null) return 'semantics "$semantics"';
    return 'locator';
  }

  /// Describes candidate elements; [numbered] prefixes each with the
  /// `nth` it would take, in the order given (callers pass reading order).
  String _describeCandidates(List<Element> elements, {bool numbered = false}) {
    var i = 0;
    return elements.map((e) {
      final key = TreeWalker.keyOf(e.widget);
      final keyPart = key != null ? ' key "$key"' : '';
      final label = walker.textOfElement(e);
      final labelPart = label != null ? ' "$label"' : '';
      final rect = walker.rectOfElement(e);
      final rectPart = rect != null ? ' @ ${_fmtRect(rect)}' : '';
      final nthPart = numbered ? 'nth ${i++} ' : '';
      return '[$nthPart${e.widget.runtimeType}$keyPart$labelPart$rectPart]';
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
