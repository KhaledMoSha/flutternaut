part of '../tree_walker.dart';

/// How far up [semanticsOf] looks for a wrapping label. `Tooltip` places
/// its child under a `Semantics` + mouse region + `Listener` of its own,
/// so the describing widget is typically 3–5 elements above the control.
const int _semanticsAncestorHops = 6;

/// How far (logical px) two rects may differ on x, y, width and height
/// and still be one widget's bounds — a `Semantics` wrapper and the
/// control it wraps share them, up to rounding.
const double _semanticsIdRectSlack = 0.5;

/// Whether [a] and [b] are the same bounds within
/// [_semanticsIdRectSlack].
bool _sameRect(ElementRect a, ElementRect b) =>
    (a.x - b.x).abs() <= _semanticsIdRectSlack &&
    (a.y - b.y).abs() <= _semanticsIdRectSlack &&
    (a.width - b.width).abs() <= _semanticsIdRectSlack &&
    (a.height - b.height).abs() <= _semanticsIdRectSlack;

/// Whether [widget] is what a `semantics` locator [target] names: its own
/// accessibility label ([ownSemanticsOf]) or its own identifier
/// ([ownSemanticsIdOf]) equals [target] — exactly, or with [foldCase]
/// case-insensitively ([target] is then already lower-cased).
bool _semanticsMatch(
  Widget widget,
  String target, {
  required bool foldCase,
}) {
  final label = TreeWalker.ownSemanticsOf(widget);
  final id = TreeWalker.ownSemanticsIdOf(widget);
  if (foldCase) {
    return label?.toLowerCase() == target || id?.toLowerCase() == target;
  }
  return label == target || id == target;
}

/// Accessibility labels and identifiers, and the `semantics` locator.
extension TreeWalkerSemantics on TreeWalker {
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
    final own = TreeWalker.ownSemanticsOf(element.widget);
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
      final label = TreeWalker.ownSemanticsOf(w);
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
      found = TreeWalker.ownSemanticsOf(w);
      if (found != null) return false;
      hops++;
      return hops < _semanticsAncestorHops;
    });
    return found;
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
    final own = TreeWalker.ownSemanticsIdOf(element.widget);
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
      final id = TreeWalker.ownSemanticsIdOf(w);
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
}
