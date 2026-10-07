part of '../tree_walker.dart';

/// Recognizers that make a gesture detector a tap handler.
const Set<Type> _tapRecognizers = {
  TapGestureRecognizer,
  DoubleTapGestureRecognizer,
  LongPressGestureRecognizer,
  TapAndPanGestureRecognizer,
  TapAndHorizontalDragGestureRecognizer,
};

/// How far above its content `IgnorePointer` a [ScrollableState] sits in
/// the element tree (its scope, gesture detector and semantics wrappers).
const int _scrollableBuildDepth = 16;

/// What swallows or takes a pointer before it reaches a target, and how that is
/// named.
extension TreeWalkerBlockers on TreeWalker {
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
}
