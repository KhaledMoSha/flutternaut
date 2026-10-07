part of '../tree_walker.dart';

/// The route whose `_ModalScopeStatus` inherited widget [element] is, or
/// null for any other element. Every [ModalRoute] builds exactly one,
/// directly above its page, so this identifies route boundaries in the
/// element tree. The widget class is private to the framework; its
/// `route` field is read dynamically, and a framework change that
/// removes it throws rather than silently hiding every route.
ModalRoute<Object?>? _routeOfScope(Element element) {
  if (element is! InheritedElement ||
      element.widget.runtimeType.toString() != '_ModalScopeStatus') {
    return null;
  }
  final Object? route = (element.widget as dynamic).route;
  return route is ModalRoute<Object?> ? route : null;
}

/// How far up [_animationKind] looks for the owning widget: a spinner or
/// Lottie builds its animated widgets a handful of elements below itself.
const int _animationOwnerHops = 8;

/// Route transitions, content animations and which routes are hidden.
extension TreeWalkerRoutes on TreeWalker {
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
}

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
      final route = _routeOfScope(ancestor);
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
    final route = _routeOfScope(scope);
    return route != null && _hidden.contains(route);
  }
}
