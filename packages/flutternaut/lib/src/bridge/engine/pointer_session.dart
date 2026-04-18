import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Manages a single synthetic pointer's lifecycle from down to up.
///
/// Created by [GestureDispatcher] after sending the [PointerAddedEvent]
/// and [PointerDownEvent]. The session handles subsequent moves and the
/// final up + remove, using a consistent [pointer] id and time base.
///
/// Internal to the bridge — not part of the public API.
class PointerSession {
  /// The synthetic pointer id (high enough to avoid conflicts with real pointers).
  final int pointer;

  /// The [PointerDownEvent] timestamp — all subsequent events use
  /// [startTime] + [Duration] offsets for consistent timing.
  final Duration startTime;

  /// Creates a [PointerSession]. The caller is responsible for sending
  /// the [PointerAddedEvent] and [PointerDownEvent] before using this
  /// session's [moveTo] and [end] methods.
  PointerSession({required this.pointer, required this.startTime});

  /// Sends a [PointerMoveEvent] at [position] with [delta] at
  /// `startTime + timeOffset`.
  void moveTo(Offset position, Offset delta, Duration timeOffset) {
    GestureBinding.instance.handlePointerEvent(PointerMoveEvent(
      pointer: pointer,
      position: position,
      delta: delta,
      timeStamp: startTime + timeOffset,
      kind: PointerDeviceKind.touch,
    ));
  }

  /// Ends the pointer: sends [PointerUpEvent] and then [PointerRemovedEvent]
  /// after one frame has been pumped.
  Future<void> end(
    Offset position, {
    Duration timeOffset = const Duration(milliseconds: 50),
  }) async {
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(
      pointer: pointer,
      position: position,
      timeStamp: startTime + timeOffset,
      kind: PointerDeviceKind.touch,
    ));
    await WidgetsBinding.instance.endOfFrame;
    GestureBinding.instance.handlePointerEvent(PointerRemovedEvent(
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
    ));
  }
}
