/// Annotation that groups every `ValueKey` inside this class under a named
/// view in the generated keys file (`flutternaut_keys.json`).
///
/// This annotation is **optional** — the bridge resolves widgets by key or
/// visible text without it. It is only read by `flutternaut_generator` at
/// build time and has **no runtime effect**. Adding or removing it does not
/// change your app's behavior.
///
/// The generator scans for this annotation on widget classes and files the
/// keys found inside under that view (keys outside any annotated class go to
/// `_ungrouped`). The Flutternaut desktop Test Editor uses the grouping to
/// offer per-screen target dropdowns.
///
/// For widgets split across multiple files, repeat the annotation on each
/// class that belongs to the same view.
///
/// Example:
/// ```dart
/// @FlutternautView('Login')
/// class LoginScreen extends StatelessWidget {
///   @override
///   Widget build(BuildContext context) {
///     return Column(children: [
///       TextField(key: const ValueKey('email_input')),
///       ElevatedButton(
///         key: const ValueKey('login_button'),
///         onPressed: _submit,
///         child: const Text('Login'),
///       ),
///     ]);
///   }
/// }
/// ```
class FlutternautView {
  /// The view name used for grouping in the keys file.
  final String name;

  /// Creates a [FlutternautView] annotation with the given view [name].
  const FlutternautView(this.name);
}
