part of '../tree_walker.dart';

// ---------------------------------------------------------------------------
// Control state (enabled / disabled)
// ---------------------------------------------------------------------------
//
// One rule answers "is this control enabled?" for the `/screen` dump (the
// catalog's `(disabled)`), the `near` shell check and the state assertions,
// so a catalog line and an `expect_disabled` on it can never disagree.

/// Minimum intersection-over-union for two matches to be layers of one
/// control (see [_sameStackedControl]).
const double _stackedOverlap = 0.5;

/// How far up [_controlOf] looks: a label sits a handful of elements below
/// the InkWell / GestureDetector of the control it names.
const int _controlHops = 12;

/// How far up [stateOwner] follows a label run: a Material button's label
/// sits a dozen or more elements below the button widget itself.
const int _stateRunHops = 40;

/// How deep [_wrappedControl] follows a single-child chain.
const int _wrapperChainDepth = 32;

/// Controls: which control owns a widget, its enabled state, and the state
/// assertion target.
extension TreeWalkerControls on TreeWalker {
  /// Whether [a] and [b] are two layers of the same on-screen control: they
  /// share their nearest interactive ancestor ([_controlOf]) AND occupy
  /// essentially the same pixels (intersection over union ≥
  /// [_stackedOverlap]). Both conditions are required — two separate
  /// labels under one page-wide GestureDetector are never merged, and two
  /// overlapping widgets of different controls are never merged.
  bool _sameStackedControl(Element a, Element b) {
    final control = _controlOf(a);
    if (control == null || !identical(control, _controlOf(b))) return false;
    final ra = _rectOf(a);
    final rb = _rectOf(b);
    if (ra == null || rb == null) return false;
    final x1 = ra.x > rb.x ? ra.x : rb.x;
    final y1 = ra.y > rb.y ? ra.y : rb.y;
    final x2 = (ra.x + ra.width) < (rb.x + rb.width)
        ? ra.x + ra.width
        : rb.x + rb.width;
    final y2 = (ra.y + ra.height) < (rb.y + rb.height)
        ? ra.y + ra.height
        : rb.y + rb.height;
    if (x2 <= x1 || y2 <= y1) return false;
    final inter = (x2 - x1) * (y2 - y1);
    final union = ra.width * ra.height + rb.width * rb.height - inter;
    return union > 0 && inter / union >= _stackedOverlap;
  }

  /// The nearest interactive ancestor-or-self of [element] — the control a
  /// tap on it triggers — within [_controlHops] levels, or null.
  Element? _controlOf(Element element) {
    if (_isControl(element.widget)) return element;
    Element? found;
    var hops = 0;
    element.visitAncestorElements((ancestor) {
      if (_isControl(ancestor.widget)) {
        found = ancestor;
        return false;
      }
      hops++;
      return hops < _controlHops;
    });
    return found;
  }

  bool _isControl(Widget widget) =>
      widget is GestureDetector ||
      widget is InkResponse ||
      widget is EditableText ||
      _extractEnabled(widget) != null ||
      widget.runtimeType.toString().endsWith('Button');

  /// Whether [element] is itself an interactive widget — one a user taps to
  /// trigger behavior, as opposed to a plain label used only to locate.
  bool _isInteractiveWidget(Widget widget) {
    if (widget is GestureDetector ||
        widget is InkWell ||
        widget is EditableText) {
      return true;
    }
    if (_extractEnabled(widget) != null) return true;
    return widget.runtimeType.toString().endsWith('Button');
  }

