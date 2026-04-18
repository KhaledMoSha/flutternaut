import 'package:flutter/foundation.dart';

/// Result of a wait/poll operation performed by the bridge.
@immutable
class WaitResult {
  /// Whether the condition was met before the timeout.
  final bool success;

  /// How long the poll ran before completing or timing out.
  final int elapsedMs;

  /// Creates a [WaitResult].
  const WaitResult({
    required this.success,
    required this.elapsedMs,
  });

  /// Serializes this result to a JSON map.
  Map<String, dynamic> toJson() => {
        'success': success,
        'elapsed_ms': elapsedMs,
      };

  @override
  String toString() =>
      'WaitResult(success: $success, elapsed: ${elapsedMs}ms)';
}
