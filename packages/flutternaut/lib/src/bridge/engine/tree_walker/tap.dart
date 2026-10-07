part of '../tree_walker.dart';

/// [size] as `402x874` (logical pixels, whole numbers).
String _fmtSize(Size size) =>
    '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}';

/// Hit testing: whether and where a tap reaches a target.
extension TreeWalkerTap on TreeWalker {
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
    // Wholly outside the screen, clipped away by its scroll view, or showing
    // less than a logical pixel of itself ([_showsEnough]) while no route
    // transition runs: no point a person could aim at is left (a hit test
    // outside the view or a clip reaches nothing), and saying "nothing
    // receives pointers — a transition" would send the reader to wait for
    // one that never ends. Typical: a page of a PageView that is not showing
    // (a debug overlay's hidden page, or its 0.00002 px remainder at the
    // screen's edge). During a transition a target sliding through the edge
    // is the transition's doing, and that verdict below stands.
    final screen = _screenSize;
    if (!_showsEnough(_visibleRect(element, screen)) && !isTransitioning) {
      final where = screen == null
          ? 'outside the screen'
          : 'outside the ${_fmtSize(screen)} screen';
      return TapRefused(
        TapRefusal.offScreen,
        center: center,
        blocker: '$where, clipped away by the view it scrolls in, or shows '
            'under 1 px of itself — it is on a page or part of a list that '
            'is not showing',
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
}
