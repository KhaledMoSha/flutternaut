part of '../tree_walker.dart';

/// The control a state assertion checks, or why there is none
/// ([TreeWalkerControls.resolveStateTarget]).
sealed class StateTarget {
  const StateTarget();
}

/// The locator names [control], which is [enabled]; [description] names it
/// in messages (`FilledButton "Log in"`).
final class StateFound extends StateTarget {
  /// The control that owns the matched widget.
  final Element control;

  /// Whether [control] is enabled.
  final bool enabled;

  /// How [control] reads in a message.
  final String description;

  /// Creates a found target.
  const StateFound(this.control, this.enabled, this.description);
}

/// Nothing the assertion can check is there right now — no match, only
/// hidden ones, an `nth` out of range, or several controls (ambiguous).
/// [reason] says which; the screen may change, so it can be re-checked.
final class StateMissing extends StateTarget {
  /// Why there is no target.
  final String reason;

  /// Creates a missing target.
  const StateMissing(this.reason);
}

/// The locator names a widget that is not part of any control — a caption,
/// a static row — so "enabled" means nothing for it. Final: waiting does
/// not turn a caption into a button.
final class StateNotAControl extends StateTarget {
  /// The locator, as messages name it (`text "Total"`).
  final String desc;

  /// Creates a not-a-control target.
  const StateNotAControl(this.desc);

  /// The reason a state assertion reports.
  String get reason => '$desc is not part of any control (a button, switch, '
      'checkbox, slider, field or a tile with onTap), so it is neither '
      'enabled nor disabled — address the control itself';
}

/// Why a tap cannot reach a target right now ([TreeWalkerTap.tapReach]).
enum TapRefusal {
  /// The target has no laid-out, on-screen geometry.
  notLaidOut,

  /// The target is laid out but wholly outside the screen, or clipped away
  /// by the view it scrolls in (a page of a `PageView` that is not showing).
  offScreen,

  /// Nothing but the view receives pointers at the target: a route
  /// transition is in progress (every route scope ignores pointers).
  nothingHit,

  /// Something painted over the target would take the tap.
  covered,

  /// The target is visible but takes no input right now: the pointer is
  /// swallowed before it gets there (an `AbsorbPointer`, the Navigator right
  /// after a navigation, a list that is still scrolling).
  inputBlocked,
}

/// Where a tap reaches a target, or why it cannot ([TreeWalkerTap.tapReach]).
sealed class TapReach {
  const TapReach();
}

/// A tap at [point] reaches the target.
final class TapReachable extends TapReach {
  /// The global logical point to tap.
  final Offset point;

  /// Creates a reachable verdict at [point].
  const TapReachable(this.point);
}

/// A tap cannot reach the target: [refusal] says why, [blocker] names what
/// takes the pointer instead, [center] is the target's centre (null when it
/// has none).
final class TapRefused extends TapReach {
  /// Why the tap is refused.
  final TapRefusal refusal;

  /// What takes the pointer instead, e.g. `AbsorbPointer(SplashSurface)`.
  final String blocker;

  /// The target's centre, when it has on-screen geometry.
  final Offset? center;

  /// Creates a refused verdict.
  const TapRefused(this.refusal, {required this.blocker, this.center});
}
