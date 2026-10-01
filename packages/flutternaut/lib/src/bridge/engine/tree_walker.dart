import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/element_info.dart';
import '../models/element_rect.dart';
import '../models/visibility_result.dart';

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
  /// so a label is never borrowed from an unrelated container.
  String? semanticsOf(Element element) {
    final own = ownSemanticsOf(element.widget);
    if (own != null) return own;

    String? found;
    void visit(Element child) {
      if (found != null) return;
      // A descendant that is a control of its own keeps its label: a slot
      // or wrapper around an IconButton must not be listed as "Open menu"
      // next to the button itself.
      final w = child.widget;
      if (_isButtonLike(w) || _extractEnabled(w) != null) return;
      found = ownSemanticsOf(w);
      if (found != null) return;
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

  /// Finds the first element whose own accessibility label
  /// ([ownSemanticsOf]) equals [label] exactly, else — so a test written
  /// against a tooltip survives a capitalisation change — the first whose
  /// label equals it case-insensitively.
  ElementInfo? findBySemantics(String label) {
    final el = findElementBySemantics(label);
    return el == null ? null : extractInfo(el);
  }

  /// The [Element] version of [findBySemantics].
  Element? findElementBySemantics(String label) {
    final exact = _findElementWhere(
      (e) => ownSemanticsOf(e.widget) == label,
    );
    if (exact != null) return exact;
    final needle = label.toLowerCase();
    return _findElementWhere(
      (e) => ownSemanticsOf(e.widget)?.toLowerCase() == needle,
    );
  }

  /// Every element whose own accessibility label equals [label]
  /// (exact first; case-insensitive when nothing matches exactly). Used
  /// by the tap/long-press confirm pipeline for ambiguity detection.
  List<Element> findAllElementsBySemantics(String label) {
    final exact = _findAllElementsWhere(
      (e) => ownSemanticsOf(e.widget) == label,
    );
    if (exact.isNotEmpty) return exact;
    final needle = label.toLowerCase();
    return _findAllElementsWhere(
      (e) => ownSemanticsOf(e.widget)?.toLowerCase() == needle,
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

  /// Whether [element]'s own text equals the locator [text] (both sides
  /// normalized — see [normalizeText]).
  bool _textEquals(Element element, String text) {
    final own = _widgetOwnText(element.widget);
    return own != null && own == normalizeText(text);
  }

  /// Finds the first text-bearing widget ([Text], `Text.rich`,
  /// [RichText], [EditableText]) whose visible text matches [text]
  /// exactly.
  ElementInfo? findByText(String text) {
    return _findWhere((element) => _textEquals(element, text));
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
  Element? _resolveEditableElementByText(String text) {
    final el = _findElementWhere((e) => _textEquals(e, text));
    if (el == null) return null;

    final enclosing = _enclosingEditableElement(el);
    if (enclosing != null) return enclosing;

    final labelRect = _rectOf(el);
    if (labelRect == null) return null;
    return _nearestFieldElement(labelRect);
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
  ElementInfo? findByTextContains(String substring) {
    final needle = substring.toLowerCase();
    return _findWhere((element) {
      final t = _widgetOwnText(element.widget);
      return t != null && t.toLowerCase().contains(needle);
    });
  }

  /// Finds the first [Element] whose [ValueKey] value matches [keyValue].
  Element? findElementByKey(String keyValue) {
    return _findElementWhere((element) => keyOf(element.widget) == keyValue);
  }

  /// Finds the first [Element] whose own visible text equals [text]
  /// exactly (case-sensitive — see [findByText]).
  Element? findElementByText(String text) {
    return _findElementWhere((e) => _textEquals(e, text));
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
  List<Element> findAllElementsByText(String text) {
    return _findAllElementsWhere((e) => _textEquals(e, text));
  }

  /// Every text-bearing [Element] whose own visible text contains
  /// [substring], case-insensitively (mirrors [findByTextContains]).
  List<Element> findAllElementsByTextContains(String substring) {
    final needle = substring.toLowerCase();
    return _findAllElementsWhere((e) {
      final t = _widgetOwnText(e.widget);
      return t != null && t.toLowerCase().contains(needle);
    });
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
  /// - interactive (tap affordance, [_nodeEnabled] non-null — the same rule
  ///   that puts `enabled` on a dump node),
  /// - no [ValueKey] and no visible text in its subtree (truly unlabeled),
  /// - on screen and unobstructed (the dump's visibility gates),
  /// - **outermost only**: a candidate's subtree is never searched for more
  ///   candidates (an `_IconButton` wrapping an enabled `GestureDetector`
  ///   counts once),
  /// - rect vertically overlaps [anchor]'s rect.
  List<Element> unlabeledInteractiveNear(Element anchor) {
    final anchorRect = _rectOf(anchor);
    final root = WidgetsBinding.instance.rootElement;
    if (anchorRect == null || root == null) return const [];

    final screen = _screenSize;
    final candidates = <({ElementRect rect, Element el})>[];

    void visit(Element element) {
      // The shell check (unlabeled + interactive + visible) both selects
      // candidates and prunes: a shell's subtree is never searched again,
      // so a wrapper and its inner gesture detector count once. A shell
      // with readable text centered inside it is pruned but NOT a
      // candidate — the catalog labels that control with the inner text
      // (its labelIconButtons pass), so it is addressable without `near`.
      if (_isUnlabeledInteractiveShell(element, screen)) {
        final rect = _rectOf(element);
        if (rect != null &&
            _yOverlaps(rect, anchorRect) &&
            !_hasReadableTextCenteredInside(rect, screen)) {
          candidates.add((rect: rect, el: element));
        }
        return; // outermost-only: never descend into a shell
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return _readingOrder(candidates).map((c) => c.el).toList();
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
  bool _isUnlabeledInteractiveShell(Element element, Size? screen) {
    if (keyOf(element.widget) != null) return false;
    if (_nodeEnabled(element) == null) return false;
    final text = _nodeText(element);
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
  VisibilityResult checkTextVisible(String text, {int? nth}) {
    return _checkVisibility(
      findAllElementsByText(text),
      'text "$text"',
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
  VisibilityResult checkTextContainsVisible(String substring, {int? nth}) {
    return _checkVisibility(
      findAllElementsByTextContains(substring),
      'text containing "$substring"',
      nth: nth,
    );
  }

  /// Visibility of the widget(s) with accessibility label [label] (see
  /// [findAllElementsBySemantics] and [checkTextVisible]).
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

  /// Every on-screen [Scrollable] whose scroll [axis] matches, used to
  /// auto-target a screen-level scroll when no explicit scroll container
  /// is given. Recurses through matches so nested scrollables are also
  /// found — that lets the caller detect genuine same-axis ambiguity.
  ///
  /// A single `ListView`/`CustomScrollView` builds exactly one
  /// `Scrollable`, so list internals don't inflate the count; a
  /// `NestedScrollView` legitimately yields more than one.
  List<Element> findVisibleScrollables(Axis axis) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const [];

    final screen = _screenSize;
    final matches = <Element>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Scrollable &&
          axisDirectionToAxis(widget.axisDirection) == axis &&
          _isOnScreen(element, screen)) {
        matches.add(element);
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return matches;
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

  /// The point to tap to reach [element], or null if [element] cannot be
  /// reached by a tap (off-screen, or nothing hittable at its location).
  ///
  /// Tappability depends on whether the target is interactive:
  /// - **Interactive** targets (buttons, fields, gesture detectors) must be
  ///   reached strictly — the hit at the element's center must land in the
  ///   element's own render subtree ([isHittableAt]). This is what catches
  ///   a genuinely occluded or off-screen *button*.
  /// - **Non-interactive** targets (a plain `Text`/`Icon`/`Image` used only
  ///   as a locator) are lenient: it is enough that *something* is hittable
  ///   at that point. Targeting by visible text means "tap whatever owns
  ///   this pixel" — e.g. tapping a field's hint text focuses the field
  ///   ([RenderEditable]), which is the intended interaction, not a miss.
  ///
  /// Either way, a point where nothing is hittable (scrolled off-screen,
  /// clipped away) returns null so the caller can fail loudly.
  ///
  /// The centre is tried first; when something covers it (a badge, a
  /// floating button over one end of a row), the inset sample points of
  /// [_samplePoints] are tried — a person would tap the part of the target
  /// they can reach.
  Offset? reachableTapPoint(Element element) {
    final center = centerOfElement(element);
    if (center == null) return null;

    if (isHittableAt(element, center)) return center;
    for (final point in _samplePoints(element).skip(1)) {
      if (isHittableAt(element, point)) return point;
    }

    if (!_isInteractiveWidget(element.widget) && _hasHitAt(element, center)) {
      return center;
    }
    return null;
  }

  /// The tap-reachable matches among [matches], in reading order, exactly
  /// as the tap gate counts them — so the `nth` the `/screen` dump reports
  /// (`text_nth` / `semantics_nth`) is the `nth` a tap resolves:
  ///
  ///  * a match that a person cannot see (offstage, faded out, clipped
  ///    away) or cannot reach with a tap is not a candidate;
  ///  * stacked copies of ONE control — two glyph layers of a nav icon, a
  ///    cross-fading label — count once (see [_sameStackedControl]).
  List<(Element, Offset)> actableMatches(List<Element> matches) {
    final screen = _screenSize;
    final out = <(Element, Offset)>[];
    for (final element in inReadingOrder(matches)) {
      if (!_isOnScreen(element, screen)) continue;
      final point = reachableTapPoint(element);
      if (point == null) continue;
      if (out.any((kept) => _sameStackedControl(kept.$1, element))) continue;
      out.add((element, point));
    }
    return out;
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

  /// Whether any widget is hit-testable at [point] in [element]'s
  /// [RenderView] — i.e. a tap there would land on *something* rather than
  /// fall through to nothing (off-screen / clipped away, or every route
  /// ignoring pointers mid-transition).
  ///
  /// The [RenderView] itself always joins the hit path and is not "something":
  /// a pointer that reaches only the view is a pointer nobody handles.
  bool _hasHitAt(Element element, Offset point) {
    final ro = element.renderObject;
    if (ro == null) return false;
    final root = _rootRenderObject(ro);
    if (root is! RenderView) return false;

    final result = HitTestResult();
    root.hitTest(result, position: point);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderObject && !identical(target, root)) return true;
    }
    return false;
  }

  /// Whether a pointer at [point] would reach only the [RenderView] — no
  /// widget at all. During a route transition every route's scope ignores
  /// pointers (`IgnorePointer` in `_ModalScope`), so a tap dispatched then is
  /// silently dropped by the framework; this is how the bridge tells that
  /// case from a genuinely occluded target.
  bool pointersIgnoredAt(Element reference, Offset point) {
    final ro = reference.renderObject;
    if (ro == null) return false;
    final root = _rootRenderObject(ro);
    if (root is! RenderView) return false;
    final result = HitTestResult();
    root.hitTest(result, position: point);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderObject && !identical(target, root)) return false;
    }
    return true;
  }

  /// What a tap at the global logical [point] would reach right now — the
  /// gate for a coordinate tap (`tap_at`). `offScreen` when the point lies
  /// outside the view; `pointersIgnored` when nothing but the [RenderView]
  /// is hit (mid route transition, or empty space); otherwise `target`
  /// describes the control (or labelled widget) that owns the frontmost
  /// hit, e.g. `ElevatedButton "Check In"`.
  ({bool offScreen, bool pointersIgnored, String? target}) probeTapAt(
    Offset point,
  ) {
    final screen = _screenSize;
    final root = WidgetsBinding.instance.rootElement?.renderObject;
    if (screen == null || root is! RenderView) {
      return (offScreen: true, pointersIgnored: false, target: null);
    }
    if (!(Offset.zero & screen).contains(point)) {
      return (offScreen: true, pointersIgnored: false, target: null);
    }
    final result = HitTestResult();
    root.hitTest(result, position: point);
    for (final entry in result.path) {
      final hit = entry.target;
      if (hit is! RenderObject || identical(hit, root)) continue;
      return (
        offScreen: false,
        pointersIgnored: false,
        target: _describeHit(hit),
      );
    }
    return (offScreen: false, pointersIgnored: true, target: null);
  }

  /// A readable name for the widget that owns the hit render object [ro]:
  /// its nearest control ([_controlOf]) with that control's label, else the
  /// creating widget's type. Uses the render object's debug creator (the
  /// bridge runs in debug builds only).
  String _describeHit(RenderObject ro) {
    final creator = ro.debugCreator;
    if (creator is! DebugCreator) return ro.runtimeType.toString();
    final element = creator.element;
    final owner = _controlOf(element) ?? element;
    final label = extractText(owner);
    final semantics = semanticsOf(owner);
    final name = owner.widget.runtimeType.toString();
    if (label != null && _hasAlnum(label)) return '$name "$label"';
    if (semantics != null) return '$name (semantics "$semantics")';
    return name;
  }

  /// Diagnostic name of the render object a tap at [point] would actually
  /// reach — the topmost hit — resolved in the same [RenderView] as
  /// [reference]. Null if nothing is hit or no view is available. Used to
  /// explain why a target is unreachable (occluded by X).
  String? topmostHitTypeAt(Element reference, Offset point) {
    final ro = reference.renderObject;
    if (ro == null) return null;

    final root = _rootRenderObject(ro);
    if (root is! RenderView) return null;

    final result = HitTestResult();
    root.hitTest(result, position: point);
    for (final entry in result.path) {
      final hit = entry.target;
      if (hit is RenderObject) return hit.runtimeType.toString();
    }
    return null;
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
    // DFS order with the `/swipe` `scrollIndex` resolution, so the index a
    // consumer reads from the dump resolves to the same scrollable when it
    // scrolls — the two can never disagree.
    final verticalScrollables = findVisibleScrollables(Axis.vertical);
    final horizontalScrollables = findVisibleScrollables(Axis.horizontal);
    final layers = _routeLayers();
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
        final nodeText = _nodeText(element);
        if (!_isRedundant(element, info, nodeText, parentLabel)) {
          node = <String, dynamic>{'type': info.type};
          if (info.key != null) node['key'] = info.key;
          if (nodeText != null) node['text'] = nodeText;
          final semantics = semanticsOf(element);
          if (semantics != null) node['semantics'] = semantics;
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
          final enabled = _nodeEnabled(element);
          if (enabled != null) node['enabled'] = enabled;
          if (info.checked != null) node['checked'] = info.checked;
          nthIndex.annotate(element, node, nodeText, semantics);
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
  /// position among on-screen same-axis scrollables, in the same order the
  /// `/swipe` `scrollIndex` resolution uses), and adopts the user-facing
  /// scroll view's type name and [ValueKey] — `ListView(key: ...)` keys the
  /// ListView widget, not the inner [Scrollable] it builds.
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
    try {
      final offset = renderObject.localToGlobal(Offset.zero);
      return ElementRect(
        x: offset.dx,
        y: offset.dy,
        width: renderObject.size.width,
        height: renderObject.size.height,
      );
    } on Exception {
      // RenderObject may not be attached or laid out.
      return null;
    }
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
  /// label found by an unbounded descendant scan (so a button still
  /// reads "Continue" through Material internals); null for structural
  /// wrappers (so `LayoutId`/`KeyedSubtree`/`InheritedWidget` don't
  /// inherit a descendant's text).
  String? _nodeText(Element element) {
    final own = _widgetOwnText(element.widget);
    if (own != null) return own;

    final widget = element.widget;
    final buttonLike = _isButtonLike(widget);
    // Only interactive widgets carry a "label"; structural wrappers
    // return null so they don't bubble a descendant's text.
    return buttonLike ? extractText(element) : null;
  }

  /// Enabled/disabled state to attach to a dump node: the widget's own
  /// [_extractEnabled] (Material buttons, form fields), else — for a button-like
  /// widget whose enabled state lives on an inner `InkWell`/`GestureDetector`
  /// (custom buttons like `PrimaryCButton`, which set `onTap: null` and dim to
  /// 0.45 opacity when disabled) — the nearest such descendant's tap-enabled
  /// state. Null when it can't be determined (so the field is omitted).
  bool? _nodeEnabled(Element element) {
    final own = _tapEnabled(element.widget);
    if (own != null) return own;
    if (!_isButtonLike(element.widget)) return null;
    bool? found;
    void visit(Element e) {
      if (found != null) return;
      found = _tapEnabled(e.widget);
      if (found != null) return;
      e.visitChildren(visit);
    }

    element.visitChildren(visit);
    return found;
  }

  /// Whether [widget] reads as a button: a Material button, or an
  /// `InkWell`/`GestureDetector` acting as one.
  bool _isButtonLike(Widget widget) =>
      widget is GestureDetector ||
      widget is InkWell ||
      widget.runtimeType.toString().endsWith('Button');

  /// A widget's tap-enabled state read directly off it: [_extractEnabled] for
  /// Material widgets/fields, or whether an `InkWell`/`GestureDetector` has a
  /// non-null `onTap` (a disabled custom button nulls its tap callback). Null
  /// when the widget exposes no tap affordance.
  bool? _tapEnabled(Widget widget) {
    final material = _extractEnabled(widget);
    if (material != null) return material;
    // InkWell ⊂ InkResponse.
    if (widget is InkResponse) return widget.onTap != null;
    if (widget is GestureDetector) return widget.onTap != null;
    return null;
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
  Element? _nearestFieldElement(ElementRect labelRect) {
    final screen = _screenSize;
    final candidates = <(ElementRect, Element)>[];

    void walk(Element element) {
      final w = element.widget;
      if (w is EditableText && _isOnScreen(element, screen)) {
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

    final screen = _screenSize;
    final layers = _routeLayers();
    final ordered = inReadingOrder(matches);
    if (ordered.isEmpty) {
      return VisibilityResult(
        exists: true,
        visible: false,
        info: extractInfo(matches.first),
        reason: '$desc exists but is not laid out',
      );
    }

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
      final blocker = topmostHitTypeAt(element, center);
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
  /// render lineage (itself, a descendant, or an ancestor behind it), or is
  /// a transparent input layer ([_isTransparentOverlay] — a
  /// `Positioned.fill(InkWell)` over a card paints nothing). Clear at every
  /// point → [_Coverage.clear]; at none → [_Coverage.covered]; otherwise
  /// [_Coverage.partial], which the dump reports as `partial: true` instead
  /// of silently dropping the element.
  ///
  /// Hit-test based, so a pointer-transparent (`IgnorePointer`) layer
  /// painted on top is not detected; real bars and modals, which absorb
  /// pointers, are.
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

  /// The points [_coverage] and [reachableTapPoint] sample on [element]:
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
    final result = HitTestResult();
    root.hitTest(result, position: point);
    // The frontmost render object hit. The path can start with non-render
    // targets — a TextSpan under the pointer is a hit-test target of its
    // own — which say nothing about what is painted there.
    RenderObject? top;
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderObject) {
        top = t;
        break;
      }
    }
    if (top == null) return true;
    if (_isRenderAncestorOrSelf(target, top) ||
        _isRenderAncestorOrSelf(top, target)) {
      return true;
    }
    // A faded-out layer on top (Opacity 0, a finished fade-out kept for
    // layout) still takes the hit but paints nothing over the target.
    if (_renderOpacity(top) < _visibleOpacityThreshold) return true;
    return _isTransparentOverlay(top, target);
  }

  /// Whether the branch that won the hit-test at a point over [target]
  /// paints nothing there — it is only an input layer (a
  /// `Positioned.fill(InkWell)` stretched over a card, a `GestureDetector`
  /// catching taps for a whole tile). Checks the hit object's own subtree
  /// and its ancestors up to (excluding) the first one that also contains
  /// [target]; any painting render object in that branch is an occluder.
  bool _isTransparentOverlay(RenderObject top, RenderObject target) {
    var budget = _transparentScanBudget;
    var paints = false;
    void scan(RenderObject ro) {
      if (paints || budget-- <= 0) {
        // Out of budget: assume it paints — never claim a clear view that
        // was not proven.
        paints = true;
        return;
      }
      if (_paintsContent(ro)) {
        paints = true;
        return;
      }
      ro.visitChildren(scan);
    }

    scan(top);
    if (paints) return false;

    var current = top.parent;
    while (current is RenderObject) {
      if (_isRenderAncestorOrSelf(current, target)) return true;
      if (_paintsContent(current)) return false;
      current = current.parent;
    }
    return false;
  }

  /// Render objects [_isTransparentOverlay] inspects before giving up.
  static const int _transparentScanBudget = 64;

  /// Whether [ro] paints visible content of its own (text, images,
  /// decoration, fill, platform views…) rather than only passing pointers
  /// or layout through.
  bool _paintsContent(RenderObject ro) {
    if (ro is RenderParagraph ||
        ro is RenderEditable ||
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
    if (ro is! RenderBox || !ro.hasSize) return null;
    Rect rect;
    try {
      rect = ro.localToGlobal(Offset.zero) & ro.size;
    } on Exception {
      // RenderObject may not be attached or laid out.
      return null;
    }
    if (screen != null) rect = rect.intersect(Offset.zero & screen);

    var parent = ro.parent;
    while (parent is RenderObject) {
      if (_clips(parent) && parent is RenderBox && parent.hasSize) {
        try {
          rect =
              rect.intersect(parent.localToGlobal(Offset.zero) & parent.size);
        } on Exception {
          // An unattached ancestor can't clip — skip it.
        }
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
      try {
        final offset = renderObject.localToGlobal(Offset.zero);
        node['rect'] = {
          'x': offset.dx,
          'y': offset.dy,
          'w': renderObject.size.width,
          'h': renderObject.size.height,
        };
      } on Exception {
        // Skip position if not available.
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

/// Computes, for dump nodes, the `nth` a text or semantics tap would need
/// to reach them — using the tap gate's own candidate list
/// ([TreeWalker.actableMatches]) — so a catalog ref resolves to exactly
/// the widget it names even when its label repeats on screen.
///
/// Emitted as `text_nth`/`text_matches` and `semantics_nth`/
/// `semantics_matches`, only when the label has more than one actable
/// match and the node is one of them. Candidate lists are computed once
/// per label per dump.
class _NthIndex {
  _NthIndex(this._walker);

  final TreeWalker _walker;
  final Map<String, List<(Element, Offset)>> _byText = {};
  final Map<String, List<(Element, Offset)>> _bySemantics = {};

  void annotate(
    Element node,
    Map<String, dynamic> out,
    String? text,
    String? semantics,
  ) {
    if (text != null && text.isNotEmpty) {
      final candidates = _byText.putIfAbsent(text, () {
        final matches = _walker.findAllElementsByText(text);
        return matches.length > 1 ? _walker.actableMatches(matches) : const [];
      });
      _emit(node, out, 'text', candidates);
    }
    if (semantics != null) {
      final candidates = _bySemantics.putIfAbsent(semantics, () {
        final matches = _walker.findAllElementsBySemantics(semantics);
        return matches.length > 1 ? _walker.actableMatches(matches) : const [];
      });
      _emit(node, out, 'semantics', candidates);
    }
  }

  void _emit(
    Element node,
    Map<String, dynamic> out,
    String prefix,
    List<(Element, Offset)> candidates,
  ) {
    if (candidates.length < 2) return;
    final index = candidates.indexWhere(
      (c) => _related(c.$1, node),
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
