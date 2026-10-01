import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/action_failure.dart';

/// Schedules work on the main UI thread via [WidgetsBinding] post-frame callbacks.
///
/// The bridge HTTP server runs on the main isolate, but widget tree access
/// must happen during a stable frame. This runner ensures operations execute
/// after the current frame's layout and paint are complete.
class MainThreadRunner {
  /// Why the app is not drawing frames right now, or null when it is.
  ///
  /// Flutter stops producing frames while the app is hidden, paused or
  /// detached (in the background, behind another app): a post-frame
  /// callback scheduled then never fires, so work handed to [run] would
  /// wait without end. Pollers read this to keep waiting for the app to
  /// come back instead of failing.
  String? get notDrawingReason {
    final binding = WidgetsBinding.instance;
    if (binding.framesEnabled) return null;
    final state = binding.lifecycleState?.name ?? 'unknown';
    return 'the app is in the background (lifecycle state: $state) and '
        'draws no frames, so its screen cannot be read or acted on — bring '
        'it to the foreground first';
  }

  /// Runs [fn] in a post-frame callback and returns the result.
  ///
  /// Schedules a frame if needed to ensure the callback fires promptly.
  /// Fails with an [ActionFailure] when the app draws no frames (see
  /// [notDrawingReason]) — the callback would never run.
  Future<T> run<T>(FutureOr<T> Function() fn) {
    final reason = notDrawingReason;
    if (reason != null) return Future<T>.error(ActionFailure(reason));

    final completer = Completer<T>();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<T>.sync(fn).then(
        completer.complete,
        onError: completer.completeError,
      );
    });
    WidgetsBinding.instance.scheduleFrame();

    return completer.future;
  }
}
