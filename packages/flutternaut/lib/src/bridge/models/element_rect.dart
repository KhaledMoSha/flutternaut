import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Screen position and size of a widget in global coordinates.
@immutable
class ElementRect {
  /// The x-coordinate of the widget's top-left corner.
  final double x;

  /// The y-coordinate of the widget's top-left corner.
  final double y;

  /// The width of the widget.
  final double width;

  /// The height of the widget.
  final double height;

  /// Creates an [ElementRect] with the given position and size.
  const ElementRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// The center point of this rect.
  Offset get center => Offset(x + width / 2, y + height / 2);

  /// Creates an [ElementRect] from a JSON map.
  factory ElementRect.fromJson(Map<String, dynamic> json) {
    return ElementRect(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['w'] as num).toDouble(),
      height: (json['h'] as num).toDouble(),
    );
  }

  /// Serializes this rect to a JSON map.
  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'w': width,
        'h': height,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ElementRect &&
          x == other.x &&
          y == other.y &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'ElementRect($x, $y, $width x $height)';
}
