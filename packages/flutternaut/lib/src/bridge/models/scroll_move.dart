import 'package:flutter/foundation.dart';

/// What a swipe did to the scroll position of the `Scrollable` it acted on —
/// the `moved` and `room` fields of a `/swipe` response.
///
/// A fact, not a verdict: the bridge never refuses a swipe after the fact.
/// A list that had [room] and [moved] 0 px (its physics refuse user drags,
/// or a paged list snapped back) is for the caller to judge.
@immutable
class ScrollMove {
  /// How far the scroll position changed along its axis, in absolute
  /// logical pixels, from just before the gesture to the moment the
  /// response is built — the most any list sharing the drag moved: the
  /// list itself, a list it sits in, or one inside it on the same axis (a
  /// `NestedScrollView` scrolls its header list before the inner one). A
  /// fling (`fling: true`) may carry the list further afterwards.
  final double moved;

  /// Whether the list could move in the swipe's direction before the
  /// gesture: it had content dimensions and more than 1 logical px left
  /// before the edge the swipe pushes it toward ("up"/"left" advance the
  /// offset, "down"/"right" retreat it) — the engine catalog's own end
  /// rule, so a list resting a fraction of a pixel short of its end has no
  /// room.
  final bool room;

  /// Creates a [ScrollMove].
  const ScrollMove({required this.moved, required this.room});

  /// The fields a `/swipe` response adds: `moved` (number) and `room`
  /// (bool).
  Map<String, dynamic> toJson() => {'moved': moved, 'room': room};

  @override
  String toString() => 'ScrollMove(moved: $moved, room: $room)';
}
