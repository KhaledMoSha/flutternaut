import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/element_info.dart';
import '../models/element_rect.dart';
import '../models/visibility_result.dart';

/// How a `text` locator is compared with a widget's own visible text —
/// the `match` field of a bridge request (`"exact"`, `"contains"`,
/// `"starts_with"`).
///
/// Every mode compares against the same per-widget text (a [Text] or
/// `Text.rich`, a [RichText], or an [EditableText]'s value — never a
/// container's merged descendants), so the three modes only differ in the
/// comparison itself and resolve through the same nth / ambiguity /
/// visibility / hit-test pipeline.
enum TextMatch {
  /// The widget's text equals the locator, **case-sensitively** — the
  /// default, and the only mode a catalog ref records.
  exact,

  /// The widget's text contains the locator as a substring,
  /// case-insensitively — for labels a test only knows part of
  /// ("Start 7-Day Free Trial").
  contains,

  /// The widget's text begins with the locator, case-insensitively — for
  /// labels with a variable tail ("Bag · 3"), without also matching every
  /// label that merely mentions the locator somewhere inside.
  startsWith;

  /// How a locator [text] compared in this mode reads in a failure or
  /// visibility reason: `text "x"`, `text containing "x"`,
  /// `text starting with "x"`. One phrasing for every route, so a reason
  /// always says which comparison failed.
  String describe(String text) => switch (this) {
        TextMatch.exact => 'text "$text"',
        TextMatch.contains => 'text containing "$text"',
        TextMatch.startsWith => 'text starting with "$text"',
      };
}

/// Walks the Flutter element tree to find widgets by [ValueKey] or text,
/// read their properties, check visibility, and dump the tree structure.
///
/// All operations are synchronous and must run on the main UI thread.
class TreeWalker {
  // ---------------------------------------------------------------------------
  // Finding
  // ---------------------------------------------------------------------------

  /// The addressable key string of [widget], or null when it has none.
  ///
  /// Only a [ValueKey] whose value is a plain scalar — [String], [num],
  /// [bool] or an enum — is a locator a test can be written against.
  /// Packages routinely key widgets with objects (`octo_image` keys its
  /// `Image` with the `ImageProvider`, which stringifies to
  /// `ResizeImage(CachedNetworkImageProvider(...))`): those strings are
  /// noise in a screen readout and unstable as locators, so they do not
  /// count as keys anywhere in the bridge.
  static String? keyOf(Widget widget) {
    final key = widget.key;
    if (key is! ValueKey) return null;
    final value = key.value;
    if (value is String || value is num || value is bool || value is Enum) {
      return value.toString();
    }
    return null;
  }

  /// Finds the first element whose [ValueKey] value matches [keyValue].
  ElementInfo? findByKey(String keyValue) {
    return _findWhere((element) => keyOf(element.widget) == keyValue);
  }

