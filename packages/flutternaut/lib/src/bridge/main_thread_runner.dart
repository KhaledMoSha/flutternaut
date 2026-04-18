import 'dart:async';

import 'package:flutter/widgets.dart';

/// Schedules work on the main UI thread via [WidgetsBinding] post-frame callbacks.
///
/// The bridge HTTP server runs on the main isolate, but widget tree access
/// must happen during a stable frame. This runner ensures operations execute
/// after the current frame's layout and paint are complete.
class MainThreadRunner {
  /// Runs [fn] in a post-frame callback and returns the result.
  ///
  /// Schedules a frame if needed to ensure the callback fires promptly.
  Future<T> run<T>(FutureOr<T> Function() fn) {
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
