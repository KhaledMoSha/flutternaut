import 'package:flutter/foundation.dart';

/// Result of a wait/poll operation performed by the bridge.
@immutable
class WaitResult {
  /// Whether the condition was met before the timeout.
  final bool success;

  /// How long the poll ran before completing or timing out.
  final int elapsedMs;

  /// Why the condition did not hold at the last check (e.g. `"up for it"
  /// exists but is at opacity 0.00`). Only set on failure, and only by
  /// waits that can explain themselves.
  final String? detail;

  /// Creates a [WaitResult].
  const WaitResult({
    required this.success,
    required this.elapsedMs,
    this.detail,
  });

  /// Serializes this result to a JSON map.
  Map<String, dynamic> toJson() => {
        'success': success,
        'elapsed_ms': elapsedMs,
        if (detail != null) 'detail': detail,
      };

  @override
  String toString() => 'WaitResult(success: $success, elapsed: ${elapsedMs}ms'
      '${detail != null ? ', detail: $detail' : ''})';
}