  /// The accessibility label a widget carries for itself: an [Icon]'s
  /// `semanticLabel`, an [IconButton]'s `tooltip`, a [Tooltip]'s
  /// `message`, or a [Semantics] `label`. Null when [widget] declares
  /// none. This is what makes an icon-only control readable in the
  /// screen dump and addressable with the `semantics` locator.
  static String? ownSemanticsOf(Widget widget) {
    String? label;
    if (widget is Icon) {
      label = widget.semanticLabel;
    } else if (widget is IconButton) {
      label = widget.tooltip;
    } else if (widget is Tooltip) {
      label = widget.message;
    } else if (widget is Semantics) {
      label = widget.properties.label ?? widget.properties.tooltip;
    }
    final trimmed = label?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// The accessibility label to attach to a dump node: the element's own
  /// ([ownSemanticsOf]), else the first one declared in its subtree without
  /// crossing into a nested control (a `GestureDetector` around an
  /// `Icon(semanticLabel:)` takes the icon's label; a wrapper around an
  /// `IconButton` does not take the button's tooltip), else
  /// one declared by a close ancestor (`Tooltip(message:, child: button)`
  /// wraps the control it describes — through a few internal widgets of
  /// its own). The ancestor walk stops at another control or scroll view
  /// so a label is never borrowed from an unrelated container. The subtree
  /// search stops at the same [_isLabelBoundary] as a node's text label and
  /// skips a label the user cannot see ([_isOnScreen]).
  String? semanticsOf(Element element) {
    final own = ownSemanticsOf(element.widget);
    if (own != null) return own;

    final screen = _screenSize;
    String? found;
    void visit(Element child) {
      if (found != null) return;
      // A descendant that is a control of its own keeps its label: a slot
      // or wrapper around an IconButton must not be listed as "Open menu"
      // next to the button itself.
      final w = child.widget;
      if (_isButtonLike(w) || _extractEnabled(w) != null) return;
      if (_isLabelBoundary(w)) return;
      final label = ownSemanticsOf(w);
      if (label != null) {
        if (_isOnScreen(child, screen)) found = label;
        return;
      }
      child.visitChildren(visit);
    }

    element.visitChildren(visit);
    if (found != null) return found;

    var hops = 0;
    element.visitAncestorElements((ancestor) {
      final w = ancestor.widget;
      if (_isButtonLike(w) || w is Scrollable || w is EditableText) {
        return false;
      }
      found = ownSemanticsOf(w);
      if (found != null) return false;
      hops++;
      return hops < _semanticsAncestorHops;
    });
    return found;
  }

  /// How far up [semanticsOf] looks for a wrapping label. `Tooltip` places
  /// its child under a `Semantics` + mouse region + `Listener` of its own,
  /// so the describing widget is typically 3–5 elements above the control.
  static const int _semanticsAncestorHops = 6;

  /// The accessibility identifier a [Semantics] widget declares
  /// (`Semantics(identifier: 'btn:nav:search')` — Flutter's
  /// `resource-id` / `accessibilityIdentifier`), trimmed. Null for any
  /// other widget and for an empty identifier. Like [ownSemanticsOf], this
  /// is what the `semantics` locator matches.
  static String? ownSemanticsIdOf(Widget widget) {
    if (widget is! Semantics) return null;
    final trimmed = widget.properties.identifier?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// The accessibility identifier to attach to a dump node as
  /// `semantics_id`: the element's own ([ownSemanticsIdOf]), else the one a
  /// close ancestor [Semantics] declares **for exactly this widget** — the
  /// first ancestor with an identifier decides, and it counts only when its
  /// rect equals the element's (within [_semanticsIdRectSlack] on x, y,
  /// width and height). `Semantics(identifier:, child: GestureDetector(…))`
  /// (with or without a `MergeSemantics` above it) names the detector;
  /// `Semantics(identifier: 'section:…', child: Row(…))` around a bar names
  /// none of the controls inside it.
  ///
  /// The walk stops, as [semanticsOf]'s does, at another control, a scroll
  /// view or a text field, and after [_semanticsAncestorHops]. The subtree
  /// is never searched: an identifier inside a control names whatever it
  /// wraps there, not the control around it.
  String? semanticsIdOf(Element element) {
    final own = ownSemanticsIdOf(element.widget);
    if (own != null) return own;
    final rect = _rectOf(element);
    if (rect == null) return null;

    String? found;
    var hops = 0;
    element.visitAncestorElements((ancestor) {
      final w = ancestor.widget;
      if (_isButtonLike(w) || w is Scrollable || w is EditableText) {
        return false;
      }
      final id = ownSemanticsIdOf(w);
      if (id != null) {
        final ancestorRect = _rectOf(ancestor);
        if (ancestorRect != null && _sameRect(ancestorRect, rect)) found = id;
        return false;
      }
      hops++;
      return hops < _semanticsAncestorHops;
    });
    return found;
  }

  /// How far (logical px) two rects may differ on x, y, width and height
  /// and still be one widget's bounds — a `Semantics` wrapper and the
  /// control it wraps share them, up to rounding.
  static const double _semanticsIdRectSlack = 0.5;

  /// Whether [a] and [b] are the same bounds within
  /// [_semanticsIdRectSlack].
  static bool _sameRect(ElementRect a, ElementRect b) =>
      (a.x - b.x).abs() <= _semanticsIdRectSlack &&
      (a.y - b.y).abs() <= _semanticsIdRectSlack &&
      (a.width - b.width).abs() <= _semanticsIdRectSlack &&
      (a.height - b.height).abs() <= _semanticsIdRectSlack;

  /// Whether [widget] is what a `semantics` locator [target] names: its own
  /// accessibility label ([ownSemanticsOf]) or its own identifier
  /// ([ownSemanticsIdOf]) equals [target] — exactly, or with [foldCase]
  /// case-insensitively ([target] is then already lower-cased).
  static bool _semanticsMatch(
    Widget widget,
    String target, {
    required bool foldCase,
  }) {
    final label = ownSemanticsOf(widget);
    final id = ownSemanticsIdOf(widget);
    if (foldCase) {
      return label?.toLowerCase() == target || id?.toLowerCase() == target;
    }
    return label == target || id == target;
  }

  /// Finds the first element whose own accessibility label
  /// ([ownSemanticsOf]) or identifier ([ownSemanticsIdOf]) equals [label]
  /// exactly, else — so a test written against a tooltip survives a
  /// capitalisation change — the first whose label or identifier equals it
  /// case-insensitively.
  ElementInfo? findBySemantics(String label) {
    final el = findElementBySemantics(label);
    return el == null ? null : extractInfo(el);
  }

  /// The [Element] version of [findBySemantics].
  Element? findElementBySemantics(String label) {
    final exact = _findElementWhere(
      (e) => _semanticsMatch(e.widget, label, foldCase: false),
    );
    if (exact != null) return exact;
    final needle = label.toLowerCase();
    return _findElementWhere(
      (e) => _semanticsMatch(e.widget, needle, foldCase: true),
    );
  }

  /// Every element whose own accessibility label or identifier equals
  /// [label] (exact first; case-insensitive when nothing matches exactly).
  /// Used by the tap/long-press confirm pipeline for ambiguity detection.
  ///
  /// A match on a `Semantics` wrapper is the wrapper itself: a tap at its
  /// centre reaches the control it wraps (the wrapper's render object is on
  /// the hit path), exactly as for a `Semantics(label:)` match.
  List<Element> findAllElementsBySemantics(String label) {
    final exact = _findAllElementsWhere(
      (e) => _semanticsMatch(e.widget, label, foldCase: false),
    );
    if (exact.isNotEmpty) return exact;
    final needle = label.toLowerCase();
    return _findAllElementsWhere(
      (e) => _semanticsMatch(e.widget, needle, foldCase: true),
    );
  }

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

  /// The element's own visible text — plain [Text], `Text.rich`
  /// ([TextSpan]), [RichText], or [EditableText]. Null otherwise.
  ///
  /// Uses `toPlainText(includeSemanticsLabels: false)` so a span's
  /// `semanticsLabel` override doesn't shadow the visible text.
  ///
  /// Display text goes through [normalizeText] (an inline `WidgetSpan` such
  /// as a typing cursor is left out, surrounding whitespace trimmed) so the
  /// `/screen` dump and every text finder see the SAME string — a label
  /// the dump reports is always a label the finders match. A field's
  /// value ([EditableText]) is user data and is returned verbatim.
  String? _widgetOwnText(Widget w) {
    if (w is EditableText) return w.controller.text;
    if (w is Text) {
      final raw =
          w.data ?? w.textSpan?.toPlainText(includeSemanticsLabels: false);
      return raw == null ? null : normalizeText(raw);
    }
    if (w is RichText) {
      return normalizeText(w.text.toPlainText(includeSemanticsLabels: false));
    }
    return null;
  }

  /// The object-replacement character `toPlainText` emits for each inline
  /// widget ([WidgetSpan]/[PlaceholderSpan]).
  static const String _placeholderChar = '￼';

  /// Canonical form of a display string: inline-widget placeholders
  /// removed (the whitespace they leave collapsed to one space) and the
  /// result trimmed. Applied to both sides of every text match.
  static String normalizeText(String raw) {
    if (!raw.contains(_placeholderChar)) return raw.trim();
    return raw
        .replaceAll(RegExp(r'[ \t]*￼[ \t]*'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
  }

  /// The one text predicate behind every text finder: whether an
  /// element's own text ([_widgetOwnText]) matches the locator [text] in
  /// [match] mode.
  ///
  /// The locator is normalized once, here, rather than per element.
  ///  * [TextMatch.exact] — `own == normalizeText(text)`, case-sensitive.
  ///    The own text is compared as [_widgetOwnText] returns it, so a
  ///    field's value still has to equal the locator verbatim.
  ///  * [TextMatch.contains] / [TextMatch.startsWith] — both sides
  ///    normalized and lower-cased. Normalizing the field value too means
  ///    a value with surrounding spaces still starts with its first word;
  ///    normalizing the locator means `" Log in "` and `"Log in"` are the
  ///    same needle, as they already are for exact.
  bool Function(Element) _textMatcher(String text, TextMatch match) {
    final needle = normalizeText(text);
    // An empty needle is a prefix and a substring of every text: a contains
    // or starts_with check on it would match any widget, and an assertion
    // built on it would pass whatever the screen shows.
    if (needle.isEmpty && match != TextMatch.exact) {
      throw ArgumentError(
        '${match.describe(text)} needs at least one visible character to '
        'match; got ${text.isEmpty ? 'an empty text' : 'only whitespace'}',
      );
    }
    switch (match) {
      case TextMatch.exact:
        return (element) => _widgetOwnText(element.widget) == needle;
      case TextMatch.contains:
        final lower = needle.toLowerCase();
        return (element) => _foldedOwnText(element)?.contains(lower) ?? false;
      case TextMatch.startsWith:
        final lower = needle.toLowerCase();
        return (element) => _foldedOwnText(element)?.startsWith(lower) ?? false;
    }
  }

  /// [element]'s own text normalized and lower-cased — the haystack of the
  /// case-insensitive modes (see [_textMatcher]); null when the widget
  /// carries no text of its own.
  String? _foldedOwnText(Element element) {
    final own = _widgetOwnText(element.widget);
    return own == null ? null : normalizeText(own).toLowerCase();
  }

  /// Finds the first text-bearing widget ([Text], `Text.rich`,
  /// [RichText], [EditableText]) whose visible text matches [text]
  /// exactly.
  ElementInfo? findByText(String text) =>
      findByTextMatch(text, TextMatch.exact);

  /// Finds the first text-bearing widget whose own visible text matches
  /// [text] in [match] mode (see [TextMatch]).
  ElementInfo? findByTextMatch(String text, TextMatch match) {
    return _findWhere(_textMatcher(text, match));
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

  /// Finds the first text-bearing widget whose visible text contains
  /// [substring], **case-insensitively** (contains is the fuzzy,
  /// opt-in path; exact matching via [findByText] stays case-sensitive).
  ElementInfo? findByTextContains(String substring) =>
      findByTextMatch(substring, TextMatch.contains);

  /// Finds the first [Element] whose [ValueKey] value matches [keyValue].
  Element? findElementByKey(String keyValue) {
    return _findElementWhere((element) => keyOf(element.widget) == keyValue);
  }

  /// Finds the first [Element] whose own visible text equals [text]
  /// exactly (case-sensitive — see [findByText]).
  Element? findElementByText(String text) {
    return _findElementWhere(_textMatcher(text, TextMatch.exact));
  }

  /// Every [Element] whose [ValueKey] value matches [keyValue]. Used to
  /// detect ambiguous locators; more than one on-screen, hittable match
  /// is a fatal authoring error.
  List<Element> findAllElementsByKey(String keyValue) {
    return _findAllElementsWhere(
      (element) => keyOf(element.widget) == keyValue,
    );
  }

  /// Every text-bearing [Element] whose own visible text equals [text]
  /// exactly (case-sensitive).
  List<Element> findAllElementsByText(String text) =>
      findAllElementsByTextMatch(text, TextMatch.exact);

  /// Every text-bearing [Element] whose own visible text matches [text] in
  /// [match] mode (see [TextMatch]) — every match, for ambiguity detection
  /// and visibility checks.
  List<Element> findAllElementsByTextMatch(String text, TextMatch match) {
    return _findAllElementsWhere(_textMatcher(text, match));
  }

  /// Every text-bearing [Element] whose own visible text equals [text]
  /// exactly AND is currently on screen. Used to resolve a row anchor —
  /// off-screen duplicates of the anchor text are not real conflicts.
  List<Element> findOnScreenElementsByText(String text) {
    final screen = _screenSize;
    return findAllElementsByText(text)
        .where((e) => _isOnScreen(e, screen))
        .toList();
  }

  /// Row band tolerance (logical px) for grouping `near` candidates into rows
  /// in [_readingOrder]. MUST match `nearRowTolerance` in the engine catalog
  /// (engine/catalog/catalog.go) or recorded `nth` values will drift.
  static const double _kNearRowTolerance = 12.0;

  /// The unlabeled interactive elements sharing [anchor]'s vertical band, in
  /// **reading order** — rows top→bottom, then left→right within a row.
  ///
  /// This is the bridge half of the `near` locator contract — the catalog
  /// (engine/catalog) derives `nth` from the `/screen` dump with the SAME
  /// rule ([_readingOrder] + [_kNearRowTolerance]), so the index a test
  /// records always resolves to the same widget. A candidate is:
  /// - interactive (a control by [dumpState] — the same rule that puts
  ///   `enabled` on a dump node),
  /// - no [ValueKey] and no visible text in its subtree (truly unlabeled),
  /// - on screen and unobstructed (the dump's visibility gates),
  /// - not a **container** ([_isNearContainer]: a page wrapper, or a shell
  ///   with readable text centered inside it) — a container is searched
  ///   through, never counted,
  /// - **outermost only** among the rest: a candidate's subtree is never
  ///   searched for more candidates (an `_IconButton` wrapping an enabled
  ///   `GestureDetector` counts once),
  /// - rect vertically overlaps [anchor]'s rect.
  List<Element> unlabeledInteractiveNear(Element anchor) {
    final anchorRect = _rectOf(anchor);
    final root = WidgetsBinding.instance.rootElement;
    if (anchorRect == null || root == null) return const [];

    final screen = _screenSize;
    final layers = _routeLayers();
    final candidates = <({ElementRect rect, Element el})>[];

    void visit(Element element) {
      // The shell check (unlabeled + interactive + visible) selects
      // candidates and prunes: a candidate's subtree is never searched
      // again, so a wrapper and its inner gesture detector count once. A
      // container shell is neither a candidate nor a stop — an app-wide
      // detector (`requests_inspector`'s long-press layer, a keyboard-dismiss
      // wrapper around a page) or a tile the catalog labels with its inner
      // text (its labelIconButtons pass): the controls inside it are searched.
      if (_isUnlabeledInteractiveShell(element, screen, layers)) {
        final rect = _rectOf(element);
        if (rect == null) return;
        if (!_isNearContainer(element, rect, screen)) {
          if (_yOverlaps(rect, anchorRect)) {
            candidates.add((rect: rect, el: element));
          }
          return; // outermost-only: never descend into a candidate shell
        }
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return _readingOrder(candidates).map((c) => c.el).toList();
  }

  /// Whether the `near` shell [element] (laid out at [rect]) is a container
  /// rather than a control — the engine catalog's rule too, so a recorded
  /// `nth` never drifts:
  ///
  ///  * a **page wrapper**: its visible rect (the dump node's `rect`) is at
  ///    least half the [screen] tall. With the screen size unknown nothing
  ///    is a page wrapper;
  ///  * or readable text is centered inside [rect]
  ///    ([_hasReadableTextCenteredInside]) — the catalog labels that
  ///    control with the inner text, so it is addressable without `near`.
  bool _isNearContainer(Element element, ElementRect rect, Size? screen) {
    if (screen != null) {
      final visible = _visibleRect(element, screen);
      if (visible != null && visible.height >= screen.height / 2) return true;
    }
    return _hasReadableTextCenteredInside(rect, screen);
  }

  /// [elements] sorted in reading order — the same rows-then-columns rule
  /// as the `near` locator ([_readingOrder]) and the engine catalog — so an
  /// `nth` recorded against duplicate text resolves to the same widget the
  /// catalog numbered. Elements without laid-out geometry are dropped.
  List<Element> inReadingOrder(List<Element> elements) {
    final items = <({ElementRect rect, Element el})>[];
    for (final el in elements) {
      final rect = _rectOf(el);
      if (rect != null) items.add((rect: rect, el: el));
    }
    return _readingOrder(items).map((c) => c.el).toList();
  }

  /// Orders rect-bearing items in reading order: group into rows (an item
  /// joins the current row while its y-center is within [_kNearRowTolerance]
  /// of the row's first item), rows top→bottom, items left→right within a row.
  /// The comparator is purely geometric — (yCenter, xCenter, y, x) — so it is a
  /// strict total order identical to the engine catalog's `readingOrder`, with
  /// no dependence on traversal/collection order.
  List<({ElementRect rect, Element el})> _readingOrder(
    List<({ElementRect rect, Element el})> items,
  ) {
    double yc(ElementRect r) => r.y + r.height / 2;
    double xc(ElementRect r) => r.x + r.width / 2;
    int cmpGeom(ElementRect a, ElementRect b) {
      if (yc(a) != yc(b)) return yc(a).compareTo(yc(b));
      if (xc(a) != xc(b)) return xc(a).compareTo(xc(b));
      if (a.y != b.y) return a.y.compareTo(b.y);
      return a.x.compareTo(b.x);
    }

    final sorted = [...items]..sort((a, b) => cmpGeom(a.rect, b.rect));

    final rows = <List<({ElementRect rect, Element el})>>[];
    double rowTop = 0;
    for (final item in sorted) {
      if (rows.isEmpty || yc(item.rect) - rowTop > _kNearRowTolerance) {
        rows.add([item]);
        rowTop = yc(item.rect);
      } else {
        rows.last.add(item);
      }
    }

    final out = <({ElementRect rect, Element el})>[];
    for (final row in rows) {
      row.sort((a, b) {
        final ax = xc(a.rect), bx = xc(b.rect);
        if (ax != bx) return ax.compareTo(bx);
        if (a.rect.y != b.rect.y) return a.rect.y.compareTo(b.rect.y);
        return a.rect.x.compareTo(b.rect.x);
      });
      out.addAll(row);
    }
    return out;
  }

  /// Whether [element] is an interactive control with no addressable
  /// identity of its own that is actually visible — the shell rule of the
  /// `near` locator (see [unlabeledInteractiveNear] for how it is used).
  ///
  /// "Unlabeled" means no **readable** text: an [Icon]'s glyph renders as a
  /// private-use character through an internal [RichText], so an icon-only
  /// button does carry text — just not text a human (or locator) can use.
  bool _isUnlabeledInteractiveShell(
    Element element,
    Size? screen,
    _RouteLayers layers,
  ) {
    if (keyOf(element.widget) != null) return false;
    if (dumpState(element) == null) return false;
    final text = _nodeText(element, screen, layers);
    if (text != null && _hasAlnum(text)) return false;
    return _isOnScreen(element, screen) && _isUnobstructed(element);
  }

  /// Whether any on-screen element with readable (alphanumeric) text has
  /// its center inside [bounds].
  bool _hasReadableTextCenteredInside(ElementRect bounds, Size? screen) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return false;

    var found = false;
    void visit(Element element) {
      if (found) return;
      final text = _widgetOwnText(element.widget);
      if (text != null && _hasAlnum(text) && _isOnScreen(element, screen)) {
        final r = _rectOf(element);
        if (r != null &&
            r.x + r.width / 2 >= bounds.x &&
            r.x + r.width / 2 <= bounds.x + bounds.width &&
            r.y + r.height / 2 >= bounds.y &&
            r.y + r.height / 2 <= bounds.y + bounds.height) {
          found = true;
          return;
        }
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found;
  }

  /// Whether [s] contains any letter or digit — glyph "labels"
  /// (private-use code points) do not count as readable text.
  bool _hasAlnum(String s) =>
      s.contains(RegExp(r'[\p{L}\p{N}]', unicode: true));

  /// Whether two rects overlap on the vertical axis (share a row band).
  bool _yOverlaps(ElementRect a, ElementRect b) =>
      a.y < b.y + b.height && b.y < a.y + a.height;

  /// Returns all elements that have a [ValueKey].
  List<ElementInfo> findAllKeyed() {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const [];

    final results = <ElementInfo>[];
    void visitor(Element element) {
      if (keyOf(element.widget) != null) {
        results.add(extractInfo(element));
      }
      element.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);
    return results;
  }

  // ---------------------------------------------------------------------------
  // Visibility
  // ---------------------------------------------------------------------------

  /// Checks whether a widget whose text equals [text] is visible — to a
  /// person looking at the screen, by the same rules the `/screen` dump
  /// uses (see [_visibilityOf]): laid out, not offstage, painted above
  /// [_visibleOpacityThreshold], not clipped away, not on a route hidden
  /// by a modal or being closed, and not covered at every sample point.
  ///
  /// Every match is considered, not just the first in tree order: a hidden
  /// duplicate (a page kept alive underneath, a faded-out cross-fade layer)
  /// never masks a visible one. With [nth], exactly the nth visible match
  /// (reading order, stacked copies of one control counted once) must
  /// exist — the same index the dump reports as `text_nth`.
  VisibilityResult checkTextVisible(String text, {int? nth}) =>
      checkTextMatchVisible(text, TextMatch.exact, nth: nth);

  /// Visibility of the widget(s) whose own visible text matches [text] in
  /// [match] mode (see [TextMatch] and [checkTextVisible]). The reason names
  /// the comparison — `text "x"`, `text containing "x"` or
  /// `text starting with "x"` (see [TextMatch.describe]).
  VisibilityResult checkTextMatchVisible(
    String text,
    TextMatch match, {
    int? nth,
  }) {
    return _checkVisibility(
      findAllElementsByTextMatch(text, match),
      match.describe(text),
      nth: nth,
    );
  }

  /// Visibility of the widget(s) with [ValueKey] [keyValue] (see
  /// [checkTextVisible]).
  VisibilityResult checkVisibleByKey(String keyValue, {int? nth}) {
    return _checkVisibility(
      findAllElementsByKey(keyValue),
      'key "$keyValue"',
      nth: nth,
    );
  }

  /// Visibility of the widget(s) whose visible text contains [substring]
  /// (case-insensitive) — the `match: "contains"` form, for labels such as
  /// "Start 7-Day Free Trial" that a test only knows part of (see
  /// [checkTextVisible]).
  VisibilityResult checkTextContainsVisible(String substring, {int? nth}) =>
      checkTextMatchVisible(substring, TextMatch.contains, nth: nth);

  /// Visibility of the widget(s) with accessibility label or identifier
  /// [label] (see [findAllElementsBySemantics] and [checkTextVisible]).
  VisibilityResult checkVisibleBySemantics(String label, {int? nth}) {
    return _checkVisibility(
      findAllElementsBySemantics(label),
      'semantics "$label"',
      nth: nth,
    );
  }

  /// The [ScrollPosition] of a [Scrollable] element, or null when no
  /// position is attached yet. Public so the gesture engine can tell
  /// which visible scrollables can actually move in a direction.
  ScrollPosition? scrollPositionOf(Element element) =>
      _scrollPositionOf(element);

  /// Whether a **route transition** is in progress right now — a page push
  /// or pop, a dialog, bottom sheet or menu opening or closing, or an
  /// interactive back-swipe. This is what `/wait_for_idle` waits for and
  /// what the dump's `animating` flag reports: while a route animates,
  /// Flutter drops or cancels pointers, so acting mid-transition is
  /// unreliable.
  ///
  /// Continuous content animations (a spinner, a Lottie loop, a live map
  /// feed) are deliberately NOT transitions — they never end, so waiting
  /// for them can never succeed. They are reported separately by
  /// [runningAnimations].
  bool get isTransitioning => _transitionState().transitioning;

  /// The on-screen content animations running right now, by kind
  /// (`spinner`, `lottie`, `shimmer`, `animation`) → count. Excludes route
  /// transitions (see [isTransitioning]) and anything hidden — offstage
  /// tabs, routes underneath, faded-out layers — so the readout only names
  /// motion the user can actually see.
  ///
  /// The signal is the tree, not the scheduler: an [AnimatedWidget]
  /// (`AnimatedBuilder`, `SlideTransition`, …) or [FadeTransition] whose
  /// [Animation] is mid-flight. A focused field's blinking caret and a
  /// tap's ink ripple keep tickers alive without driving such a widget and
  /// are not reported.
  Map<String, int> runningAnimations() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const {};
    final routeAnimations = _transitionState().routeAnimations;
    final layers = _routeLayers();
    final screen = _screenSize;
    final counts = <String, int>{};
    // One owner widget (a CircularProgressIndicator, a Lottie) typically
    // drives several animated widgets; each owner counts once.
    final owners = <Element>{};

    void visit(Element element) {
      final animation = _drivingAnimation(element.widget);
      if (animation != null &&
          animation.isAnimating &&
          !_derivesFrom(animation, routeAnimations) &&
          _isOnScreen(element, screen) &&
          !layers.hides(element)) {
        final (kind, owner) = _animationKind(element);
        if (owners.add(owner)) counts[kind] = (counts[kind] ?? 0) + 1;
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return counts;
  }

  /// Every [ModalRoute] currently in the tree, read off the
  /// `_ModalScopeStatus` inherited widget each route builds. Reading the
  /// route through the element — instead of `ModalRoute.of(context)` —
  /// registers no dependency, so inspecting the app never makes it rebuild.
  List<ModalRoute<Object?>> _modalRoutes() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const [];
    final routes = <ModalRoute<Object?>>[];
    void visit(Element element) {
      final route = _routeOfScope(element);
      if (route != null) routes.add(route);
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return routes;
  }

  /// The route whose `_ModalScopeStatus` inherited widget [element] is, or
  /// null for any other element. Every [ModalRoute] builds exactly one,
  /// directly above its page, so this identifies route boundaries in the
  /// element tree. The widget class is private to the framework; its
  /// `route` field is read dynamically, and a framework change that
  /// removes it throws rather than silently hiding every route.
  static ModalRoute<Object?>? _routeOfScope(Element element) {
    if (element is! InheritedElement ||
        element.widget.runtimeType.toString() != '_ModalScopeStatus') {
      return null;
    }
    final Object? route = (element.widget as dynamic).route;
    return route is ModalRoute<Object?> ? route : null;
  }

  ({bool transitioning, Set<Animation<Object?>> routeAnimations})
      _transitionState() {
    var transitioning = false;
    final animations = <Animation<Object?>>{};
    for (final route in _modalRoutes()) {
      final primary = route.animation;
      final secondary = route.secondaryAnimation;
      if (primary != null) {
        animations.add(primary);
        if (primary.isAnimating) transitioning = true;
      }
      if (secondary != null) {
        animations.add(secondary);
        if (secondary.isAnimating) transitioning = true;
      }
      if (route.navigator?.userGestureInProgress ?? false) {
        transitioning = true;
      }
    }
    return (transitioning: transitioning, routeAnimations: animations);
  }

  /// The [Animation] driving [widget], if it is an animation-driven widget:
  /// an [AnimatedWidget] (`SlideTransition`, `AnimatedBuilder`,
  /// `ListenableBuilder`) whose listenable is an animation, or a
  /// [FadeTransition] (a render-object widget, not an [AnimatedWidget]).
  /// Implicitly animated widgets (`AnimatedContainer`, …) keep their
  /// controller protected and are not detected.
  Animation<Object?>? _drivingAnimation(Widget widget) {
    if (widget is AnimatedWidget) {
      final l = widget.listenable;
      return l is Animation<Object?> ? l : null;
    }
    if (widget is FadeTransition) return widget.opacity;
    if (widget is SliverFadeTransition) return widget.opacity;
    return null;
  }

  /// Whether [animation] is, or is derived from (curved, driven through a
  /// tween, proxied, reversed), one of the route [roots] — i.e. it is part
  /// of a route transition, not content animation.
  bool _derivesFrom(
    Animation<Object?> animation,
    Set<Animation<Object?>> roots,
  ) {
    Animation<Object?>? current = animation;
    for (var hops = 0; current != null && hops < 16; hops++) {
      if (roots.contains(current)) return true;
      final Object withParent = current;
      if (withParent is AnimationWithParentMixin<Object?>) {
        current = withParent.parent;
      } else if (current is ProxyAnimation) {
        current = current.parent;
      } else if (current is TrainHoppingAnimation) {
        current = current.currentTrain;
      } else if (current is CompoundAnimation<Object?>) {
        return _derivesFrom(current.first, roots) ||
            _derivesFrom(current.next, roots);
      } else {
        current = null;
      }
    }
    return false;
  }

  /// Names what kind of content animation [element] belongs to, by the
  /// nearest recognisable owner widget a few levels up, and returns that
  /// owner so the several animated widgets one spinner builds count once.
  (String, Element) _animationKind(Element element) {
    String? kind;
    Element owner = element;
    var hops = 0;
    void check(Element e) {
      final name = e.widget.runtimeType.toString();
      if (name.contains('ProgressIndicator') ||
          name.contains('ActivityIndicator') ||
          name.contains('Spinner') ||
          name.contains('Spinkit')) {
        kind = 'spinner';
      } else if (name.startsWith('Lottie')) {
        kind = 'lottie';
      } else if (name.contains('Shimmer') || name.contains('Skeleton')) {
        kind = 'shimmer';
      }
      if (kind != null) owner = e;
    }

    check(element);
    if (kind == null) {
      element.visitAncestorElements((ancestor) {
        check(ancestor);
        hops++;
        return kind == null && hops < _animationOwnerHops;
      });
    }
    return (kind ?? 'animation', owner);
  }

  /// How far up [_animationKind] looks for the owning widget: a spinner or
  /// Lottie builds its animated widgets a handful of elements below itself.
  static const int _animationOwnerHops = 8;

  // ---------------------------------------------------------------------------
  // Geometry & hit testing (used by the pre-action confirm pipeline)
  // ---------------------------------------------------------------------------

  /// The global on-screen [ElementRect] of [element], or null if it has
  /// no laid-out [RenderBox].
  ElementRect? rectOfElement(Element element) => _rectOf(element);

  /// The center of [element]'s on-screen rect, or null if it has no
  /// laid-out geometry.
  Offset? centerOfElement(Element element) => _rectOf(element)?.center;

  /// The visible text of [element] (its own or first descendant), or null.
  String? textOfElement(Element element) => extractText(element);

  /// Every on-screen [Scrollable] whose scroll [axis] matches, in
  /// element-tree DFS order: the `/screen` dump's `scrollIndex`, the
  /// `/swipe` `scrollIndex` and the direction-only auto-pick all read this
  /// one list. Recurses through matches so nested scrollables are also
  /// found — that lets the caller detect genuine same-axis ambiguity.
  ///
  /// A scrollable counts exactly when the dump emits it as a node. Only
  /// routes the user can see count, by the dump walk's own rule: the
  /// subtree of a route hidden behind a page, dialog, sheet or menu, or of
  /// a route that is closing, is pruned. Without it a list on a page kept
  /// underneath took a number (the visible list read `scrollIndex 3` while
  /// 0–2 never appeared) and an equal-size twin made the auto-pick
  /// ambiguous, depending on navigation history. A scrollable covered at
  /// every sample point ([_coverage]) — the page coming back while the
  /// closing page still slides over it — is not shown either, and a swipe
  /// at its centre would land on the cover.
  ///
  /// A single `ListView`/`CustomScrollView` builds exactly one
  /// `Scrollable`, so list internals don't inflate the count; a
  /// `NestedScrollView` legitimately yields more than one.
  List<Element> findVisibleScrollables(Axis axis) =>
      _visibleScrollables(axis, _routeLayers());

  /// [findVisibleScrollables] against an already-taken [layers] snapshot,
  /// so the dump numbers its scrollables by the same route state it walks.
  List<Element> _visibleScrollables(Axis axis, _RouteLayers layers) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const [];

    final screen = _screenSize;
    final matches = <Element>[];
    void visit(Element element) {
      if (layers.hidesScope(element)) return;
      final widget = element.widget;
      if (widget is Scrollable &&
          axisDirectionToAxis(widget.axisDirection) == axis &&
          _isOnScreen(element, screen) &&
          _coverage(element, screen) != _Coverage.covered) {
        matches.add(element);
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return matches;
  }

  /// Where a scroll gesture on [scrollable] can start right now: the first
  /// of its [_samplePoints] (the centre of its visible part first) where
  /// the pointer reaches it — its drag recognizer is on the hit path — and
  /// nothing painted covers it ([_pointClear]). Counting a scrollable
  /// ([findVisibleScrollables]) only says some of it is in view; its
  /// unclipped centre can be off screen (a page sliding in), under a card,
  /// or under the page still sliding away, and a swipe there moves nothing.
  ///
  /// `point` is null when no sample point qualifies; `blocker` then says
  /// what is in the way at the centre of the visible part.
  ({Offset? point, String blocker}) scrollStartOf(Element scrollable) {
    final target = scrollable.renderObject;
    final points = _samplePoints(scrollable);
    if (target == null || points.isEmpty) {
      return (point: null, blocker: 'no part of it is on screen');
    }
    final root = _rootRenderObject(target);
    if (root is! RenderView) {
      return (point: null, blocker: 'it is not attached to a view');
    }
    for (final point in points) {
      if (_pathReaches(_hitTest(root, point), target) &&
          _pointClear(target, root, point)) {
        return (point: point, blocker: '');
      }
    }
    return (point: null, blocker: _scrollBlocker(target, root, points.first));
  }

  /// What keeps a scroll gesture at [point] from [target] (see
  /// [scrollStartOf]).
  String _scrollBlocker(RenderObject target, RenderView root, Offset point) {
    if (isTransitioning) {
      return 'a route transition is running, and pointers are ignored until '
          'it ends (wait_idle waits for it)';
    }
    final hit = _hitTest(root, point);
    final top = _frontmost(hit);
    if (top == null || identical(top, root)) {
      return 'nothing receives the pointer there';
    }
    if (_pathReaches(hit, target)) {
      return 'it is covered there by ${_describeHit(top)}';
    }
    if (_isRenderAncestorOrSelf(top, target)) {
      final blocker = _silentClaimer(top, point, stopAt: target) ??
          _ignoringBetween(top, target);
      if (blocker != null) {
        return 'the pointer is swallowed by ${_describeBlocker(blocker)}';
      }
    }
    return 'the pointer is taken by ${_describeHit(top)}';
  }

  /// Whether a pointer at [point] (global/view coordinates) would reach
  /// [element] — i.e. [element]'s [RenderObject] is on the hit-test path,
  /// or is an ancestor of a render object on that path (the hit landed on
  /// a descendant of [element], which still counts as hitting it).
  ///
  /// This is the authoritative "is it actually tappable right now" check:
  /// it accounts for occlusion, z-order / overlays, clipping, and
  /// `IgnorePointer` / `AbsorbPointer` — none of which a rect test
  /// catches. Returns false (cannot confirm) when [element] has no render
  /// object, or the root render object is not a [RenderView] we can
  /// hit-test.
  bool isHittableAt(Element element, Offset point) {
    final targetRo = element.renderObject;
    if (targetRo == null) return false;

    final root = _rootRenderObject(targetRo);
    if (root is! RenderView) return false;

    final result = HitTestResult();
    root.hitTest(result, position: point);

    for (final entry in result.path) {
      final hit = entry.target;
      if (hit is RenderObject && _isRenderAncestorOrSelf(targetRo, hit)) {
        return true;
      }
    }
    return false;
  }

  /// Where a tap reaches [element] right now, or why it cannot.
  ///
  /// The centre is tried first; when something covers it (a badge, a
  /// floating button over one end of a row), the inset sample points of
  /// [_samplePoints] are tried — a person would tap the part of the target
  /// they can reach. Each point is hit-tested once.
  ///
  /// Tappability depends on whether the target is interactive:
  /// - **Interactive** targets (buttons, fields, gesture detectors) must be
  ///   reached strictly — the hit must land in the element's own render
  ///   subtree ([isHittableAt]). This is what catches a genuinely occluded
  ///   or off-screen *button*.
  /// - **Non-interactive** targets (a plain `Text`/`Icon`/`Image` used only
  ///   as a locator) are reached when the strict test passes, or when the
  ///   pixel is owned by what a person tapping that label would trigger
  ///   ([_judgeLabelPoint]): a transparent input layer stretched over it, an
  ///   empty field under its hint text, an ancestor handler. They are NOT
  ///   reached when something painted covers them (a splash, a scrim) or
  ///   when the pointer is swallowed before it gets there (an
  ///   `AbsorbPointer`, a list that is still scrolling) — the tap would do
  ///   nothing, so it must be refused, not reported as a success.
  TapReach tapReach(Element element) {
    final targetRo = element.renderObject;
    final center = centerOfElement(element);
    if (targetRo == null || center == null) {
      return const TapRefused(
        TapRefusal.notLaidOut,
        blocker: 'nothing (the target has no on-screen geometry)',
      );
    }
    final root = _rootRenderObject(targetRo);
    if (root is! RenderView) {
      return TapRefused(
        TapRefusal.notLaidOut,
        center: center,
        blocker: 'nothing (the target is not attached to a view)',
      );
    }
    // Wholly outside the screen or clipped away by its scroll view while no
    // route transition runs: no point of it can be hit (a hit test outside
    // the view or a clip reaches nothing), and saying "nothing receives
    // pointers — a transition" would send the reader to wait for one that
    // never ends. Typical: a page of a PageView that is not showing (a debug
    // overlay's hidden page). During a transition a target sliding through
    // the edge is the transition's doing, and that verdict below stands.
    final screen = _screenSize;
    final visible = _visibleRect(element, screen);
    if ((visible == null || visible.width <= 0 || visible.height <= 0) &&
        !isTransitioning) {
      final where = screen == null
          ? 'outside the screen'
          : 'outside the ${_fmtSize(screen)} screen';
      return TapRefused(
        TapRefusal.offScreen,
        center: center,
        blocker: '$where, or clipped away by the view it scrolls in — it '
            'is on a page or part of a list that is not showing',
      );
    }

    final points = [center, ..._samplePoints(element).skip(1)];
    final hits = [for (final point in points) _hitTest(root, point)];
    for (var i = 0; i < points.length; i++) {
      if (_pathReaches(hits[i], targetRo)) return TapReachable(points[i]);
    }

    final isLabel = !_isInteractiveWidget(element.widget);
    final verdicts = [
      for (var i = 0; i < points.length; i++)
        _judgeLabelPoint(targetRo, root, points[i], hits[i]),
    ];
    if (isLabel) {
      for (var i = 0; i < points.length; i++) {
        if (verdicts[i].refusal == null) return TapReachable(points[i]);
      }
    }

    // Refused: explain with the centre's verdict. An interactive target
    // whose centre a label tap would accept is still not reached itself —
    // the layer or handler that owns the pixel takes the tap instead.
    final verdict = verdicts.first;
    final refusal = verdict.refusal ??
        (verdict.ancestorTook ? TapRefusal.inputBlocked : TapRefusal.covered);
    return TapRefused(refusal, center: center, blocker: verdict.blocker());
  }

  /// [size] as `402x874` (logical pixels, whole numbers).
  static String _fmtSize(Size size) =>
      '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}';

  /// Hit-tests [root] at the global logical [point].
  HitTestResult _hitTest(RenderView root, Offset point) {
    final result = HitTestResult();
    root.hitTest(result, position: point);
    return result;
  }

  /// Whether the hit [result] lands in [target]'s render subtree — [target]
  /// itself or a descendant receives the pointer (see [isHittableAt]).
  bool _pathReaches(HitTestResult result, RenderObject target) {
    for (final entry in result.path) {
      final hit = entry.target;
      if (hit is RenderObject && _isRenderAncestorOrSelf(target, hit)) {
        return true;
      }
    }
    return false;
  }

  /// The frontmost render object in a hit [result]. The path can start with
  /// non-render targets — a TextSpan under the pointer is a hit-test target
  /// of its own — which say nothing about what is on top there.
  RenderObject? _frontmost(HitTestResult result) {
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderObject) return target;
    }
    return null;
  }

  /// Whether a tap on a non-interactive label [target] (a locator, not the
  /// control itself) may be dispatched at [point], whose hit-test [hit] does
  /// not reach the label's own subtree. `refusal` is null when it
  /// may; `blocker` names what takes the pointer there (computed on demand —
  /// naming a widget looks up its element, and only the verdict a refusal
  /// reports needs it); `ancestorTook` is true when the frontmost hit is an
  /// ancestor of [target] (the pointer stopped before reaching it).
  ///
  ///  1. Only the [RenderView] is hit → [TapRefusal.nothingHit] (a route
  ///     transition, every route scope ignoring pointers).
  ///  2. The frontmost hit is in another branch, painted over the label →
  ///     [TapRefusal.covered]; when it paints nothing (a
  ///     `Positioned.fill(InkWell)` over a card, an empty field under its
  ///     hint) or is faded out, the tap is what a person's would be: allowed.
  ///  3. The frontmost hit is an ancestor of the label → find what blocks
  ///     the label ([_silentClaimer], else [_ignoringBetween]): none means
  ///     the ancestor itself takes the tap
  ///     (an opaque handler over a child that ignores pointers): allowed. A
  ///     silent claimer painted in front (a splash in an `AbsorbPointer`) →
  ///     [TapRefusal.covered]. Any other blocker → allowed only when a tap
  ///     handler wraps it ([_handlerWraps], the
  ///     `InkWell(child: AbsorbPointer(field))` idiom), else
  ///     [TapRefusal.inputBlocked].
  ({TapRefusal? refusal, String Function() blocker, bool ancestorTook})
      _judgeLabelPoint(
    RenderObject target,
    RenderView root,
    Offset point,
    HitTestResult hit,
  ) {
    final top = _frontmost(hit);
    if (top == null || identical(top, root)) {
      return (
        refusal: TapRefusal.nothingHit,
        blocker: () => 'nothing',
        ancestorTook: false,
      );
    }

    if (!_isRenderAncestorOrSelf(top, target)) {
      final clear = _renderOpacity(top) < _visibleOpacityThreshold ||
          _isTransparentOverlay(top, target);
      return (
        refusal: clear ? null : TapRefusal.covered,
        blocker: () => _describeHit(top),
        ancestorTook: false,
      );
    }

    final claimer = _silentClaimer(top, point, stopAt: target);
    final blocker = claimer ?? _ignoringBetween(top, target);
    if (blocker == null) {
      return (
        refusal: null,
        blocker: () => _describeHit(top),
        ancestorTook: true,
      );
    }
    if (claimer != null &&
        !_isRenderAncestorOrSelf(claimer, target) &&
        _paintsOver(claimer, point)) {
      return (
        refusal: TapRefusal.covered,
        blocker: () => _describeBlocker(claimer),
        ancestorTook: true,
      );
    }
    final handler = _handlerWraps(top, blocker);
    if (handler != null) {
      return (
        refusal: null,
        blocker: () => _describeHit(handler),
        ancestorTook: true,
      );
    }
    return (
      refusal: TapRefusal.inputBlocked,
      blocker: () => _describeBlocker(blocker),
      ancestorTook: true,
    );
  }

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

  /// Minimum intersection-over-union for two matches to be layers of one
  /// control (see [_sameStackedControl]).
  static const double _stackedOverlap = 0.5;

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

  /// How far up [_controlOf] looks: a label sits a handful of elements below
  /// the InkWell / GestureDetector of the control it names.
  static const int _controlHops = 12;

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

  /// The child of [top] that took the pointer at the global [point] without
  /// recording itself on the hit path, or null when no child claims it.
  ///
  /// A render object normally joins the hit path when it or a child is hit,
  /// so when the frontmost recorded hit [top] has a child that claims the
  /// point, that child swallowed the pointer silently: an `AbsorbPointer`
  /// (`RenderAbsorbPointer.hitTest` returns true without adding itself) —
  /// a splash or loading layer, or the Navigator's absorber right after a
  /// navigation. When no child claims it, [top] took the hit itself.
  ///
  /// Children are probed in hit-test order (last painted first), stopping
  /// after the child that leads to [stopAt] when given — what is painted
  /// below the target's branch was never asked.
  RenderBox? _silentClaimer(
    RenderObject top,
    Offset point, {
    RenderObject? stopAt,
  }) {
    final children = <RenderObject>[];
    top.visitChildren(children.add);
    final onChain = stopAt == null ? null : _childTowards(top, stopAt);
    for (final child in children.reversed) {
      if (child is RenderBox && child.attached && child.hasSize) {
        final claims = child.hitTest(
          BoxHitTestResult(),
          position: child.globalToLocal(point),
        );
        if (claims) return child;
      }
      if (identical(child, onChain)) break;
    }
    return null;
  }

  /// The direct child of [ancestor] on the render path down to [node], or
  /// null when [ancestor] is not a strict ancestor of [node].
  RenderObject? _childTowards(RenderObject ancestor, RenderObject node) {
    RenderObject? current = node;
    while (current != null) {
      final parent = current.parent;
      if (identical(parent, ancestor)) return current;
      current = parent is RenderObject ? parent : null;
    }
    return null;
  }

  /// The outermost `IgnorePointer` that is ignoring between [top]
  /// (exclusive) and [target] — what keeps the pointer from a target whose
  /// ancestor [top] took the hit itself (a Scrollable ignores pointers on its
  /// content while a scroll animates or flings). Null when there is none.
  RenderObject? _ignoringBetween(RenderObject top, RenderObject target) {
    RenderObject? found;
    var current = target.parent;
    while (current is RenderObject && !identical(current, top)) {
      if ((current is RenderIgnorePointer && current.ignoring) ||
          (current is RenderSliverIgnorePointer && current.ignoring)) {
        found = current;
      }
      current = current.parent;
    }
    return found;
  }

  /// The tap handler that receives a pointer [blocker] keeps from the
  /// target, when that handler wraps [blocker] for the purpose — the
  /// `InkWell(child: AbsorbPointer(field))` idiom of a field that opens a
  /// picker. Null otherwise.
  ///
  /// The handler is the first pointer listener at or above [top] (every
  /// ancestor of the frontmost hit receives the pointer). It qualifies when
  /// it is a tap handler ([_isTapHandler]) and nothing painted sits between
  /// it and [blocker]: a handler around a whole page (a keyboard-dismissing
  /// `GestureDetector` over a loading layer) or the Navigator's raw
  /// listener does not make the blocked target tappable.
  RenderObject? _handlerWraps(RenderObject top, RenderObject blocker) {
    RenderObject? listener = top;
    while (listener != null && listener is! RenderPointerListener) {
      final parent = listener.parent;
      listener = parent is RenderObject ? parent : null;
    }
    if (listener == null || !_isTapHandler(listener)) return null;

    var current = blocker.parent;
    while (current is RenderObject) {
      if (identical(current, listener)) return listener;
      if (_paintsContent(current)) return null;
      current = current.parent;
    }
    return null;
  }

  /// Recognizers that make a gesture detector a tap handler.
  static const Set<Type> _tapRecognizers = {
    TapGestureRecognizer,
    DoubleTapGestureRecognizer,
    LongPressGestureRecognizer,
    TapAndPanGestureRecognizer,
    TapAndHorizontalDragGestureRecognizer,
  };

  /// Whether [ro] is the pointer listener of a gesture detector that
  /// recognizes taps: a `RawGestureDetector` (behind every `GestureDetector`
  /// and `InkWell`) builds `_GestureSemantics > Listener`, and registers a
  /// tap recognizer only while it has a tap callback — a disabled control
  /// does not count. A raw `Listener` (the Navigator's) or a drag-only
  /// detector (a Scrollable's) is not a tap handler.
  bool _isTapHandler(RenderObject ro) {
    if (ro is! RenderPointerListener) return false;
    final element = _elementOwning(ro);
    if (element == null) return false;
    RawGestureDetector? detector;
    var hops = 0;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is RawGestureDetector) {
        detector = widget;
        return false;
      }
      return ++hops < 2;
    });
    final gestures = detector?.gestures;
    return gestures != null && gestures.keys.any(_tapRecognizers.contains);
  }

  /// Names what keeps the pointer from the target: the Navigator right
  /// after a navigation, a list that is still scrolling, or the blocking
  /// widget with the widget it wraps, e.g. `AbsorbPointer(SplashSurface)`.
  String _describeBlocker(RenderObject blocker) {
    final element = _elementOwning(blocker);
    if (element == null) return blocker.runtimeType.toString();
    if (_hasAncestorWidget<Navigator>(element, 5)) {
      return 'the Navigator, which takes no taps for a moment after a '
          'navigation';
    }
    if (blocker is RenderIgnorePointer) {
      final scrollable = _owningScrollable(element);
      if (scrollable != null && scrollable.position.isScrollingNotifier.value) {
        return 'a list that is still scrolling (a Scrollable ignores taps '
            'on its content until the scroll settles)';
      }
    }
    final name = element.widget.runtimeType.toString();
    String? child;
    element
        .visitChildElements((c) => child ??= c.widget.runtimeType.toString());
    return child == null ? name : '$name($child)';
  }

  /// The [ScrollableState] that built [element] — the nearest one above it,
  /// when it is close enough (within [_scrollableBuildDepth] elements) to be
  /// the Scrollable's own `IgnorePointer` rather than a widget deep in one of
  /// its rows.
  ScrollableState? _owningScrollable(Element element) {
    ScrollableState? found;
    var seen = 0;
    element.visitAncestorElements((ancestor) {
      if (ancestor is StatefulElement && ancestor.state is ScrollableState) {
        found = ancestor.state as ScrollableState;
        return false;
      }
      return ++seen < _scrollableBuildDepth;
    });
    return found;
  }

  /// How far above its content `IgnorePointer` a [ScrollableState] sits in
  /// the element tree (its scope, gesture detector and semantics wrappers).
  static const int _scrollableBuildDepth = 16;

  /// Whether a widget of type [T] is among the first [hops] ancestors of
  /// [element].
  bool _hasAncestorWidget<T extends Widget>(Element element, int hops) {
    var found = false;
    var seen = 0;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is T) {
        found = true;
        return false;
      }
      return ++seen < hops;
    });
    return found;
  }

  /// Whether the layer [layer] paints something a person would see at the
  /// global [point]: not faded out, and some render object in its subtree
  /// that covers the point paints content.
  bool _paintsOver(RenderObject layer, Offset point) =>
      _renderOpacity(layer) >= _visibleOpacityThreshold &&
      _subtreePaints(layer, at: point);

  /// What a tap at the global logical [point] would reach right now — the
  /// gate for a coordinate tap (`tap_at`). `offScreen` when the point lies
  /// outside the view; `pointersIgnored` when nothing but the [RenderView]
  /// is hit (mid route transition, or empty space); `absorbedBy` names a
  /// layer that swallows the pointer before anything handles it (an
  /// `AbsorbPointer` splash, the Navigator right after a navigation) unless
  /// a tap handler wraps it ([_handlerWraps]); otherwise `target` describes
  /// the control (or labelled widget) that owns the frontmost hit, e.g.
  /// `ElevatedButton "Check In"`.
  ({
    bool offScreen,
    bool pointersIgnored,
    String? absorbedBy,
    String? target,
  }) probeTapAt(Offset point) {
    final screen = _screenSize;
    final root = WidgetsBinding.instance.rootElement?.renderObject;
    if (screen == null ||
        root is! RenderView ||
        !(Offset.zero & screen).contains(point)) {
      return (
        offScreen: true,
        pointersIgnored: false,
        absorbedBy: null,
        target: null,
      );
    }
    final top = _frontmost(_hitTest(root, point));
    if (top == null || identical(top, root)) {
      return (
        offScreen: false,
        pointersIgnored: true,
        absorbedBy: null,
        target: null,
      );
    }
    final claimer = _silentClaimer(top, point);
    final absorbed = claimer != null && _handlerWraps(top, claimer) == null;
    return (
      offScreen: false,
      pointersIgnored: false,
      absorbedBy: absorbed ? _describeBlocker(claimer) : null,
      target: _describeHit(top),
    );
  }

  /// The element that owns [ro] — the [RenderObjectElement] whose
  /// `renderObject` is [ro] — or null when no mounted element does.
  ///
  /// This is what `RenderObject.debugCreator` gives in a debug build, but the
  /// bridge runs in every build mode and `debugCreator` is only set inside an
  /// assert, so it is null in profile and release. Searched from the root
  /// element, descending only into render-owning elements whose render object
  /// is an ancestor of [ro] (component elements are always entered): the
  /// walk follows the path to [ro] instead of visiting the whole tree. When
  /// that misses — an `OverlayPortal` child sits under its portal in the
  /// element tree but under the Overlay in the render tree — every element is
  /// searched.
  Element? _elementOwning(RenderObject ro) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    return _searchOwner(root, ro, guided: true) ??
        _searchOwner(root, ro, guided: false);
  }

  Element? _searchOwner(Element root, RenderObject ro, {required bool guided}) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is RenderObjectElement) {
        final own = element.renderObject;
        if (identical(own, ro)) {
          found = element;
          return;
        }
        if (guided && !_isRenderAncestorOrSelf(own, ro)) return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// A readable name for the widget that owns the hit render object [ro]:
  /// its nearest control ([_controlOf]) with that control's label, else the
  /// creating widget's type. Found through [_elementOwning], so it reads the
  /// same in debug, profile and release builds.
  String _describeHit(RenderObject ro) {
    final element = _elementOwning(ro);
    if (element == null) return ro.runtimeType.toString();
    final owner = _controlOf(element) ?? element;
    final label = extractText(owner);
    final semantics = semanticsOf(owner);
    final name = owner.widget.runtimeType.toString();
    if (label != null && _hasAlnum(label)) return '$name "$label"';
    if (semantics != null) return '$name (semantics "$semantics")';
    return name;
  }

  /// Names what covers [element] at [point] for a "covered by X" reason:
  /// the layer that silently swallowed the pointer in front of it
  /// ([_silentClaimer]) when there is one, else the frontmost hit's type.
  String? _coverAt(Element element, Offset point) {
    final target = element.renderObject;
    if (target == null) return null;
    final root = _rootRenderObject(target);
    if (root is! RenderView) return null;
    final top = _frontmost(_hitTest(root, point));
    if (top == null) return null;
    if (_isRenderAncestorOrSelf(top, target)) {
      final claimer = _silentClaimer(top, point, stopAt: target);
      if (claimer != null) return _describeBlocker(claimer);
    }
    return top.runtimeType.toString();
  }

  // ---------------------------------------------------------------------------
  // Tree dump
  // ---------------------------------------------------------------------------

  /// Dumps the widget tree as a structured map, limited to [maxDepth].
  Map<String, dynamic> dumpTree({int maxDepth = 30}) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const {'error': 'No root element'};
    return _dumpElement(rootElement, 0, maxDepth);
  }

