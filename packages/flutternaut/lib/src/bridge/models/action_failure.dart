import 'package:flutter/foundation.dart';

/// Thrown by the gesture engine when an action cannot be performed
/// *safely* — the target is missing, ambiguous, or not visible and
/// tappable at the point we would act on.
///
/// Carries a human-readable [message] that the bridge surfaces verbatim
/// in the response envelope's `error` field, so the test engine reports
/// the real reason (occlusion, ambiguity, off-screen) instead of a
/// generic failure. Failing loudly here is deliberate: the bridge must
/// never report success when the wrong widget — or nothing — was hit.
@immutable
class ActionFailure implements Exception {
  /// Human-readable explanation of why the action could not be performed.
  final String message;

  /// Creates an [ActionFailure] with a descriptive [message].
  const ActionFailure(this.message);

  @override
  String toString() => 'ActionFailure: $message';
}