  /// The enabled state a control widget declares itself, following
  /// Flutter's own definition (`ButtonStyleButton.enabled`: `onPressed` or
  /// `onLongPress` set). Null for a widget that is not one of these controls.
  ///
  /// A `ListTile` with no callbacks at all is not a control (a static info
  /// row): null, not disabled. The `*ListTile` variants (switch, checkbox,
  /// radio) are answered by the `ListTile` they build, which carries their
  /// real state — a `RadioListTile` under a `RadioGroup` has no `onChanged`
  /// of its own.
  bool? _ownState(Widget w) {
    if (w is ButtonStyleButton) return w.enabled;
    if (w is MaterialButton) return w.enabled;
    if (w is CupertinoButton) return w.enabled;
    if (w is IconButton) return w.onPressed != null;
    if (w is FloatingActionButton) return w.onPressed != null;
    if (w is TextField) return w.enabled ?? true;
    if (w is CupertinoTextField) return w.enabled;
    if (w is Switch) return w.onChanged != null;
    if (w is Checkbox) return w.onChanged != null;
    if (w is CupertinoSwitch) return w.onChanged != null;
    if (w is Slider) return w.onChanged != null;
    if (w is CupertinoSlider) return w.onChanged != null;
    if (w is DropdownButton) return w.onChanged != null;
    if (w is PopupMenuButton) return w.enabled;
    if (w is ListTile) {
      if (!w.enabled) return false;
      return (w.onTap ?? w.onLongPress) != null ? true : null;
    }
    return null;
  }

  /// Whether [w] is a custom button — its type name ends in `Button` but it
  /// is none of the controls [_ownState] knows. Its state lives on the
  /// inner `InkWell`/`GestureDetector` it builds, where a nulled `onTap` is
  /// the disabled signal (a `PrimaryCButton` dims and sets `onTap: null`).
  bool _isNamedButton(Widget w) =>
      _ownState(w) == null && w.runtimeType.toString().endsWith('Button');

  /// The tap state of a generic tap surface (`InkWell`/`InkResponse`,
  /// `GestureDetector`): enabled when it has a tap-like callback; disabled
  /// when it has no callback at all — the way a custom control built on a
  /// bare detector disables itself (`onTap: enabled ? submit : null`). A
  /// detector that only handles drags or scales is not a tap control: null.
  bool? _genericTapState(Widget w) {
    if (w is InkResponse) {
      final taps = w.onTap != null ||
          w.onDoubleTap != null ||
          w.onLongPress != null ||
          w.onTapDown != null ||
          w.onTapUp != null ||
          w.onSecondaryTap != null;
      return taps;
    }
    if (w is GestureDetector) {
      final taps = w.onTap != null ||
          w.onDoubleTap != null ||
          w.onLongPress != null ||
          w.onTapDown != null ||
          w.onTapUp != null ||
          w.onSecondaryTap != null ||
          w.onLongPressStart != null;
      if (taps) return true;
      final drags = w.onVerticalDragStart != null ||
          w.onVerticalDragUpdate != null ||
          w.onHorizontalDragStart != null ||
          w.onHorizontalDragUpdate != null ||
          w.onPanStart != null ||
          w.onPanUpdate != null ||
          w.onScaleStart != null ||
          w.onScaleUpdate != null;
      return drags ? null : false;
    }
    return null;
  }

  /// Whether [w] is a `ListTile` that is not a control: enabled, with no
  /// `onTap`/`onLongPress` — a static info row. The `InkWell` it builds has
  /// no callbacks either, which must not read as a disabled control.
  bool _isInertListTile(Widget w) =>
      w is ListTile && w.enabled && w.onTap == null && w.onLongPress == null;

  /// A custom button's state: whether the first `InkWell`/`GestureDetector`
  /// it builds has an `onTap`. Null when it builds none.
  bool? _namedButtonState(Element element) {
    bool? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      if (w is InkResponse) {
        found = w.onTap != null;
        return;
      }
      if (w is GestureDetector) {
        found = w.onTap != null;
        return;
      }
      e.visitChildren(visit);
    }