  /// Dumps only the widgets actually displayed on screen right now.
  ///
  /// Unlike [dumpTree], this prunes framework scaffolding
  /// (ProviderScope, MaterialApp, RestorationScope, …) and off-screen
  /// branches. A node is emitted only when it is both **on screen**
  /// (laid out, non-zero size, rect intersecting the viewport) and
  /// **meaningful** (keyed / text / interactive). Children always
  /// recurse, so a meaningful leaf under unmeaningful wrappers is still
  /// found — it just attaches to the nearest emitted ancestor, so the
  /// hierarchy that matters (a button inside a row) is preserved
  /// without the wrapper noise.
  Map<String, dynamic> dumpVisibleTree() {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const {'error': 'No root element'};

    final screen = _screenSize;
    final elements = <Map<String, dynamic>>[];

    // Per-axis scrollable lists share [findVisibleScrollables]' filter and
    // DFS order with the `/swipe` `scrollIndex` resolution and the
    // direction-only auto-pick, so the index a consumer reads from the dump
    // resolves to the same scrollable when it scrolls — they can never
    // disagree. That filter prunes hidden routes exactly as this walk does
    // ([_RouteLayers.hidesScope] below, one snapshot for both) and drops a
    // scrollable covered at every point as the node gate below does, so no
    // list takes a number the dump never shows.
    final layers = _routeLayers();
    final verticalScrollables = _visibleScrollables(Axis.vertical, layers);
    final horizontalScrollables = _visibleScrollables(Axis.horizontal, layers);
    final nthIndex = _NthIndex(this);

    // [parentLabel] is the text of the nearest already-emitted ancestor. A
    // descendant that only re-presents that label — a button's inner
    // GestureDetector/Text, or a Text's child RichText — is the same control's
    // render machinery, not a distinct element. Emitting it would flood the
    // catalog with duplicate, indistinguishable refs (one "Get Started" button
    // becoming four identical rows), so we emit the outermost node for a label
    // run and skip the inner echoes.
    void walk(
      Element element,
      List<Map<String, dynamic>> sink,
      String? parentLabel,
    ) {
      // A route hidden behind a dialog/sheet/page, or one that is closing,
      // is not on screen for the user: its whole subtree is skipped.
      if (layers.hidesScope(element)) return;

      var childSink = sink;
      var childLabel = parentLabel;
      Map<String, dynamic>? node;

      // A scroll view wrapper (ListView, PageView, …) is represented by the
      // single Scrollable it builds — the scrollable node adopts its type
      // name and key — so the wrapper itself is never emitted (a keyed
      // ListView must not become two nodes carrying the same key).
      final widget = element.widget;
      final coverage = _scrollContainerName(widget) == null &&
              _isMeaningful(element) &&
              _isOnScreen(element, screen)
          ? _coverage(element, screen)
          : _Coverage.covered;
      if (coverage != _Coverage.covered) {
        final info = extractInfo(element);
        final label = _nodeLabel(element, screen, layers);
        final nodeText = label?.text;
        if (!_isRedundant(element, info, nodeText, parentLabel)) {
          node = <String, dynamic>{'type': info.type};
          if (info.key != null) node['key'] = info.key;
          if (nodeText != null) node['text'] = nodeText;
          // A label read off a descendant text: that text's own rect, the
          // one a `near` locator anchored on this label measures rows by.
          final source = label?.source;
          final labelRect = source == null ? null : _rectOf(source);
          if (labelRect != null) node['label_rect'] = labelRect.toJson();
          final semantics = semanticsOf(element);
          if (semantics != null) node['semantics'] = semantics;
          final semanticsId = semanticsIdOf(element);
          if (semanticsId != null) node['semantics_id'] = semanticsId;
          final rect = _visibleRect(element, screen);
          if (rect != null) {
            node['rect'] = ElementRect(
              x: rect.left,
              y: rect.top,
              width: rect.width,
              height: rect.height,
            ).toJson();
          }
          if (coverage == _Coverage.partial) node['partial'] = true;
          final enabled = dumpState(element);
          if (enabled != null) node['enabled'] = enabled;
          if (info.checked != null) node['checked'] = info.checked;
          nthIndex.annotate(element, node, nodeText, semantics, semanticsId);
          if (widget is Scrollable) {
            _applyScrollInfo(
              element,
              widget,
              node,
              verticalScrollables,
              horizontalScrollables,
            );
          }
          final kids = <Map<String, dynamic>>[];
          node['children'] = kids;
          sink.add(node);
          childSink = kids;
          final trimmed = nodeText?.trim();
          if (trimmed != null && trimmed.isNotEmpty) childLabel = trimmed;
        }
      }

      element.visitChildren((child) => walk(child, childSink, childLabel));

      if (node != null && (node['children'] as List).isEmpty) {
        node.remove('children');
      }
    }

    rootElement.visitChildren((child) => walk(child, elements, null));

    return {
      if (screen != null) 'screen': {'w': screen.width, 'h': screen.height},
      'animating': isTransitioning,
      'animations': runningAnimations(),
      'elements': elements,
    };
  }

