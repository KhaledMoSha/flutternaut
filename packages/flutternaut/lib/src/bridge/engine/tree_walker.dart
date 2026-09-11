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

  /// Finds the first element whose [ValueKey] value matches [keyValue].
  ElementInfo? findByKey(String keyValue) {
    return _findWhere((element) {
      final key = element.widget.key;
      return key is ValueKey && key.value.toString() == keyValue;
    });
  }

  /// The element's own visible text — plain [Text], `Text.rich`
  /// ([TextSpan]), [RichText], or [EditableText]. Null otherwise.
  ///
  /// Uses `toPlainText(includeSemanticsLabels: false)` so a span's
  /// `semanticsLabel` override doesn't shadow the visible text.
  String? _widgetOwnText(Widget w) {
    if (w is EditableText) return w.controller.text;
    if (w is Text) {
      return w.data ?? w.textSpan?.toPlainText(includeSemanticsLabels: false);
    }
    if (w is RichText) {
      return w.text.toPlainText(includeSemanticsLabels: false);
    }
    return null;
  }

  /// Finds the first text-bearing widget ([Text], `Text.rich`,
  /// [RichText], [EditableText]) whose visible text matches [text]
  /// exactly.
  ElementInfo? findByText(String text) {
    return _findWhere((element) => _widgetOwnText(element.widget) == text);
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
    final el = _findElementWhere((e) => _widgetOwnText(e.widget) == text);
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
    return _findElementWhere((element) {
      final key = element.widget.key;
      return key is ValueKey && key.value.toString() == keyValue;
    });
  }

  /// Finds the first [Element] whose own visible text equals [text]
  /// exactly (case-sensitive — see [findByText]).
  Element? findElementByText(String text) {
    return _findElementWhere((e) => _widgetOwnText(e.widget) == text);
  }

  /// Every [Element] whose [ValueKey] value matches [keyValue]. Used to
  /// detect ambiguous locators; more than one on-screen, hittable match
  /// is a fatal authoring error.
  List<Element> findAllElementsByKey(String keyValue) {
    return _findAllElementsWhere((element) {
      final key = element.widget.key;
      return key is ValueKey && key.value.toString() == keyValue;
    });
  }

  /// Every text-bearing [Element] whose own visible text equals [text]
  /// exactly (case-sensitive).
  List<Element> findAllElementsByText(String text) {
    return _findAllElementsWhere((e) => _widgetOwnText(e.widget) == text);
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
    if (element.widget.key is ValueKey) return false;
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
  bool _hasAlnum(String s) => s.contains(RegExp(r'[\p{L}\p{N}]', unicode: true));

  /// Whether two rects overlap on the vertical axis (share a row band).
  bool _yOverlaps(ElementRect a, ElementRect b) =>
      a.y < b.y + b.height && b.y < a.y + a.height;

  /// Returns all elements that have a [ValueKey].
  List<ElementInfo> findAllKeyed() {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const [];

    final results = <ElementInfo>[];
    void visitor(Element element) {
      if (element.widget.key is ValueKey) {
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

  /// Checks visibility of the widget found by [text]. Visibility is
  /// occlusion-aware — an on-screen element hidden under a foreign widget
  /// (nav bar, app bar, overlay) reports `visible == false`. See
  /// [_checkVisibility].
  VisibilityResult checkTextVisible(String text) {
    return _checkVisibility(findElementByText(text));
  }

  /// Checks visibility of the widget found by [ValueKey]. Occlusion-aware
  /// (see [checkTextVisible]).
  VisibilityResult checkVisibleByKey(String keyValue) {
    return _checkVisibility(findElementByKey(keyValue));
  }

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
  Offset? reachableTapPoint(Element element) {
    final center = centerOfElement(element);
    if (center == null) return null;

    if (isHittableAt(element, center)) return center;

    if (!_isInteractiveWidget(element.widget) && _hasHitAt(element, center)) {
      return center;
    }
    return null;
  }

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
  /// fall through to nothing (off-screen / clipped away).
  bool _hasHitAt(Element element, Offset point) {
    final ro = element.renderObject;
    if (ro == null) return false;
    final root = _rootRenderObject(ro);
    if (root is! RenderView) return false;

    final result = HitTestResult();
    root.hitTest(result, position: point);
    for (final entry in result.path) {
      if (entry.target is RenderObject) return true;
    }
    return false;
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
      var childSink = sink;
      var childLabel = parentLabel;
      Map<String, dynamic>? node;

      // A scroll view wrapper (ListView, PageView, …) is represented by the
      // single Scrollable it builds — the scrollable node adopts its type
      // name and key — so the wrapper itself is never emitted (a keyed
      // ListView must not become two nodes carrying the same key).
      final widget = element.widget;
      final visible = _scrollContainerName(widget) == null &&
          _isMeaningful(element) &&
          _isOnScreen(element, screen) &&
          _isUnobstructed(element);
      if (visible) {
        final info = extractInfo(element);
        final nodeText = _nodeText(element);
        if (!_isRedundant(element, info, nodeText, parentLabel)) {
          node = <String, dynamic>{'type': info.type};
          if (info.key != null) node['key'] = info.key;
          if (nodeText != null) node['text'] = nodeText;
          final rect = _visibleRect(element, screen);
          if (rect != null) {
            node['rect'] = ElementRect(
              x: rect.left,
              y: rect.top,
              width: rect.width,
              height: rect.height,
            ).toJson();
          }
          final enabled = _nodeEnabled(element);
          if (enabled != null) node['enabled'] = enabled;
          if (info.checked != null) node['checked'] = info.checked;
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
      node['scrollOffset'] = position.pixels;
      node['maxScrollExtent'] = position.maxScrollExtent;
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
        final key = w.key;
        if (node['key'] == null && key is ValueKey) {
          node['key'] = key.value.toString();
        }
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
      return widget is Text || widget is RichText || widget is EditableText;
    }
    final parent = parentLabel?.trim() ?? '';
    return parent.isNotEmpty && text == parent;
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
    final key = widget.key;
    final keyStr = key is ValueKey ? key.value.toString() : null;

    return ElementInfo(
      type: widget.runtimeType.toString(),
      key: keyStr,
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
    if (widget is InkResponse) return widget.onTap != null; // InkWell ⊂ InkResponse
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

  /// Computes occlusion-aware visibility for [element].
  ///
  /// `onScreen` is the rect-vs-viewport test; `obstructed` is true when the
  /// element is on screen but a foreign widget is painted on top of its
  /// center (see [_isUnobstructed]); `visible` (what every assertion /
  /// wait / scroll check consumes) is `onScreen && !obstructed` — so an
  /// element hidden under a nav bar / app bar / overlay is not "visible".
  VisibilityResult _checkVisibility(Element? element) {
    if (element == null) {
      return const VisibilityResult(exists: false, visible: false);
    }

    final info = extractInfo(element);
    final screenSize = _screenSize;
    if (info.rect == null || screenSize == null) {
      return VisibilityResult(exists: true, visible: false, info: info);
    }

    final r = info.rect!;
    final onScreen = r.x + r.width > 0 &&
        r.x < screenSize.width &&
        r.y + r.height > 0 &&
        r.y < screenSize.height;
    final obstructed = onScreen && !_isUnobstructed(element);

    return VisibilityResult(
      exists: true,
      visible: onScreen && !obstructed,
      onScreen: onScreen,
      obstructed: obstructed,
      info: info,
    );
  }

  /// Whether [element]'s center is the frontmost thing painted there — i.e.
  /// nothing from a different branch (nav bar, app bar, FAB, modal) sits on
  /// top of it.
  ///
  /// Hit-tests at the element's center: the element is unobstructed when the
  /// frontmost hit (`path.first`) is in the element's render lineage — the
  /// element itself, a descendant, or an ancestor (the background behind
  /// it). A frontmost hit from an unrelated branch means something is
  /// painted on top → obstructed.
  ///
  /// Defensive: returns true (cannot prove obstruction) when there is no
  /// render object, no [RenderView] to hit-test, or an empty hit path —
  /// we never falsely report occlusion. Note this is hit-test based, so a
  /// pointer-transparent (`IgnorePointer`) overlay is not detected; real
  /// bars/modals that absorb pointers are.
  bool _isUnobstructed(Element element) {
    final targetRo = element.renderObject;
    if (targetRo == null) return true;

    final center = centerOfElement(element);
    if (center == null) return true;

    final root = _rootRenderObject(targetRo);
    if (root is! RenderView) return true;

    final result = HitTestResult();
    root.hitTest(result, position: center);
    if (result.path.isEmpty) return true;

    final top = result.path.first.target;
    if (top is! RenderObject) return true;

    return _isRenderAncestorOrSelf(targetRo, top) ||
        _isRenderAncestorOrSelf(top, targetRo);
  }

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
    var opacity = 1.0;
    RenderObject? ro = element.renderObject;
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
          rect = rect.intersect(parent.localToGlobal(Offset.zero) & parent.size);
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
    if (widget.key is ValueKey) return true;
    if (_extractEnabled(widget) != null) return true;
    if (_extractChecked(widget) != null) return true;
    return widget.runtimeType.toString().endsWith('Button');
  }

  Map<String, dynamic> _dumpElement(Element element, int depth, int maxDepth) {
    final node = <String, dynamic>{
      'type': element.widget.runtimeType.toString(),
    };

    final key = element.widget.key;
    if (key is ValueKey) {
      node['key'] = key.value.toString();
    }

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