    element.visitChildren(visit);
    return found;
  }

  /// The enabled state [element] carries as a control of its own — a known
  /// control ([_ownState]), a custom `*Button` ([_namedButtonState]), or a
  /// tap surface ([_genericTapState]) — or null when it is not one.
  bool? _elementState(Element element) {
    final own = _ownState(element.widget);
    if (own != null) return own;
    if (_isNamedButton(element.widget)) return _namedButtonState(element);
    return _genericTapState(element.widget);
  }

  /// Whether [element] is a specific control: one whose state is its own
  /// declaration (a Material/Cupertino control, a custom `*Button`), as
  /// opposed to a generic tap surface that only says it reacts.
  bool _isSpecificControl(Element element) =>
      _ownState(element.widget) != null ||
      (_isNamedButton(element.widget) && _namedButtonState(element) != null);

  /// The control whose enabled state answers for [element] — the one the
  /// `/screen` dump attaches `enabled` to — or null when [element] is not
  /// part of any control. [labelOf] reads the label that ties a label run
  /// together (visible text, or the accessibility label for a `semantics`
  /// locator).
  ///
  ///  1. [element] itself when it is a specific control.
  ///  2. Otherwise its **label run**: the ancestors that present the same
  ///     label — a button's `Text`, its inner `GestureDetector`, its
  ///     `InkWell`, the button — exactly the echoes the dump folds into one
  ///     node. The first specific control in the run wins (the
  ///     `FilledButton`, the `ListTile`); without one, the innermost tap
  ///     surface — unless the run belongs to a static `ListTile` (no
  ///     `onTap`), which is no control. The run ends at an ancestor with a
  ///     different label (a
  ///     caption is not owned by the page-wide detector around it, unless it
  ///     is that detector's own label), at a scroll view or a route. A label
  ///     inside a text field belongs to the field.
  ///  3. With [descend], when nothing above owns it: the control [element]
  ///     wraps through a single chain of children (a key on the `Padding`
  ///     around a button, a `Tooltip` around one). A wrapper whose subtree
  ///     branches before reaching a control (a `Dismissible` row) owns none.
  Element? stateOwner(
    Element element, {
    required String? Function(Element) labelOf,
    bool descend = false,
  }) {
    if (_isSpecificControl(element)) return element;
    Element? generic =
        _genericTapState(element.widget) != null ? element : null;

    final label = labelOf(element);
    Element? specific;
    var inert = false;
    if (label != null) {
      var hops = 0;
      element.visitAncestorElements((a) {
        final w = a.widget;
        if (w is Scrollable || _routeOfScope(a) != null) return false;
        if (w is TextField || w is CupertinoTextField) {
          specific = a;
          return false;
        }
        if (++hops > _stateRunHops) return false;
        if (_isInertListTile(w)) {
          inert = true;
          return false;
        }
        final isSpecific = _isSpecificControl(a);
        final surface = _genericTapState(w) != null;
        if (!isSpecific && !surface && !_isMeaningful(a)) return true;
        if (labelOf(a) != label) return false;
        if (isSpecific) {
          specific = a;
          return false;
        }
        if (surface) generic ??= a;
        return true;
      });
    }
    if (specific != null) return specific;
    // A static ListTile's row: its InkWell's empty callbacks are not a
    // disabled control.
    if (inert) return null;
    if (generic != null) return generic;
    return descend ? _wrappedControl(element) : null;
  }

  /// The control [element] wraps through a single chain of children — the
  /// first specific control on the chain, else its first tap surface — or
  /// null when the subtree branches first.
  Element? _wrappedControl(Element element) {
    Element? generic;
    var current = element;
    for (var depth = 0; depth < _wrapperChainDepth; depth++) {
      final children = <Element>[];
      current.visitChildren(children.add);
      if (children.length != 1) break;
      current = children.single;
      // A static ListTile is no control, and nor is the InkWell it builds.
      if (_isInertListTile(current.widget)) return null;
      if (_isSpecificControl(current)) return current;
      if (_genericTapState(current.widget) != null) generic ??= current;
    }
    return generic;
  }

  /// The label that ties a **text** label run together: the element's own
  /// text, or — for a control or other meaningful widget — the first text
  /// it shows (what the dump labels its node with). Normalized like every
  /// text match.
  String? textRunLabel(Element element) {
    final own = _widgetOwnText(element.widget);
    if (own != null) return TreeWalker.normalizeText(own);
    final w = element.widget;
    if (_elementState(element) != null || _isButtonLike(w) || w is ListTile) {
      final text = extractText(element);
      return text == null ? null : TreeWalker.normalizeText(text);
    }
    return null;
  }

  /// The enabled state the `/screen` dump attaches to [element]'s node: the
  /// state of the control that owns it ([stateOwner] over its text run),
  /// or null when it is not part of a control.
  bool? dumpState(Element element) {
    final owner = stateOwner(element, labelOf: textRunLabel);
    return owner == null ? null : _elementState(owner);
  }

  /// Resolves the control a state assertion (`/assert_enabled`,
  /// `/assert_disabled`, `/is_enabled`) checks, from a `key`, `text`
  /// (compared in [match] mode) or `semantics` locator.
  ///
  /// The target must be on the page in front: a match on a page hidden
  /// under a dialog or sheet, on a closing route or in an offstage tab does
  /// not count, but one scrolled out of view or under the keyboard does —
  /// a button's state does not depend on where the list is scrolled. With
  /// [nth], the nth match of the visible list every route indexes
  /// ([visibleMatches]). Several matches that belong to one control (a
  /// label's `Text` and the `RichText` inside it) are one target; several
  /// controls are ambiguous. The chosen match answers through the control
  /// that owns it ([stateOwner]) — a button's label through the button.
  StateTarget resolveStateTarget({
    String? key,
    String? text,
    String? semantics,
    TextMatch match = TextMatch.exact,
    int? nth,
  }) {
    final String desc;
    final List<Element> matches;
    final String? Function(Element) labelOf;
    if (key != null) {
      desc = 'key "$key"';
      matches = findAllElementsByKey(key);
      labelOf = textRunLabel;
    } else if (text != null) {
      desc = match.describe(text);
      matches = findAllElementsByTextMatch(text, match);
      labelOf = textRunLabel;
    } else if (semantics != null) {
      desc = 'semantics "$semantics"';
      matches = findAllElementsBySemantics(semantics);
      labelOf = semanticsOf;
    } else {
      throw ArgumentError('a "key", "text" or "semantics" locator is required');
    }
    if (matches.isEmpty) return StateMissing('no widget matches $desc');

    Element? owner(Element e) => stateOwner(e, labelOf: labelOf, descend: true);

    if (nth != null) {
      final visible = visibleMatches(matches);
      if (nth < 0 || nth >= visible.length) {
        return StateMissing('nth $nth is out of range for $desc: '
            '${visible.length} visible match(es)');
      }
      final control = owner(visible[nth]);
      return control == null
          ? StateNotAControl(desc)
          : StateFound(
              control, controlState(control), describeControl(control));
    }

    final layers = _routeLayers();
    final present = <Element>[];
    String? hiddenWhy;
    for (final e in inReadingOrder(matches)) {
      if (_isOffstage(e)) {
        hiddenWhy ??= 'is offstage (an inactive tab or a page kept alive '
            'underneath)';
        continue;
      }
      if (layers.hides(e)) {
        hiddenWhy ??= 'is on a route hidden behind a dialog/sheet/page, or on '
            'a route that is closing';
        continue;
      }
      present.add(e);
    }
    if (present.isEmpty) {
      return StateMissing('$desc exists but ${hiddenWhy ?? 'is not laid out'}');
    }

    final controls = <Element?>[];
    for (final e in present) {
      final control = owner(e);
      if (!controls.any((c) => identical(c, control))) controls.add(control);
    }
    if (controls.length > 1) {
      final named = [
        for (final c in controls)
          c == null ? 'a non-control' : describeControl(c),
      ].join('; ');
      return StateMissing('$desc is ambiguous: it names ${controls.length} '
          'widgets ($named). Pass nth (0-based, reading order of the visible '
          'matches) or use a ValueKey');
    }
    final control = controls.single;
    return control == null
        ? StateNotAControl(desc)
        : StateFound(control, controlState(control), describeControl(control));
  }

  /// The enabled state of [owner], a control returned by [stateOwner].
  bool controlState(Element owner) {
    final state = _elementState(owner);
    if (state == null) {
      throw StateError('${owner.widget.runtimeType} is not a control');
    }
    return state;
  }

  /// How a control reads in a state assertion's message:
  /// `FilledButton "Log in"`, `IconButton (semantics "Close")`,
  /// `ListTile key "row_3"`.
  String describeControl(Element owner) {
    final type = owner.widget.runtimeType.toString();
    final key = TreeWalker.keyOf(owner.widget);
    final text = extractText(owner);
    final parts = <String>[type];
    if (key != null) parts.add('key "$key"');
    if (text != null && _hasAlnum(text)) {
      parts.add('"${TreeWalker.normalizeText(text)}"');
    } else {
      final semantics = semanticsOf(owner);
      if (semantics != null) parts.add('(semantics "$semantics")');
    }
    return parts.join(' ');
  }
}