  /// Enriches a dump [node] for a [Scrollable] element: marks it
  /// `scrollable`, reports its axis, scroll metrics, and `scrollIndex` (its
  /// position among the same-axis scrollables the dump shows, in the
  /// same order the `/swipe` `scrollIndex` resolution uses), and adopts
  /// the user-facing scroll view's type name and [ValueKey] —
  /// `ListView(key: ...)` keys the ListView widget, not the inner
  /// [Scrollable] it builds.
  ///
  /// Metrics are omitted (never reported as zeros) when the scroll position
  /// is not attached or has no content dimensions yet.
  ///
  /// An extent is reported only when it is a finite number. A lazily built
  /// list with no item count (`ListView.builder` / `PageView.builder`
  /// without `itemCount`, a looping carousel) has an infinite
  /// `maxScrollExtent`, and a center-anchored endless list an infinite
  /// negative `minScrollExtent`; JSON cannot carry infinity, so those sides
  /// are stated as `scrollUnboundedForward` / `scrollUnboundedBack` instead.
  void _applyScrollInfo(
    Element element,
    Scrollable widget,
    Map<String, dynamic> node,
    List<Element> verticalScrollables,
    List<Element> horizontalScrollables,
  ) {
    final axis = axisDirectionToAxis(widget.axisDirection);
    node['scrollable'] = true;
    node['axis'] = axis == Axis.vertical ? 'vertical' : 'horizontal';

    final matches =
        axis == Axis.vertical ? verticalScrollables : horizontalScrollables;
    final index = matches.indexOf(element);
    if (index >= 0) node['scrollIndex'] = index;

    final position = _scrollPositionOf(element);
    if (position != null &&
        position.hasPixels &&
        position.hasContentDimensions) {
      final pixels = position.pixels;
      final minExtent = position.minScrollExtent;
      final maxExtent = position.maxScrollExtent;
      if (pixels.isFinite) node['scrollOffset'] = pixels;
      if (minExtent.isFinite) {
        node['minScrollExtent'] = minExtent;
      } else if (minExtent == double.negativeInfinity) {
        node['scrollUnboundedBack'] = true;
      }
      if (maxExtent.isFinite) {
        node['maxScrollExtent'] = maxExtent;
      } else if (maxExtent == double.infinity) {
        node['scrollUnboundedForward'] = true;
      }
    }

    var hops = 0;
    element.visitAncestorElements((ancestor) {
      final w = ancestor.widget;
      // Crossing another scrollable's machinery (its Scrollable or its
      // viewport) means this Scrollable has no wrapping scroll view of its
      // own — keep the plain "Scrollable" identity.
      if (w is Scrollable || ancestor.renderObject is RenderAbstractViewport) {
        return false;
      }
      final name = _scrollContainerName(w);
      if (name != null) {
        node['type'] = name;
        final key = keyOf(w);
        if (node['key'] == null && key != null) node['key'] = key;
        return false;
      }
      hops++;
      return hops < 6;
    });
  }

