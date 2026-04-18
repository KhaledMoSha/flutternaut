import 'package:flutter/foundation.dart';

/// Result of an assertion check performed by the bridge.
@immutable
class AssertResult {
  /// Whether the assertion passed.
  final bool passed;

  /// Human-readable description of the result.
  final String message;

  /// The actual value found (for text comparison assertions).
  final String? actual;

  /// The expected value (for text comparison assertions).
  final String? expected;

  /// Creates an [AssertResult].
  const AssertResult({
    required this.passed,
    required this.message,
    this.actual,
    this.expected,
  });

  /// Serializes this result to a JSON map.
  Map<String, dynamic> toJson() => {
        'passed': passed,
        'message': message,
        if (actual != null) 'actual': actual,
        if (expected != null) 'expected': expected,
      };

  @override
  String toString() => 'AssertResult(passed: $passed, message: $message)';
}
