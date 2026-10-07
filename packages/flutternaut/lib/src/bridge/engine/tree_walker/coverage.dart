part of '../tree_walker.dart';

/// Render objects [_subtreePaints] inspects before giving up.
const int _transparentScanBudget = 64;

/// Occlusion: how much of an element a person can see past what is painted on
/// top of it.
extension TreeWalkerCoverage on TreeWalker {
  /// Whether the layer [layer] paints something a person would see at the
  /// global [point]: not faded out, and some render object in its subtree
  /// that covers the point paints content.
  bool _paintsOver(RenderObject layer, Offset point) =>
      _renderOpacity(layer) >= _visibleOpacityThreshold &&
      _subtreePaints(layer, at: point);

  /// Whether [element] is not covered at every sample point — the
  /// occlusion half of the dump's visibility gate (see [_coverage]).
  bool _isUnobstructed(Element element) =>
      _coverage(element, _screenSize) != _Coverage.covered;

  /// How much of [element] a person can see past whatever is painted on
  /// top of it, sampled at [_samplePoints] (its centre and four points
  /// inset 25% into its visible rect).
  ///
  /// A point is clear when the frontmost hit there is in the element's own
  /// render lineage (itself, a descendant, or an ancestor behind it — unless
  /// a layer in front swallowed the pointer silently and paints there, see
  /// [_pointClear]), or is an input layer that paints nothing at that point
  /// ([_isTransparentOverlay] — a `Positioned.fill(InkWell)` over a card, a
  /// page-wide translucent detector whose banner is elsewhere). Clear at every
  /// point → [_Coverage.clear]; at none → [_Coverage.covered]; otherwise
  /// [_Coverage.partial], which the dump reports as `partial: true` instead
  /// of silently dropping the element.
  ///
  /// Hit-test based, so a pointer-transparent (`IgnorePointer`) layer
  /// painted on top is not detected; real bars and modals, and
  /// `AbsorbPointer` layers (a splash held over the page), are.
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

  /// The points [_coverage] and [tapReach] sample on [element]:
  /// its visible rect's centre first, then four points inset 25% towards
  /// each corner. Empty when the element has no visible geometry, or shows
  /// less than [TreeWalkerGeometry.minVisibleSide] on a side
  /// ([_showsEnough]).
  List<Offset> _samplePoints(Element element, {Size? screen}) {
    final rect = _visibleRect(element, screen ?? _screenSize);
    if (rect == null || !_showsEnough(rect)) return const [];
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
    final top = _frontmost(_hitTest(root, point));
    if (top == null) return true;
    if (_isRenderAncestorOrSelf(target, top)) return true;
    if (_isRenderAncestorOrSelf(top, target)) {
      // The pointer stopped at an ancestor. Either the ancestor took it
      // itself (nothing is over the target), or a child of it swallowed it
      // without joining the hit path: an `AbsorbPointer` wrapping the
      // target's branch absorbs input but hides nothing; one painted in
      // front of it (a splash, a loading layer) covers the target when it
      // paints there.
      final claimer = _silentClaimer(top, point, stopAt: target);
      if (claimer == null || _isRenderAncestorOrSelf(claimer, target)) {
        return true;
      }
      return !_paintsOver(claimer, point);
    }
    // A faded-out layer on top (Opacity 0, a finished fade-out kept for
    // layout) still takes the hit but paints nothing over the target.
    if (_renderOpacity(top) < _visibleOpacityThreshold) return true;
    return _isTransparentOverlay(top, target, at: point);
  }

  /// Whether the branch that won the hit-test at a point over [target]
  /// paints nothing there — it is only an input layer (a
  /// `Positioned.fill(InkWell)` stretched over a card, a `GestureDetector`
  /// catching taps for a whole tile). Checks the hit object's own subtree
  /// and its ancestors up to (excluding) the first one that also contains
  /// [target]; any painting render object in that branch is an occluder.
  ///
  /// With [at] (the coverage check, [_pointClear]) only what the hit
  /// object's subtree paints at that point counts: a page-wide tap layer
  /// that draws a banner at the top covers nothing at a point below it.
  /// Without it (the tap gate, [_judgeLabelPoint]) anything the branch
  /// paints anywhere refuses the label tap — that layer's own handler, not
  /// the label's control, would take a tap there, so being visible at a
  /// point does not make a label tappable at it.
  bool _isTransparentOverlay(
    RenderObject top,
    RenderObject target, {
    Offset? at,
  }) {
    if (_subtreePaints(top, at: at)) return false;

    var current = top.parent;
    while (current is RenderObject) {
      if (_isRenderAncestorOrSelf(current, target)) return true;
      if (_paintsContent(current)) return false;
      current = current.parent;
    }
    return false;
  }

  /// Whether any render object in [root]'s subtree paints content
  /// ([_paintsContent]). With [at], boxes whose global bounds do not
  /// contain that point are skipped with their subtrees — only what is
  /// painted at the point counts. Gives up after [_transparentScanBudget]
  /// render objects and then reports that it paints: a clear view that was
  /// not proven is never claimed.
  bool _subtreePaints(RenderObject root, {Offset? at}) {
    var budget = _transparentScanBudget;
    var paints = false;
    void scan(RenderObject ro) {
      if (paints) return;
      if (budget-- <= 0) {
        paints = true;
        return;
      }
      if (at != null && ro is RenderBox && ro.hasSize) {
        final bounds = ro.localToGlobal(Offset.zero) & ro.size;
        if (!bounds.contains(at)) return;
      }
      if (_paintsContent(ro)) {
        paints = true;
        return;
      }
      ro.visitChildren(scan);
    }

    scan(root);
    return paints;
  }

  /// Whether [ro] paints visible content of its own (text, images,
  /// decoration, fill, platform views…) rather than only passing pointers
  /// or layout through.
  bool _paintsContent(RenderObject ro) {
    // An empty field paints only its cursor: the hint text under it shows
    // through, and a tap on the hint is a tap on the field.
    if (ro is RenderEditable) {
      return ro.text?.toPlainText().isNotEmpty ?? false;
    }
    if (ro is RenderParagraph ||
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
}

/// How much of an element is uncovered (see [TreeWalkerCoverage._coverage]).
enum _Coverage { clear, partial, covered }
