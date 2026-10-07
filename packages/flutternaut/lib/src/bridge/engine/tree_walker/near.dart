part of '../tree_walker.dart';

/// Row band tolerance (logical px) for grouping `near` candidates into rows
/// in [_readingOrder]. MUST match `nearRowTolerance` in the engine catalog
/// (engine/catalog/catalog.go) or recorded `nth` values will drift.
const double _kNearRowTolerance = 12.0;

/// The `near` locator and reading order (the bridge half of CLAUDE.md sync
/// triad 6(b)).
extension TreeWalkerNear on TreeWalker {
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
    if (TreeWalker.keyOf(element.widget) != null) return false;
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

  /// Whether two rects overlap on the vertical axis (share a row band).
  bool _yOverlaps(ElementRect a, ElementRect b) =>
      a.y < b.y + b.height && b.y < a.y + a.height;
}