  /// The [ScrollPosition] of a [Scrollable] element, or null when the state
  /// has no attached position yet (first layout has not run).
  ScrollPosition? _scrollPositionOf(Element element) {
    if (element is! StatefulElement) return null;
    final state = element.state;
    if (state is! ScrollableState) return null;
    try {
      return state.position;
    } on TypeError {
      // `ScrollableState.position` null-check-throws before a position is
      // attached (no layout yet).
      return null;
    }
  }

  /// The user-facing scroll view name for [widget] — the wrapper whose inner
  /// [Scrollable] represents it in the dump — or null when [widget] is not a
  /// scroll view wrapper.
  String? _scrollContainerName(Widget widget) {
    if (widget is ListView) return 'ListView';
    if (widget is GridView) return 'GridView';
    if (widget is CustomScrollView) return 'CustomScrollView';
    // Any other ScrollView subclass (custom BoxScrollViews, etc.).
    if (widget is ScrollView) return widget.runtimeType.toString();
    if (widget is SingleChildScrollView) return 'SingleChildScrollView';
    if (widget is PageView) return 'PageView';
    if (widget is ListWheelScrollView) return 'ListWheelScrollView';
    if (widget is NestedScrollView) return 'NestedScrollView';
    if (widget is ReorderableListView) return 'ReorderableListView';
    // CarouselView is matched by name: it is not available on every Flutter
    // version this package supports, so an `is` check cannot be used.
    final name = widget.runtimeType.toString();
    return name == 'CarouselView' ? name : null;
  }

