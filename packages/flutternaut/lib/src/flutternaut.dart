import 'package:flutter/widgets.dart';

/// A wrapper widget that configures [Semantics] for Flutternaut test automation.
///
/// Replaces verbose `Semantics(label: ..., container: true, ...)` calls
/// with a concise API. Preserves child semantics by default so interactive
/// widgets (buttons, inputs, checkboxes) keep their actions. Only
/// [Flutternaut.text] sets `excludeSemantics: true` for a clean label.
///
/// Use named constructors for common patterns:
/// - [Flutternaut.input] — text fields
/// - [Flutternaut.button] — buttons and interactive controls (container: true)
/// - [Flutternaut.text] — dynamic text displays (excludes child semantics)
/// - [Flutternaut.item] — list items (container: true)
/// - [Flutternaut.checkbox] — checkable items (container: true + checked)
///
/// The optional [description] parameter provides additional context for the
/// Flutternaut key generator and AI test authoring. It is **not** passed to
/// [Semantics] — it exists purely as metadata.
///
/// Example:
/// ```dart
/// Flutternaut.button(
///   label: 'login_button',
///   child: ElevatedButton(onPressed: _login, child: Text('Login')),
/// )
///
/// Flutternaut.text(
///   label: 'flow_item_count',
///   description: 'Shows total number of items in the list',
///   value: '${items.length} items',
///   child: Text('${items.length} items'),
/// )
/// ```
class Flutternaut extends StatelessWidget {
  /// The accessibility label used by the test engine to find this element.
  final String label;

  /// Optional dynamic value readable by the test engine (e.g. counter text).
  final String? value;

  /// Optional human-readable description for AI context.
  ///
  /// Used by the Flutternaut key generator to provide richer metadata.
  /// Not passed to [Semantics] — purely informational.
  final String? description;

  /// Whether this element is a button (interactive control).
  final bool button;

  /// Whether this element is a semantic container (e.g. list item).
  final bool container;

  /// Whether to exclude child semantics from the tree.
  final bool excludeSemantics;

  /// Whether this element is checked (for checkboxes/toggles).
  final bool? checked;

  /// The child widget to wrap with semantics.
  final Widget child;

  /// Default constructor — applies label + excludeSemantics.
  ///
  /// Use for elements that don't fit other categories (drag targets,
  /// scroll containers, generic wrappers).
  const Flutternaut({
    super.key,
    required this.label,
    this.value,
    this.description,
    this.button = false,
    this.container = true,
    this.excludeSemantics = false,
    this.checked,
    required this.child,
  });

  /// For text input fields (TextField, TextFormField).
  const Flutternaut.input({
    super.key,
    required this.label,
    this.description,
    required this.child,
  })  : value = null,
        button = false,
        container = false,
        excludeSemantics = true,
        checked = null;

  /// For interactive controls (ElevatedButton, IconButton, GestureDetector).
  ///
  /// Auto-sets `button: true` and `container: true`. Preserves child semantics
  /// so the button's `onTap` action propagates — keeping the node clickable.
  ///
  /// The direct child must be the button widget itself. Do not wrap it in
  /// extra containers or padding — this breaks clickability propagation.
  const Flutternaut.button({
    super.key,
    required this.label,
    this.description,
    required this.child,
  })  : value = null,
        button = true,
        container = true,
        excludeSemantics = false,
        checked = null;

  /// For dynamic text displays (counters, status labels, error messages).
  ///
  /// Pass [value] with the dynamic text content so the test engine can read it.
  const Flutternaut.text({
    super.key,
    required this.label,
    this.value,
    this.description,
    required this.child,
  })  : button = false,
        container = false,
        excludeSemantics = true,
        checked = null;

  /// For list items inside ListView/ListTile.
  ///
  /// Auto-sets `container: true` in semantics.
  const Flutternaut.item({
    super.key,
    required this.label,
    this.value,
    this.description,
    required this.child,
  })  : button = false,
        container = true,
        excludeSemantics = false,
        checked = null;

  /// For checkable items (Checkbox, Switch).
  ///
  /// Auto-sets `container: true` and passes [checked] state.
  const Flutternaut.checkbox({
    super.key,
    required this.label,
    required this.checked,
    this.description,
    required this.child,
  })  : value = null,
        button = false,
        container = true,
        excludeSemantics = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      value: value,
      button: button,
      container: container,
      checked: checked,
      excludeSemantics: excludeSemantics,
      child: child,
    );
  }
}
