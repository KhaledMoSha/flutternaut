part of '../tree_walker.dart';

/// Editable fields: the field a label or key names, and the focused field.
extension TreeWalkerFields on TreeWalker {
  /// The [EditableTextState] of the text field that currently holds
  /// keyboard focus, or null when no field is focused. A field the app
  /// itself focused (an OTP widget whose real input sits hidden under
  /// its digit boxes) is typed into through this, exactly as the OS
  /// keyboard would deliver keystrokes to it — no hit-test is involved
  /// because the app's own focus is the proof the field accepts input.
  EditableTextState? focusedEditableState() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;

    EditableTextState? primary;
    EditableTextState? withinScope;
    void visit(Element element) {
      if (primary != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        final state = element.state as EditableTextState;
        final node = state.widget.focusNode;
        if (node.hasPrimaryFocus) {
          primary = state;
          return;
        }
        withinScope ??= node.hasFocus ? state : null;
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return primary ?? withinScope;
  }

  /// Resolves the visible label [text] to the [TextEditingController]
  /// of its associated editable field — without relying on focus.
  ///
  /// Order:
  ///   (a) the matched element is, or is inside, an [EditableText]
  ///       (covers `InputDecoration.labelText`/`hintText` and matching
  ///       a field by its own current text);
  ///   (b) otherwise the label is a sibling of its field — pick the
  ///       on-screen [EditableText] geometrically nearest below/right
  ///       of the label's rect.
  ///
  /// Returns null if no field can be confidently associated; callers
  /// must NOT fall back to the focused field (failing is safer than
  /// typing into the wrong one).
  TextEditingController? findControllerByText(String text) {
    final el = _resolveEditableElementByText(text);
    return el == null ? null : (el.widget as EditableText).controller;
  }

  /// Like [findControllerByText] but returns the [EditableTextState] of
  /// the associated field, so callers can drive it through the real
  /// input pipeline (`userUpdateTextEditingValue`) — firing `onChanged`
  /// and applying `inputFormatters`.
  EditableTextState? findEditableStateByText(String text) {
    return _stateOf(_resolveEditableElementByText(text));
  }

  /// The [EditableText] element associated with the visible label [text]
  /// (the matched element itself if it is/encloses an [EditableText],
  /// otherwise the geometrically nearest field). Used by the type/clear
  /// confirm pipeline to gate the *field* — not the label — for
  /// visibility and tappability.
  Element? findEditableElementByText(String text) =>
      _resolveEditableElementByText(text);

  /// The [EditableText] element of the field located by [ValueKey] —
  /// the keyed element itself or its first [EditableText] descendant
  /// (the key is normally on the `TextField`, an ancestor of its
  /// `EditableText`). Null if no editable descendant exists.
  Element? findEditableElementByKey(String keyValue) {
    final keyed = findElementByKey(keyValue);
    if (keyed == null) return null;
    if (keyed.widget is EditableText) return keyed;

    Element? editable;
    void visit(Element element) {
      if (editable != null) return;
      if (element.widget is EditableText) {
        editable = element;
        return;
      }
      element.visitChildren(visit);
    }

    keyed.visitChildren(visit);
    return editable;
  }

  /// The [EditableTextState] backing an [EditableText] [element], or null.
  EditableTextState? editableStateOf(Element? element) => _stateOf(element);

  /// Resolves the visible label [text] to the [EditableText] element of
  /// its associated field. See [findControllerByText] for the order.
  ///
  /// The label is the first match, in tree order, that is not structurally
  /// hidden — on a route hidden behind another page, dialog or sheet, or
  /// under an active `Offstage` (an inactive tab). A page kept underneath
  /// the current one often carries the same form at the same place (an
  /// edit-menu page under a new-category page, both titled "Name in
  /// English"); taking its label typed into — or, gated, refused as
  /// occluded — a field the user cannot see. Opacity, position and coverage
  /// are deliberately not judged on the label: a filled field's hint is
  /// faded out yet still names the field, and a field below the fold is
  /// brought into view by the gate.
  Element? _resolveEditableElementByText(String text) {
    final layers = _routeLayers();
    Element? el;
    for (final match
        in _findAllElementsWhere(_textMatcher(text, TextMatch.exact))) {
      if (layers.hides(match) || _isOffstage(match)) continue;
      el = match;
      break;
    }
    if (el == null) return null;

    final enclosing = _enclosingEditableElement(el);
    if (enclosing != null) return enclosing;

    final labelRect = _rectOf(el);
    if (labelRect == null) return null;
    return _nearestFieldElement(labelRect, layers);
  }

  /// The [EditableTextState] for an [EditableText] element, or null.
  EditableTextState? _stateOf(Element? el) {
    if (el is StatefulElement && el.state is EditableTextState) {
      return el.state as EditableTextState;
    }
    return null;
  }

  /// The [EditableText] element of [el] itself or its nearest
  /// [EditableText] ancestor, or null.
  Element? _enclosingEditableElement(Element el) {
    if (el.widget is EditableText) return el;
    Element? found;
    el.visitAncestorElements((ancestor) {
      if (ancestor.widget is EditableText) {
        found = ancestor;
        return false; // stop
      }
      return true;
    });
    return found;
  }

  /// Picks the on-screen [EditableText] element geometrically associated
  /// with a sibling [labelRect]: smallest vertical gap where the field
  /// starts at/below the label, tie-broken by horizontal center
  /// distance, within ~one form row. Returns null if nothing qualifies.
  /// A field on a route [layers] hides never qualifies: a page underneath
  /// can hold a field at the very same place.
  Element? _nearestFieldElement(ElementRect labelRect, _RouteLayers layers) {
    final screen = _screenSize;
    final candidates = <(ElementRect, Element)>[];

    void walk(Element element) {
      final w = element.widget;
      if (w is EditableText &&
          _isOnScreen(element, screen) &&
          !layers.hides(element)) {
        final r = _rectOf(element);
        if (r != null) candidates.add((r, element));
      }
      element.visitChildren(walk);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    root.visitChildren(walk);
    if (candidates.isEmpty) return null;

    final labelBottom = labelRect.y + labelRect.height;
    final labelCenterX = labelRect.x + labelRect.width / 2;
    const sameRowEpsilon = 8.0;
    final maxGap = labelRect.height + 80.0;

    Element? best;
    double bestPrimary = double.infinity;
    double bestSecondary = double.infinity;

    for (final c in candidates) {
      final r = c.$1;
      // Field must be on the same row or below the label.
      if (r.y < labelRect.y - sameRowEpsilon) continue;
      final verticalGap = (r.y - labelBottom).clamp(0.0, double.infinity);
      final sameRow = (r.y - labelRect.y).abs() <= sameRowEpsilon;
      if (!sameRow && verticalGap > maxGap) continue;
      final centerX = r.x + r.width / 2;
      final horizontal = (centerX - labelCenterX).abs();

      if (verticalGap < bestPrimary ||
          (verticalGap == bestPrimary && horizontal < bestSecondary)) {
        best = c.$2;
        bestPrimary = verticalGap;
        bestSecondary = horizontal;
      }
    }

    return best;
  }
}
