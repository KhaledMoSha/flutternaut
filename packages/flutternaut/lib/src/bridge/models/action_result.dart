import 'package:flutter/foundation.dart';

/// Result of a gesture or action dispatched by the bridge.
///
/// All gesture endpoints (tap, swipe, drag, etc.) return this shape.
/// Endpoint-specific metadata (e.g. direction, count) goes in [extras].
@immutable
class ActionResult {
  /// Whether the action was dispatched successfully.
  ///
  /// For element-targeting actions, this is `false` when the element
  /// couldn't be found or the gesture couldn't be applied.
  final bool success;

  /// The name of the action that was performed (e.g. 'tap', 'scroll').
  final String action;

  /// Endpoint-specific metadata merged into the response.
  ///
  /// Examples:
  /// - `{'direction': 'up'}` for swipe
  /// - `{'count': 2}` for multi_tap
  /// - `{'url': '...'}` for open_deeplink
  /// - `{'key': '...'}` or `{'text': '...'}` to echo back the locator
  final Map<String, dynamic>? extras;

  /// Creates an [ActionResult].
  const ActionResult({
    required this.success,
    required this.action,
    this.extras,
  });

  /// Serializes this result to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'success': success,
      'action': action,
      if (extras != null) ...extras!,
    };
  }

  @override
  String toString() =>
      'ActionResult(action: $action, success: $success, extras: $extras)';
}