  /// Whether [element] would only duplicate an ancestor already in the dump —
  /// a render primitive carrying no addressable identity of its own — so it can
  /// be skipped to keep each on-screen control to a single node.
  ///
  /// Keyed, enabled/checked (interactive), and icon/image nodes always survive.
  /// A pure [Text]/[RichText]/[EditableText] is redundant when its text echoes
  /// the nearest emitted ancestor's label (the inner `Text`/`RichText` of a
  /// button or a `Text`), or when it carries no text at all (an empty leaf).
  bool _isRedundant(
    Element element,
    ElementInfo info,
    String? nodeText,
    String? parentLabel,
  ) {
    if (info.key != null || info.enabled != null || info.checked != null) {
      return false;
    }
    final widget = element.widget;
    if (widget is Icon || widget is Image) return false;
    final text = nodeText?.trim() ?? '';
    if (text.isEmpty) {
      // An empty EditableText is the input machinery of a TextField /
      // CupertinoTextField that is already a node of its own; a bare one
      // (a custom field built straight on EditableText) has no such
      // ancestor and must survive, or the empty field vanishes from the
      // screen readout until it has a value.
      if (widget is EditableText) return _hasFieldAncestor(element);
      return widget is Text || widget is RichText;
    }
    final parent = parentLabel?.trim() ?? '';
    return parent.isNotEmpty && text == parent;
  }

