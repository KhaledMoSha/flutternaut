part of '../tree_walker.dart';

/// Below this painted opacity a widget is treated as invisible. ~0.05 keeps
/// clearly-visible widgets (including a page fading *in* past ~5%) and drops
/// only the near-invisible faded-out layers.
const double _visibleOpacityThreshold = 0.05;

/// Element geometry: rects, the screen size, on-screen and offstage tests,
/// painted opacity and clipping.
extension TreeWalkerGeometry on TreeWalker {
  /// The smallest side, in logical pixels, a widget's visible rect (after
  /// clipping to the screen and every clipping ancestor) must have on
  /// **both** axes for a person to see it ([_showsEnough]). One rule for the
  /// whole bridge: the `/screen` dump, `scrollIndex`, `/swipe` resolution
  /// and the auto-pick, `nth`, `near`, the visibility checks and the tap
  /// gate. A sub-pixel sliver — the next page of a `PageView` left 0.00002
  /// px on screen by a fractional offset, a wrapper positioned at the
  /// screen's edge — is not on screen.
  ///
  /// The engine catalog applies the same value (`catalog.MinVisibleSide`
  /// in engine/catalog/visible_size.go; its pin test reads this
  /// declaration, so keep it on one line): change both, and both pin tests
  /// (min_visible_side_test.go, test/bridge/min_visible_side_test.dart),
  /// together.
  static const double minVisibleSide = 1.0;

  /// Whether a visible rect [r] shows enough of a widget for a person to
  /// see it: at least [minVisibleSide] on both sides. Null (no geometry),
  /// empty and negative (clipped away) rects do not.
  bool _showsEnough(Rect? r) =>
      r != null && r.width >= minVisibleSide && r.height >= minVisibleSide;

  /// The global on-screen [ElementRect] of [element], or null if it has
  /// no laid-out [RenderBox].
  ElementRect? rectOfElement(Element element) => _rectOf(element);

  /// The part of [element] inside the screen and every clipping ancestor
  /// (see [_visibleRect]), or null when it has no laid-out [RenderBox]. A
  /// rect without both sides of [minVisibleSide] shows nothing a person can
  /// see. Public so the gesture engine can rank scrollables by what shows.
  Rect? visibleRectOf(Element element) => _visibleRect(element, _screenSize);

  /// The center of [element]'s on-screen rect, or null if it has no
  /// laid-out geometry.
  Offset? centerOfElement(Element element) => _rectOf(element)?.center;

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

  /// Whether [element] is laid out, its rect still shows at least
  /// [minVisibleSide] on both sides after clipping to the [screen] viewport
  /// **and every clipping ancestor** (scroll viewports / `ClipRect`s)
  /// ([_showsEnough]), and it is not hidden under an `Offstage` (e.g.
  /// inactive tab / `Visibility(maintainState: true)`).
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
    return _showsEnough(_visibleRect(element, screen));
  }

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
}
