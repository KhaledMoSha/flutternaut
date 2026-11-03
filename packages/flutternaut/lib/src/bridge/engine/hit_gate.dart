part of 'gesture_dispatcher.dart';

/// The hit-test gate every tap-like gesture passes before a pointer goes
/// down: the target must be reachable by a tap right now, and no route
/// transition may be running (bridge protocol 1.11.0). A refusal dispatches
/// nothing; the engine re-tries the step for its timeout, so a refusal
/// naming a passing state (a transition, a splash, a scroll) resolves on its
/// own.
extension GestureDispatcherHitGate on GestureDispatcher {
  /// Confirms the matched [element] is tappable, returning the point to tap,
  /// or throwing [ActionFailure] saying why not ([TreeWalkerTap.tapReach]).
  /// The engine re-tries a refused step for its timeout: a refusal naming a
  /// passing state (a splash, a scroll, a navigation) resolves on its own.
  Offset _confirmHittable(Element element, String desc) {
    switch (walker.tapReach(element)) {
      case TapReachable(:final point):
        return point;
      case TapRefused(:final refusal, :final blocker, :final center):
        final at = center == null ? '' : ' at ${_fmtOffset(center)}';
        throw ActionFailure(switch (refusal) {
          TapRefusal.notLaidOut =>
            '$desc exists but has no on-screen geometry (not laid out).',
          TapRefusal.offScreen => '$desc is present$at but not on screen: '
              'it is $blocker.',
          TapRefusal.nothingHit =>
            '$desc is present$at but no widget receives pointers there.',
          TapRefusal.transitioning => '$desc is present$at but $blocker — '
              'a tap waits for it to end.',
          TapRefusal.covered => '$desc is present$at but a tap there would '
              'reach $blocker instead — it is occluded or off-screen.',
          TapRefusal.hiddenRoute => '$desc $blocker.',
          TapRefusal.inputBlocked => '$desc is visible$at but takes no taps '
              'right now: $blocker swallows the pointer before it gets '
              'there.',
        });
    }
  }

  /// Refuses a coordinate tap at [at] while a route transition runs (see
  /// [TreeWalkerRoutes.transitionRefusal]): the page under the point is
  /// still moving.
  void _refuseWhileTransitioning(Offset at) {
    final transition = walker.transitionRefusal();
    if (transition == null) return;
    throw ActionFailure(
      'Point ${_fmtOffset(at)} was not tapped: $transition — a tap waits '
      'for it to end.',
    );
  }
}
