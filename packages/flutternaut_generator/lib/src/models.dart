import 'dart:convert';

/// A single Flutternaut-wrapped element found in source code.
class FlutternautElement {
  /// The accessibility label (e.g. "login_button").
  final String label;

  /// The constructor type: "element", "input", "button", "text", "item", or "checkbox".
  final String type;

  /// Optional human-readable description for AI context.
  final String? description;

  /// Whether the label contains string interpolation (e.g. "todo_$index").
  final bool isDynamic;

  /// The view/screen this element belongs to (from @FlutternautView annotation).
  final String? view;

  /// The relative file path where this element was found.
  final String file;

  const FlutternautElement({
    required this.label,
    required this.type,
    this.description,
    this.isDynamic = false,
    this.view,
    required this.file,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'label': label,
      'type': type,
    };
    if (isDynamic) {
      map['dynamic'] = true;
    }
    if (view != null) {
      map['view'] = view;
    }
    map['description'] = description;
    map['file'] = file;
    return map;
  }
}

/// The full output structure written to flutternaut_keys.json.
class KeysOutput {
  final DateTime generatedAt;
  final String package;
  final List<FlutternautElement> elements;

  const KeysOutput({
    required this.generatedAt,
    required this.package,
    required this.elements,
  });

  Map<String, dynamic> toJson() => {
        'generated_at': generatedAt.toUtc().toIso8601String(),
        'package': package,
        'elements': elements.map((e) => e.toJson()).toList(),
      };

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(toJson());
}
