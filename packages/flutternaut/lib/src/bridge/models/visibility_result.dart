import 'package:flutter/foundation.dart';

import 'element_info.dart';

/// Result of a visibility check on a widget.
@immutable
class VisibilityResult {
  /// Whether the widget exists in the widget tree.
  final bool exists;

  /// Whether the widget is visible to the user — occlusion-aware:
  /// `onScreen && !obstructed`. An element hidden under a nav bar / app
  /// bar / overlay is **not** visible.
  final bool visible;

  /// Whether the widget's rect intersects the screen viewport, ignoring
  /// occlusion. (`visible` is the occlusion-aware refinement of this.)
  final bool onScreen;

  /// Whether the widget is on screen but covered by a foreign widget
  /// painted on top of its center.
  final bool obstructed;

  /// Full element info if the widget was found.
  final ElementInfo? info;

  /// Creates a [VisibilityResult].
  const VisibilityResult({
    required this.exists,
    required this.visible,
    this.onScreen = false,
    this.obstructed = false,
    this.info,
  });

  /// Serializes this result to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'exists': exists,
      'visible': visible,
      'on_screen': onScreen,
      'obstructed': obstructed,
      if (info?.rect != null) 'rect': info!.rect!.toJson(),
      if (info?.text != null) 'text': info!.text,
      if (info?.type != null && info!.type.isNotEmpty) 'type': info!.type,
    };
  }

  @override
  String toString() =>
      'VisibilityResult(exists: $exists, visible: $visible, '
      'onScreen: $onScreen, obstructed: $obstructed)';
}
