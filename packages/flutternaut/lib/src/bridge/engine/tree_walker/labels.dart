part of '../tree_walker.dart';

/// Text and labels: a widget's own text, the label a control shows, and element
/// info.
extension TreeWalkerLabels on TreeWalker {
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
      return raw == null ? null : TreeWalker.normalizeText(raw);
    }
    if (w is RichText) {
      return TreeWalker.normalizeText(
          w.text.toPlainText(includeSemanticsLabels: false));
    }
    return null;
  }

  /// Whether [s] contains any letter or digit — glyph "labels"
  /// (private-use code points) do not count as readable text.
  bool _hasAlnum(String s) =>
      s.contains(RegExp(r'[\p{L}\p{N}]', unicode: true));

  /// The visible text of [element] (its own or first descendant), or null.
  String? textOfElement(Element element) => extractText(element);

  /// Extracts full info from an [Element], including type, key, text,
  /// position, enabled/checked state.
  ///
  /// Visible for testing.
  ElementInfo extractInfo(Element element) {
    final widget = element.widget;

    return ElementInfo(
      type: widget.runtimeType.toString(),
      key: TreeWalker.keyOf(widget),
      text: extractText(element),
      rect: _rectOf(element),
      enabled: _extractEnabled(widget),
      checked: _extractChecked(widget),
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
    if (TreeWalker.keyOf(widget) != null) return true;
    if (_extractEnabled(widget) != null) return true;
    if (_extractChecked(widget) != null) return true;
    return widget.runtimeType.toString().endsWith('Button');
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
