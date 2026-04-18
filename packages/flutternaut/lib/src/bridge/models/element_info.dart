import 'package:flutter/foundation.dart';

import 'element_rect.dart';

/// Information about a widget found in the Flutter widget tree.
@immutable
class ElementInfo {
  /// Whether the element was found.
  final bool found;

  /// The runtime type of the widget (e.g. 'ElevatedButton', 'Text').
  final String type;

  /// The ValueKey string, if the widget has one.
  final String? key;

  /// The text content of the widget (from Text.data or EditableText.controller).
  final String? text;

  /// Whether the widget is in an enabled state (buttons, fields, switches).
  /// Null if the widget type doesn't have an enabled concept.
  final bool? enabled;

  /// Whether the widget is in a checked state (checkboxes, switches).
  /// Null if the widget type doesn't have a checked concept.
  final bool? checked;

  /// The screen position and size of the widget.
  /// Null if the widget's RenderObject isn't laid out.
  final ElementRect? rect;

  /// Creates an [ElementInfo] with the given properties.
  const ElementInfo({
    this.found = true,
    this.type = '',
    this.key,
    this.text,
    this.enabled,
    this.checked,
    this.rect,
  });

  /// An [ElementInfo] representing a not-found result.
  static const notFound = ElementInfo(found: false);

  /// Serializes this element info to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'found': found,
      if (found) 'type': type,
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      if (rect != null) 'rect': rect!.toJson(),
      if (enabled != null) 'enabled': enabled,
      if (checked != null) 'checked': checked,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ElementInfo &&
          found == other.found &&
          type == other.type &&
          key == other.key &&
          text == other.text &&
          enabled == other.enabled &&
          checked == other.checked &&
          rect == other.rect;

  @override
  int get hashCode => Object.hash(found, type, key, text, enabled, checked, rect);

  @override
  String toString() =>
      'ElementInfo(type: $type, key: $key, text: $text, found: $found)';
}
