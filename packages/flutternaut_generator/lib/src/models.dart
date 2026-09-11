import 'dart:convert';

/// Role of a key inside a row, used by AI prompts and the editor to decide
/// how to interact with it.
enum KeyRole {
  /// Text-displaying widget — `Text`, `RichText`, `EditableText`, `TextField`.
  /// Used as the search target for `find_in_list`.
  field,

  /// Interactive widget — has `onPressed`, `onTap`, `onChanged`, etc.
  /// Tappable in sub-steps.
  action,

  /// Anything else — containers, decorations, layout helpers.
  other;

  String toJson() => name;
}

/// A single ValueKey'd widget on a screen, captured from the AST.
class KeyElement {
  /// The key string. May contain `{index}` placeholders if dynamic.
  final String label;

  /// The Flutter widget type that carries this `ValueKey`
  /// (e.g. `"Checkbox"`, `"ElevatedButton"`, `"Text"`).
  final String? widget;

  /// Inferred interaction role.
  final KeyRole role;

  /// `true` if [label] contains an interpolation placeholder (`{index}`,
  /// `{name}`, etc).
  final bool isDynamic;

  /// Source file where this key was found, relative to the project root.
  final String file;

  const KeyElement({
    required this.label,
    required this.role,
    required this.file,
    this.widget,
    this.isDynamic = false,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'role': role.toJson(),
        if (widget != null) 'widget': widget,
        if (isDynamic) 'dynamic': true,
        'file': file,
      };
}

/// A list-row group: a set of dynamic [KeyElement]s all parameterised by
/// the same iteration index.
///
/// Rows enable both the AI and the visual editor to reason about a row as
/// a unit (find by field, then act via siblings) instead of inferring the
/// grouping from key suffixes.
class KeysRow {
  /// Stable identifier for the row, derived from the search prefix or the
  /// row class name.
  final String name;

  /// Custom row widget class name, if the row's keys live in a separate
  /// widget class (e.g. `TodoTile`). Absent for inline `itemBuilder` rows.
  final String? rowClass;

  /// `find_in_list` / `iterate_over_list` prefix — the first `field`
  /// member's label with `{index}` stripped. May be `null` if the row has
  /// no field member.
  final String? searchPrefix;

  /// Always `"{index}"` for v1. Reserved for future nested-iteration.
  final String indexToken;

  /// Members of the row, in the order they appear in source.
  final List<KeyElement> members;

  /// Source file where the row was detected (for inline rows, the screen
  /// file; for custom-row-widget rows, the row widget's file).
  final String file;

  const KeysRow({
    required this.name,
    required this.searchPrefix,
    required this.indexToken,
    required this.members,
    required this.file,
    this.rowClass,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        if (rowClass != null) 'row_class': rowClass,
        'search_prefix': searchPrefix,
        'index_token': indexToken,
        'members': members.map((m) => m.toJson()).toList(),
        'file': file,
      };
}

/// All keys belonging to a single screen, partitioned into list-rows and
/// flat (non-row) elements.
class ViewKeys {
  /// Detected list-row groups on this screen.
  final List<KeysRow> rows;

  /// Keys that are not part of any detected list row.
  final List<KeyElement> elements;

  const ViewKeys({
    this.rows = const [],
    this.elements = const [],
  });

  Map<String, dynamic> toJson() => {
        'rows': rows.map((r) => r.toJson()).toList(),
        'elements': elements.map((e) => e.toJson()).toList(),
      };
}

/// The full output structure written to `flutternaut_keys.json`.
class KeysOutput {
  /// UTC timestamp of the generation run.
  final DateTime generatedAt;

  /// Name of the Flutter package being scanned (from its `pubspec.yaml`).
  final String package;

  /// Keys grouped by `@FlutternautView` value. Keys outside any annotated
  /// class go under the `"_ungrouped"` view so nothing is silently
  /// dropped.
  final Map<String, ViewKeys> views;

  const KeysOutput({
    required this.generatedAt,
    required this.package,
    required this.views,
  });

  Map<String, dynamic> toJson() => {
        'generated_at': generatedAt.toUtc().toIso8601String(),
        'package': package,
        'views': {
          for (final entry in views.entries) entry.key: entry.value.toJson(),
        },
      };

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(toJson());
}