  /// Whether [element] sits inside a [TextField] or [CupertinoTextField] —
  /// the wrappers that are emitted as the field's own dump node.
  bool _hasFieldAncestor(Element element) {
    var found = false;
    element.visitAncestorElements((ancestor) {
      final w = ancestor.widget;
      if (w is TextField || w is CupertinoTextField) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  // ---------------------------------------------------------------------------
  // Element info extraction
  // ---------------------------------------------------------------------------

  /// Extracts full info from an [Element], including type, key, text,
  /// position, enabled/checked state.
  ///
  /// Visible for testing.
  ElementInfo extractInfo(Element element) {
    final widget = element.widget;

    return ElementInfo(
      type: widget.runtimeType.toString(),
      key: keyOf(widget),
      text: extractText(element),
      rect: _rectOf(element),
      enabled: _extractEnabled(widget),
      checked: _extractChecked(widget),
    );
  }

  /// Global on-screen rect of [element], or null if it has no laid-out
  /// [RenderBox].
  ElementRect? _rectOf(Element element) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    // A detached render object has no transform to the screen (and
    // `localToGlobal` would throw an Error, not an Exception).
    if (!renderObject.attached) return null;
    final offset = renderObject.localToGlobal(Offset.zero);
    return ElementRect(
      x: offset.dx,
      y: offset.dy,
      width: renderObject.size.width,
      height: renderObject.size.height,
    );
  }

  /// Extracts text content from an element or its first text-bearing descendant.
  ///
  /// Visible for testing.
  String? extractText(Element element) {
    final own = _widgetOwnText(element.widget);
    if (own != null) return own;

    String? found;
    element.visitChildren((child) {
      if (found != null) return;
      found = extractText(child);
    });
    return found;
  }

  /// Text to attach to a node in [dumpVisibleTree]: the element's own
  /// text for [Text]/[EditableText]; for button-like widgets, the
  /// label its subtree shows ([_subtreeLabel] — so a button still reads
  /// "Continue" through Material internals); null for structural
  /// wrappers (so `LayoutId`/`KeyedSubtree`/`InheritedWidget` don't
  /// inherit a descendant's text).
  String? _nodeText(Element element, Size? screen, _RouteLayers layers) =>
      _nodeLabel(element, screen, layers)?.text;

  /// [_nodeText] plus the descendant that supplied it — null [source] when
  /// the text is the element's own. The source's rect is what a `near`
  /// locator anchored on this label resolves against
  /// ([GestureDispatcher.resolveNearActable] finds the text element
  /// itself), so the dump reports it as `label_rect`.
  ({String text, Element? source})? _nodeLabel(
    Element element,
    Size? screen,
    _RouteLayers layers,
  ) {
    final own = _widgetOwnText(element.widget);
    if (own != null) return (text: own, source: null);

    // Only interactive widgets carry a "label"; structural wrappers
    // return null so they don't bubble a descendant's text.
    if (!_isButtonLike(element.widget)) return null;
    return _subtreeLabel(element, screen, layers);
  }

  /// The label a button-like [element] shows, and the descendant showing
  /// it: among the descendant texts the user can see — on screen
  /// ([_isOnScreen]) and not on a hidden route — the first, in tree order,
  /// that contains a letter; the first of them when none does.
  ///
  /// Words name a control; a bare number beside them is its state. A bag
  /// button drawn as `[2] Bag · 73.48` is "Bag · 73.48", not its item-count
  /// badge "2" — a label that changes with the cart, so a test recorded
  /// against it fails as soon as the cart holds something else. A control
  /// that shows only digits or a glyph (a "3" tip chip) keeps that text.
  ///
  /// The search never enters a [_isLabelBoundary]. A detector wrapped
  /// around a whole page, list or navigator (an app-wide
  /// keyboard-dismiss `GestureDetector`) is a container, not a button:
  /// labelling it with whatever text comes first inside — a page kept
  /// under the current one, the first row of a list — reports text that
  /// is not on screen, and makes the dump drop the real control carrying
  /// that text as an echo of its parent's label.
  ({String text, Element source})? _subtreeLabel(
    Element element,
    Size? screen,
    _RouteLayers layers,
  ) {
    ({String text, Element source})? first;
    ({String text, Element source})? worded;
    void visit(Element child) {
      if (worded != null) return;
      final w = child.widget;
      if (_isLabelBoundary(w) || layers.hidesScope(child)) return;
      final own = _widgetOwnText(w);
      if (own != null) {
        // A text the user cannot see is no label; its subtree is the same
        // text's render machinery, so the search moves on to its siblings.
        if (_isOnScreen(child, screen) && !layers.hides(child)) {
          final found = (text: own, source: child);
          first ??= found;
          if (_hasLetter(own)) worded = found;
        }
        return;
      }
      child.visitChildren(visit);
    }

    element.visitChildren(visit);
    return worded ?? first;
  }

  /// Whether [s] contains a letter in any script — what makes a text a
  /// name rather than a count, a price or an icon glyph.
  bool _hasLetter(String s) => s.contains(RegExp(r'\p{L}', unicode: true));

  /// Whether a label search ([_subtreeLabel], [semanticsOf]) must stop at
  /// [widget]: a scroll view or a navigator holds content of its own (rows,
  /// pages), never the label of a control wrapped around it. A field's
  /// value is read off its [EditableText] above the field's own
  /// [Scrollable], so a field keeps its text.
  bool _isLabelBoundary(Widget widget) =>
      widget is Scrollable || widget is Navigator || widget is Overlay;

  /// Whether [widget] reads as a button: a Material button, or an
  /// `InkWell`/`GestureDetector` acting as one.
  bool _isButtonLike(Widget widget) =>
      widget is GestureDetector ||
      widget is InkWell ||
      widget.runtimeType.toString().endsWith('Button');

  // ---------------------------------------------------------------------------
  // Control state (enabled / disabled)
  // ---------------------------------------------------------------------------
  //
  // One rule answers "is this control enabled?" for the `/screen` dump (the
  // catalog's `(disabled)`), the `near` shell check and the state assertions,
  // so a catalog line and an `expect_disabled` on it can never disagree.

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

  /// How far up [stateOwner] follows a label run: a Material button's label
  /// sits a dozen or more elements below the button widget itself.
  static const int _stateRunHops = 40;

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

  /// How deep [_wrappedControl] follows a single-child chain.
  static const int _wrapperChainDepth = 32;

  /// The label that ties a **text** label run together: the element's own
  /// text, or — for a control or other meaningful widget — the first text
  /// it shows (what the dump labels its node with). Normalized like every
  /// text match.
  String? textRunLabel(Element element) {
    final own = _widgetOwnText(element.widget);
    if (own != null) return normalizeText(own);
    final w = element.widget;
    if (_elementState(element) != null || _isButtonLike(w) || w is ListTile) {
      final text = extractText(element);
      return text == null ? null : normalizeText(text);
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
    final key = keyOf(owner.widget);
    final text = extractText(owner);
    final parts = <String>[type];
    if (key != null) parts.add('key "$key"');
    if (text != null && _hasAlnum(text)) {
      parts.add('"${normalizeText(text)}"');
    } else {
      final semantics = semanticsOf(owner);
      if (semantics != null) parts.add('(semantics "$semantics")');
    }
    return parts.join(' ');
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  ElementInfo? _findWhere(bool Function(Element) test) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return null;

    ElementInfo? result;
    void visitor(Element element) {
      if (result != null) return;
      if (test(element)) {
        result = extractInfo(element);
        return;
      }
      element.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);
    return result;
  }

  /// Like [_findWhere] but returns the matched [Element] itself.
  Element? _findElementWhere(bool Function(Element) test) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return null;

    Element? result;
    void visitor(Element element) {
      if (result != null) return;
      if (test(element)) {
        result = element;
        return;
      }
      element.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);
    return result;
  }

  /// Like [_findElementWhere] but returns every matching [Element].
  ///
  /// Does not descend into a matched element's own subtree (mirroring
  /// [_findWhere]'s early-return), so a [Text] and the [RichText] it
  /// builds internally — which share the same visible string — are not
  /// both counted as separate matches.
  List<Element> _findAllElementsWhere(bool Function(Element) test) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const [];

    final results = <Element>[];
    void visitor(Element element) {
      if (test(element)) {
        results.add(element);
        return; // do not descend into a match's own subtree
      }
      element.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);
    return results;
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

  /// Visibility of a locator's [matches] ([desc] names the locator in
  /// reasons). Visible when any match is visible — or, with [nth], when
  /// the nth distinct visible match exists (reading order; stacked copies
  /// of one control count once). When nothing is visible the result
  /// carries the reason for the first match in reading order, so a failed
  /// wait or assertion says exactly why ("… is at opacity 0.00").
  VisibilityResult _checkVisibility(
    List<Element> matches,
    String desc, {
    int? nth,
  }) {
    if (matches.isEmpty) {
      return VisibilityResult(
        exists: false,
        visible: false,
        reason: 'no widget matches $desc',
      );
    }

    final ordered = inReadingOrder(matches);
    if (ordered.isEmpty) {
      return VisibilityResult(
        exists: true,
        visible: false,
        info: extractInfo(matches.first),
        reason: '$desc exists but is not laid out',
      );
    }

    final (:visible, :firstHidden) = _scanVisible(ordered, desc);

    if (nth != null) {
      if (nth >= 0 && nth < visible.length) return visible[nth].$2;
      return VisibilityResult(
        exists: true,
        visible: false,
        onScreen: visible.isNotEmpty,
        info: extractInfo(ordered.first),
        reason: 'nth $nth is out of range for $desc: ${visible.length} '
            'visible match(es)'
            '${firstHidden?.reason != null ? ' (${firstHidden!.reason})' : ''}',
      );
    }
    if (visible.isNotEmpty) return visible.first.$2;
    return firstHidden!;
  }

  /// The matches a person can see, in reading order, stacked copies of one
  /// control (a nav icon's two glyph layers, a cross-fading label) counted
  /// once — **the one list every `nth` indexes**: visibility waits and
  /// assertions, taps, state assertions and the `/screen` dump's
  /// `text_nth`/`semantics_nth`. An action then checks what it needs of the
  /// chosen match (a tap: that it is reachable) and fails loudly when that
  /// does not hold, rather than silently counting differently.
  List<Element> visibleMatches(List<Element> matches) => [
        for (final v in _scanVisible(inReadingOrder(matches), '').visible) v.$1,
      ];

  /// The visible matches among [ordered] (already in reading order) with
  /// their results, stacked copies merged, and the first hidden match's
  /// result — the reason given when nothing is visible.
  ({List<(Element, VisibilityResult)> visible, VisibilityResult? firstHidden})
      _scanVisible(List<Element> ordered, String desc) {
    final screen = _screenSize;
    final layers = _routeLayers();
    final visible = <(Element, VisibilityResult)>[];
    VisibilityResult? firstHidden;
    for (final element in ordered) {
      final result = _visibilityOf(element, screen, layers, desc);
      if (!result.visible) {
        firstHidden ??= result;
      } else if (!visible.any((v) => _sameStackedControl(v.$1, element))) {
        visible.add((element, result));
      }
    }
    return (visible: visible, firstHidden: firstHidden);
  }

  /// Whether [element] is visible to a person looking at the screen — the
  /// single predicate shared by the `/screen` dump and every visibility
  /// wait/assertion, so the two can never disagree:
  ///
  ///  1. laid out and not under an active `Offstage`;
  ///  2. painted at ≥ [_visibleOpacityThreshold] effective opacity;
  ///  3. a non-empty rect after clipping to the screen and every clipping
  ///     ancestor;
  ///  4. not on a route hidden by a modal route above it, or being closed
  ///     ([_RouteLayers]);
  ///  5. not covered at every sample point ([_coverage]).
  VisibilityResult _visibilityOf(
    Element element,
    Size? screen,
    _RouteLayers layers,
    String desc,
  ) {
    final info = extractInfo(element);
    VisibilityResult hidden(String why, {bool onScreen = false}) =>
        VisibilityResult(
          exists: true,
          visible: false,
          onScreen: onScreen,
          obstructed: onScreen,
          info: info,
          reason: '$desc exists but $why',
        );

    if (info.rect == null || screen == null) return hidden('is not laid out');
    if (_isOffstage(element)) {
      return hidden('is offstage (an inactive tab or a page kept alive '
          'underneath)');
    }
    final opacity = _effectiveOpacity(element);
    if (opacity < _visibleOpacityThreshold) {
      return hidden('is at opacity ${opacity.toStringAsFixed(2)}');
    }
    final rect = _visibleRect(element, screen);
    if (rect == null || rect.width <= 0 || rect.height <= 0) {
      return hidden('is off-screen or clipped out of view');
    }
    if (layers.hides(element)) {
      return hidden(
        'is on a route hidden behind a dialog/sheet/page, or on a route '
        'that is closing',
        onScreen: true,
      );
    }
    if (_coverage(element, screen) == _Coverage.covered) {
      final center = rect.center;
      final blocker = _coverAt(element, center);
      return hidden(
        'is covered by ${blocker ?? 'another widget'} at every point',
        onScreen: true,
      );
    }
    return VisibilityResult(
      exists: true,
      visible: true,
      onScreen: true,
      info: info,
    );
  }

  /// Whether [element] is not covered at every sample point — the
  /// occlusion half of the dump's visibility gate (see [_coverage]).
  bool _isUnobstructed(Element element) =>
      _coverage(element, _screenSize) != _Coverage.covered;

  /// How much of [element] a person can see past whatever is painted on
  /// top of it, sampled at [_samplePoints] (its centre and four points
  /// inset 25% into its visible rect).
  ///
  /// A point is clear when the frontmost hit there is in the element's own
  /// render lineage (itself, a descendant, or an ancestor behind it — unless
  /// a layer in front swallowed the pointer silently and paints there, see
  /// [_pointClear]), or is an input layer that paints nothing at that point
  /// ([_isTransparentOverlay] — a `Positioned.fill(InkWell)` over a card, a
  /// page-wide translucent detector whose banner is elsewhere). Clear at every
  /// point → [_Coverage.clear]; at none → [_Coverage.covered]; otherwise
  /// [_Coverage.partial], which the dump reports as `partial: true` instead
  /// of silently dropping the element.
  ///
  /// Hit-test based, so a pointer-transparent (`IgnorePointer`) layer
  /// painted on top is not detected; real bars and modals, and
  /// `AbsorbPointer` layers (a splash held over the page), are.
  _Coverage _coverage(Element element, Size? screen) {
    final targetRo = element.renderObject;
    if (targetRo == null) return _Coverage.clear;
    final root = _rootRenderObject(targetRo);
    if (root is! RenderView) return _Coverage.clear;

    final points = _samplePoints(element, screen: screen);
    if (points.isEmpty) return _Coverage.clear;
    var clear = 0;
    for (final point in points) {
      if (_pointClear(targetRo, root, point)) clear++;
    }
    if (clear == points.length) return _Coverage.clear;
    return clear == 0 ? _Coverage.covered : _Coverage.partial;
  }

  /// The points [_coverage] and [tapReach] sample on [element]:
  /// its visible rect's centre first, then four points inset 25% towards
  /// each corner. Empty when the element has no visible geometry.
  List<Offset> _samplePoints(Element element, {Size? screen}) {
    final rect = _visibleRect(element, screen ?? _screenSize);
    if (rect == null || rect.width <= 0 || rect.height <= 0) return const [];
    final dx = rect.width / 4;
    final dy = rect.height / 4;
    return [
      rect.center,
      rect.topLeft.translate(dx, dy),
      rect.topRight.translate(-dx, dy),
      rect.bottomLeft.translate(dx, -dy),
      rect.bottomRight.translate(-dx, -dy),
    ];
  }

  bool _pointClear(RenderObject target, RenderView root, Offset point) {
    final top = _frontmost(_hitTest(root, point));
    if (top == null) return true;
    if (_isRenderAncestorOrSelf(target, top)) return true;
    if (_isRenderAncestorOrSelf(top, target)) {
      // The pointer stopped at an ancestor. Either the ancestor took it
      // itself (nothing is over the target), or a child of it swallowed it
      // without joining the hit path: an `AbsorbPointer` wrapping the
      // target's branch absorbs input but hides nothing; one painted in
      // front of it (a splash, a loading layer) covers the target when it
      // paints there.
      final claimer = _silentClaimer(top, point, stopAt: target);
      if (claimer == null || _isRenderAncestorOrSelf(claimer, target)) {
        return true;
      }
      return !_paintsOver(claimer, point);
    }
    // A faded-out layer on top (Opacity 0, a finished fade-out kept for
    // layout) still takes the hit but paints nothing over the target.
    if (_renderOpacity(top) < _visibleOpacityThreshold) return true;
    return _isTransparentOverlay(top, target, at: point);
  }

  /// Whether the branch that won the hit-test at a point over [target]
  /// paints nothing there — it is only an input layer (a
  /// `Positioned.fill(InkWell)` stretched over a card, a `GestureDetector`
  /// catching taps for a whole tile). Checks the hit object's own subtree
  /// and its ancestors up to (excluding) the first one that also contains
  /// [target]; any painting render object in that branch is an occluder.
  ///
  /// With [at] (the coverage check, [_pointClear]) only what the hit
  /// object's subtree paints at that point counts: a page-wide tap layer
  /// that draws a banner at the top covers nothing at a point below it.
  /// Without it (the tap gate, [_judgeLabelPoint]) anything the branch
  /// paints anywhere refuses the label tap — that layer's own handler, not
  /// the label's control, would take a tap there, so being visible at a
  /// point does not make a label tappable at it.
  bool _isTransparentOverlay(
    RenderObject top,
    RenderObject target, {
    Offset? at,
  }) {
    if (_subtreePaints(top, at: at)) return false;

    var current = top.parent;
    while (current is RenderObject) {
      if (_isRenderAncestorOrSelf(current, target)) return true;
      if (_paintsContent(current)) return false;
      current = current.parent;
    }
    return false;
  }

  /// Whether any render object in [root]'s subtree paints content
  /// ([_paintsContent]). With [at], boxes whose global bounds do not
  /// contain that point are skipped with their subtrees — only what is
  /// painted at the point counts. Gives up after [_transparentScanBudget]
  /// render objects and then reports that it paints: a clear view that was
  /// not proven is never claimed.
  bool _subtreePaints(RenderObject root, {Offset? at}) {
    var budget = _transparentScanBudget;
    var paints = false;
    void scan(RenderObject ro) {
      if (paints) return;
      if (budget-- <= 0) {
        paints = true;
        return;
      }
      if (at != null && ro is RenderBox && ro.hasSize) {
        final bounds = ro.localToGlobal(Offset.zero) & ro.size;
        if (!bounds.contains(at)) return;
      }
      if (_paintsContent(ro)) {
        paints = true;
        return;
      }
      ro.visitChildren(scan);
    }

    scan(root);
    return paints;
  }

  /// Render objects [_subtreePaints] inspects before giving up.
  static const int _transparentScanBudget = 64;

  /// Whether [ro] paints visible content of its own (text, images,
  /// decoration, fill, platform views…) rather than only passing pointers
  /// or layout through.
  bool _paintsContent(RenderObject ro) {
    // An empty field paints only its cursor: the hint text under it shows
    // through, and a tap on the hint is a tap on the field.
    if (ro is RenderEditable) {
      return ro.text?.toPlainText().isNotEmpty ?? false;
    }
    if (ro is RenderParagraph ||
        ro is RenderImage ||
        ro is RenderPhysicalModel ||
        ro is RenderPhysicalShape ||
        ro is RenderBackdropFilter ||
        ro is TextureBox ||
        ro is PlatformViewRenderBox) {
      return true;
    }
    if (ro is RenderDecoratedBox) return true;
    if (ro is RenderCustomPaint) {
      return _painterPaints(ro.painter) || _painterPaints(ro.foregroundPainter);
    }
    final name = ro.runtimeType.toString();
    return name.contains('ColoredBox') ||
        name.contains('UiKitView') ||
        name.contains('AndroidView');
  }

  /// Whether [painter] draws anything. Material wraps every surface —
  /// including a transparent one around an `InkWell` overlay — in a
  /// shape-border painter; a border with zero stroke dimensions (the
  /// default `BorderSide.none`) draws nothing. The painter class is private
  /// to the framework, so its `border` is read dynamically.
  bool _painterPaints(CustomPainter? painter) {
    if (painter == null) return false;
    if (painter.runtimeType.toString() == '_ShapeBorderPainter') {
      final Object? border = (painter as dynamic).border;
      if (border is ShapeBorder) return border.dimensions != EdgeInsets.zero;
    }
    return true;
  }

  /// A snapshot of which routes are hidden right now (see [_RouteLayers]).
  _RouteLayers _routeLayers() {
    final routes = _modalRoutes();
    final hidden = <ModalRoute<Object?>>{};
    for (var i = 0; i < routes.length; i++) {
      final route = routes[i];
      if (route.animation?.status == AnimationStatus.reverse) {
        hidden.add(route); // being closed
        continue;
      }
      for (var j = i + 1; j < routes.length; j++) {
        final above = routes[j];
        if (!identical(above.navigator, route.navigator)) continue;
        final status = above.animation?.status;
        final shown = status == AnimationStatus.forward ||
            status == AnimationStatus.completed;
        if (shown && _hidesRoutesBelow(above)) {
          hidden.add(route);
          break;
        }
      }
    }
    return _RouteLayers(hidden);
  }

  /// Whether [route], once shown, hides the routes below it in its
  /// navigator from a user: an opaque page, or any popup (dialog, bottom
  /// sheet, menu) or barrier-carrying route — its barrier takes every
  /// pointer outside it and dims what is underneath.
  bool _hidesRoutesBelow(ModalRoute<Object?> route) =>
      route.opaque || route is PopupRoute || route.barrierColor != null;

  /// The viewport size in **logical** pixels — the same coordinate space as
  /// element rects (which come from `RenderBox.localToGlobal`, logical px).
  ///
  /// The root render object's `paintBounds` are in *physical* pixels, so using
  /// them here made the on-screen test compare logical rects against a viewport
  /// ~`devicePixelRatio`× too tall, letting below-the-fold widgets pass as
  /// "visible". Deriving from the [FlutterView] (`physicalSize / dpr`) keeps
  /// both sides logical.
  Size? get _screenSize {
    final root = WidgetsBinding.instance.rootElement?.renderObject;
    if (root is! RenderView) return null;
    final view = root.flutterView;
    if (view.devicePixelRatio <= 0) return null;
    return view.physicalSize / view.devicePixelRatio;
  }

  /// Whether [element] is laid out with a non-zero size, its rect is still
  /// non-empty after clipping to the [screen] viewport **and every clipping
  /// ancestor** (scroll viewports / `ClipRect`s), and it is not hidden under an
  /// `Offstage` (e.g. inactive tab / `Visibility(maintainState: true)`).
  ///
  /// Clipping to ancestors — not just the screen — is what prunes a widget
  /// scrolled out of a *sub-viewport* (a list between a header and footer)
  /// whose laid-out rect still happens to fall within the full screen bounds.
  bool _isOnScreen(Element element, Size? screen) {
    if (_isOffstage(element)) return false;
    // Faded-out widgets (a cross-fading AnimatedSwitcher page, a
    // FadeTransition/Opacity(0) kept for layout) are laid out and hit-testable
    // but invisible — the user can't see them, so they are not "on screen".
    if (_effectiveOpacity(element) < _visibleOpacityThreshold) return false;
    final r = _visibleRect(element, screen);
    return r != null && r.width > 0 && r.height > 0;
  }

  /// Below this painted opacity a widget is treated as invisible. ~0.05 keeps
  /// clearly-visible widgets (including a page fading *in* past ~5%) and drops
  /// only the near-invisible faded-out layers.
  static const double _visibleOpacityThreshold = 0.05;

  /// Effective painted opacity of [element]: the product of every ancestor
  /// opacity ([Opacity] via [RenderOpacity], and [FadeTransition]/animated
  /// opacity via [RenderAnimatedOpacity]). ~0 means the user cannot see it even
  /// though it is laid out and hit-testable.
  double _effectiveOpacity(Element element) {
    final ro = element.renderObject;
    return ro == null ? 1.0 : _renderOpacity(ro);
  }

  /// Painted opacity of render object [start]: the product of every
  /// [RenderOpacity] / [RenderAnimatedOpacity] from it up to the root.
  double _renderOpacity(RenderObject start) {
    var opacity = 1.0;
    RenderObject? ro = start;
    while (ro != null && opacity > 0) {
      if (ro is RenderOpacity) {
        opacity *= ro.opacity;
      } else if (ro is RenderAnimatedOpacity) {
        opacity *= ro.opacity.value;
      }
      final parent = ro.parent;
      ro = parent is RenderObject ? parent : null;
    }
    return opacity;
  }

  /// The element's global rect intersected with the [screen] viewport and the
  /// bounds of every clipping ancestor. Null when the element has no laid-out
  /// [RenderBox]; a zero/negative-area result means it is fully clipped away
  /// (off-screen, scrolled out of a sub-viewport, or hidden behind a clip).
  Rect? _visibleRect(Element element, Size? screen) {
    final ro = element.renderObject;
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
    var rect = ro.localToGlobal(Offset.zero) & ro.size;
    if (screen != null) rect = rect.intersect(Offset.zero & screen);

    var parent = ro.parent;
    while (parent is RenderObject) {
      if (_clips(parent) &&
          parent is RenderBox &&
          parent.hasSize &&
          parent.attached) {
        rect = rect.intersect(parent.localToGlobal(Offset.zero) & parent.size);
      }
      parent = parent.parent;
    }
    return rect;
  }

  /// Whether [ro] clips its descendants to its own bounds — a scroll viewport
  /// or an explicit clip. Used to prune content scrolled/clipped out of view.
  bool _clips(RenderObject ro) =>
      ro is RenderAbstractViewport ||
      ro is RenderClipRect ||
      ro is RenderClipRRect ||
      ro is RenderClipOval ||
      ro is RenderClipPath;

  /// Walks up the render tree from [ro] to the root render object
  /// (typically the [RenderView]).
  RenderObject _rootRenderObject(RenderObject ro) {
    var current = ro;
    while (true) {
      final parent = current.parent;
      if (parent is RenderObject) {
        current = parent;
      } else {
        return current;
      }
    }
  }

  /// Whether [ancestor] is [node] itself or an ancestor of [node] in the
  /// render tree.
  bool _isRenderAncestorOrSelf(RenderObject ancestor, RenderObject node) {
    RenderObject? current = node;
    while (current != null) {
      if (identical(current, ancestor)) return true;
      final parent = current.parent;
      current = parent is RenderObject ? parent : null;
    }
    return false;
  }

  /// Whether any render ancestor is an `Offstage` that is currently
  /// offstage (laid out but not painted / hit-testable).
  bool _isOffstage(Element element) {
    RenderObject? ro = element.renderObject;
    while (ro != null) {
      if (ro is RenderOffstage && ro.offstage) return true;
      final parent = ro.parent;
      ro = parent is RenderObject ? parent : null;
    }
    return false;
  }

  /// Whether [element] is worth surfacing in the visible dump: a
  /// keyed, text-bearing, or interactive widget — not framework
  /// scaffolding or pure layout wrappers.
  bool _isMeaningful(Element element) {
    final widget = element.widget;
    if (widget is Text ||
        widget is RichText ||
        widget is EditableText ||
        widget is Icon ||
        widget is Image ||
        widget is GestureDetector ||
        widget is InkWell) {
      return true;
    }
    if (widget is Scrollable) return true;
    if (keyOf(widget) != null) return true;
    if (_extractEnabled(widget) != null) return true;
    if (_extractChecked(widget) != null) return true;
    return widget.runtimeType.toString().endsWith('Button');
  }

  Map<String, dynamic> _dumpElement(Element element, int depth, int maxDepth) {
    final node = <String, dynamic>{
      'type': element.widget.runtimeType.toString(),
    };

    final key = keyOf(element.widget);
    if (key != null) node['key'] = key;

    final text = extractText(element);
    if (text != null) node['text'] = text;

    final renderObject = element.renderObject;
    if (renderObject is RenderBox && renderObject.hasSize) {
      // A detached render object has no position on screen.
      if (renderObject.attached) {
        final offset = renderObject.localToGlobal(Offset.zero);
        node['rect'] = {
          'x': offset.dx,
          'y': offset.dy,
          'w': renderObject.size.width,
          'h': renderObject.size.height,
        };
      }
    }

    if (depth < maxDepth) {
      final children = <Map<String, dynamic>>[];
      element.visitChildren((child) {
        children.add(_dumpElement(child, depth + 1, maxDepth));
      });
      if (children.isNotEmpty) {
        node['children'] = children;
      }
    }

    return node;
  }

  bool? _extractEnabled(Widget widget) {
    if (widget is TextField) return widget.enabled ?? true;
    if (widget is CupertinoTextField) return widget.enabled;
    if (widget is ElevatedButton) return widget.onPressed != null;
    if (widget is TextButton) return widget.onPressed != null;
    if (widget is OutlinedButton) return widget.onPressed != null;
    if (widget is FilledButton) return widget.onPressed != null;
    if (widget is IconButton) return widget.onPressed != null;
    if (widget is Switch) return widget.onChanged != null;
    if (widget is Checkbox) return widget.onChanged != null;
    return null;
  }

  bool? _extractChecked(Widget widget) {
    if (widget is Checkbox) return widget.value;
    if (widget is Switch) return widget.value;
    return null;
  }
}

/// How much of an element is uncovered (see [TreeWalker._coverage]).
enum _Coverage { clear, partial, covered }

/// Which [ModalRoute]s are hidden from the user at one instant: a route
/// that is closing (its primary animation reversing), or one with a
/// shown opaque/popup/barrier route above it in the same navigator. An
/// element is hidden when any route enclosing it is — a dialog on the
/// root navigator hides a nested navigator's pages too.
class _RouteLayers {
  _RouteLayers(this._hidden);

  final Set<ModalRoute<Object?>> _hidden;

  /// Whether [element] sits on a hidden route.
  bool hides(Element element) {
    if (_hidden.isEmpty) return false;
    var hidden = false;
    element.visitAncestorElements((ancestor) {
      final route = TreeWalker._routeOfScope(ancestor);
      if (route != null && _hidden.contains(route)) {
        hidden = true;
        return false;
      }
      return true;
    });
    return hidden;
  }

  /// Whether the route owning the `_ModalScopeStatus` [scope] is hidden.
  bool hidesScope(Element scope) {
    final route = TreeWalker._routeOfScope(scope);
    return route != null && _hidden.contains(route);
  }
}

/// Computes, for dump nodes, the `nth` a text or semantics locator needs
/// to reach them — the one visible-match list every route indexes
/// ([TreeWalker.visibleMatches]) — so a catalog ref resolves to exactly
/// the widget it names even when its label repeats on screen.
///
/// Emitted as `text_nth`/`text_matches`, `semantics_nth`/
/// `semantics_matches` and `semantics_id_nth`/`semantics_id_matches`, only
/// when the label has more than one visible match and the node is one of
/// them. An identifier is a `semantics` locator target too, so its
/// candidates are exactly what that locator resolves to. Candidate lists
/// are computed once per label per dump.
class _NthIndex {
  _NthIndex(this._walker);

  final TreeWalker _walker;
  final Map<String, List<Element>> _byText = {};
  final Map<String, List<Element>> _bySemantics = {};

  void annotate(
    Element node,
    Map<String, dynamic> out,
    String? text,
    String? semantics,
    String? semanticsId,
  ) {
    if (text != null && text.isNotEmpty) {
      final candidates = _byText.putIfAbsent(text, () {
        final matches = _walker.findAllElementsByText(text);
        return matches.length > 1 ? _walker.visibleMatches(matches) : const [];
      });
      _emit(node, out, 'text', candidates);
    }
    if (semantics != null) {
      _emit(node, out, 'semantics', _semanticsCandidates(semantics));
    }
    if (semanticsId != null) {
      _emit(node, out, 'semantics_id', _semanticsCandidates(semanticsId));
    }
  }

  /// The visible matches of a `semantics` locator [target] (label or
  /// identifier), or none when it matches at most one widget.
  List<Element> _semanticsCandidates(String target) =>
      _bySemantics.putIfAbsent(target, () {
        final matches = _walker.findAllElementsBySemantics(target);
        return matches.length > 1 ? _walker.visibleMatches(matches) : const [];
      });

  void _emit(
    Element node,
    Map<String, dynamic> out,
    String prefix,
    List<Element> candidates,
  ) {
    if (candidates.length < 2) return;
    final index = candidates.indexWhere(
      (c) => _related(c, node),
    );
    if (index < 0) return;
    out['${prefix}_nth'] = index;
    out['${prefix}_matches'] = candidates.length;
  }

  /// Whether [a] and [b] are the same element or one encloses the other —
  /// a button node's label is a Text leaf inside it; a node's semantics
  /// may come from a Tooltip around it.
  static bool _related(Element a, Element b) =>
      _encloses(a, b) || _encloses(b, a);

  static bool _encloses(Element ancestor, Element node) {
    if (identical(ancestor, node)) return true;
    var found = false;
    node.visitAncestorElements((e) {
      if (identical(e, ancestor)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }
}

/// The control a state assertion checks, or why there is none
/// ([TreeWalker.resolveStateTarget]).
sealed class StateTarget {
  const StateTarget();
}

/// The locator names [control], which is [enabled]; [description] names it
/// in messages (`FilledButton "Log in"`).
final class StateFound extends StateTarget {
  /// The control that owns the matched widget.
  final Element control;

  /// Whether [control] is enabled.
  final bool enabled;

  /// How [control] reads in a message.
  final String description;

  /// Creates a found target.
  const StateFound(this.control, this.enabled, this.description);
}

/// Nothing the assertion can check is there right now — no match, only
/// hidden ones, an `nth` out of range, or several controls (ambiguous).
/// [reason] says which; the screen may change, so it can be re-checked.
final class StateMissing extends StateTarget {
  /// Why there is no target.
  final String reason;

  /// Creates a missing target.
  const StateMissing(this.reason);
}

/// The locator names a widget that is not part of any control — a caption,
/// a static row — so "enabled" means nothing for it. Final: waiting does
/// not turn a caption into a button.
final class StateNotAControl extends StateTarget {
  /// The locator, as messages name it (`text "Total"`).
  final String desc;

  /// Creates a not-a-control target.
  const StateNotAControl(this.desc);

  /// The reason a state assertion reports.
  String get reason => '$desc is not part of any control (a button, switch, '
      'checkbox, slider, field or a tile with onTap), so it is neither '
      'enabled nor disabled — address the control itself';
}

/// Why a tap cannot reach a target right now ([TreeWalker.tapReach]).
enum TapRefusal {
  /// The target has no laid-out, on-screen geometry.
  notLaidOut,

  /// The target is laid out but wholly outside the screen, or clipped away
  /// by the view it scrolls in (a page of a `PageView` that is not showing).
  offScreen,

  /// Nothing but the view receives pointers at the target: a route
  /// transition is in progress (every route scope ignores pointers).
  nothingHit,

  /// Something painted over the target would take the tap.
  covered,

  /// The target is visible but takes no input right now: the pointer is
  /// swallowed before it gets there (an `AbsorbPointer`, the Navigator right
  /// after a navigation, a list that is still scrolling).
  inputBlocked,
}

/// Where a tap reaches a target, or why it cannot ([TreeWalker.tapReach]).
sealed class TapReach {
  const TapReach();
}

/// A tap at [point] reaches the target.
final class TapReachable extends TapReach {
  /// The global logical point to tap.
  final Offset point;

  /// Creates a reachable verdict at [point].
  const TapReachable(this.point);
}

/// A tap cannot reach the target: [refusal] says why, [blocker] names what
/// takes the pointer instead, [center] is the target's centre (null when it
/// has none).
final class TapRefused extends TapReach {
  /// Why the tap is refused.
  final TapRefusal refusal;

  /// What takes the pointer instead, e.g. `AbsorbPointer(SplashSurface)`.
  final String blocker;

  /// The target's centre, when it has on-screen geometry.
  final Offset? center;

  /// Creates a refused verdict.
  const TapRefused(this.refusal, {required this.blocker, this.center});
}
