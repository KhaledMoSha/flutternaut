part of 'gesture_dispatcher.dart';

/// Revealing a target before a gesture: the one scroll a person would make
/// to bring it into view, never a wait.
extension GestureDispatcherReveal on GestureDispatcher {
  /// Best-effort scroll of [target] into view, the way a user could. No-op
  /// when the target has no laid-out box (e.g. not yet built in a lazy list —
  /// that stays the job of `scroll_until_visible`). The hit-test gate that
  /// follows is the authority on whether the target ended up reachable.
  ///
  /// Two rules keep this from moving the screen under the test:
  ///
  ///  * A reachable target is left where it is; so is a blocked or hidden one
  ///    ([TapRefusal.inputBlocked], [TapRefusal.hiddenRoute]) and one whose
  ///    page is mid transition ([TapRefusal.transitioning]). A covered one
  ///    is centred, not put at the leading edge it was covered at (the iOS
  ///    status-bar tap area over a row scrolled to the top).
  ///  * Only ancestors the **user** could scroll are scrolled. An ancestor
  ///    whose physics refuse user offsets (`NeverScrollableScrollPhysics`) is
  ///    app-controlled: debug overlays such as `requests_inspector` wrap the
  ///    whole app in such a `PageView`, and `Scrollable.ensureVisible` — which
  ///    scrolls *every* ancestor so the target sits at its leading edge —
  ///    dragged the hidden overlay page into view on every tap.
  Future<void> _ensureVisible(Element target) async {
    final renderObject = target.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final double alignment;
    switch (walker.tapReach(target)) {
      case TapReachable():
        return;
      // Blocked (a list still scrolling), on a hidden page, or mid route
      // transition (the page is still sliding in): scrolling would move a
      // screen nobody acts on yet; the gate refuses and the step re-tries.
      case TapRefused(refusal: TapRefusal.inputBlocked):
      case TapRefused(refusal: TapRefusal.hiddenRoute):
      case TapRefused(refusal: TapRefusal.transitioning):
        return;
      case TapRefused(:final refusal):
        alignment = refusal == TapRefusal.covered ? 0.5 : 0.0;
    }

    // Same ancestor walk as Scrollable.ensureVisible: the first scrollable
    // reveals the target, each outer one reveals the scrollable inside it.
    // Collected synchronously, so no BuildContext crosses an async gap.
    final reveals = <(ScrollPosition, RenderObject, RenderObject?)>[];
    BuildContext context = target;
    RenderObject? targetRenderObject;
    var scrollable = Scrollable.maybeOf(context);
    while (scrollable != null) {
      final position = scrollable.position;
      final object = context.findRenderObject();
      if (object != null && position.physics.shouldAcceptUserOffset(position)) {
        reveals.add((position, object, targetRenderObject));
      }
      targetRenderObject ??= object;
      context = scrollable.context;
      scrollable = Scrollable.maybeOf(context);
    }

    final scrolled = reveals.isNotEmpty;
    for (final (position, object, innerTarget) in reveals) {
      await position.ensureVisible(
        object,
        alignment: alignment,
        duration: Duration.zero,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        targetRenderObject: innerTarget,
      );
    }
    if (scrolled) await _pumpFrames(count: 3);
  }
}
