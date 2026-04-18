import 'package:flutter/foundation.dart';

import 'element_info.dart';

/// Result of a visibility check on a widget.
@immutable
class VisibilityResult {
  /// Whether the widget exists in the widget tree.
  final bool exists;

  /// Whether the widget is visible within the screen viewport.
  final bool visible;

  /// Full element info if the widget was found.
  final ElementInfo? info;

  /// Creates a [VisibilityResult].
  const VisibilityResult({
    required this.exists,
    required this.visible,
    this.info,
  });

  /// Serializes this result to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'exists': exists,
      'visible': visible,
      if (info?.rect != null) 'rect': info!.rect!.toJson(),
      if (info?.text != null) 'text': info!.text,
      if (info?.type != null && info!.type.isNotEmpty) 'type': info!.type,
    };
  }

  @override
  String toString() => 'VisibilityResult(exists: $exists, visible: $visible)';
}
