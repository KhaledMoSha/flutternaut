part of '../tree_walker.dart';

/// Scrollables: which are on screen, where a scroll can start, and their dump
/// metrics.
extension TreeWalkerScroll on TreeWalker {
  /// The [ScrollPosition] of a [Scrollable] element, or null when no
  /// position is attached yet. Public so the gesture engine can tell
  /// which visible scrollables can actually move in a direction.
  ScrollPosition? scrollPositionOf(Element element) =>
      _scrollPositionOf(element);

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
        final key = TreeWalker.keyOf(w);
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
}
