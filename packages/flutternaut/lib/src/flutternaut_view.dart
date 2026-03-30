/// Annotation that groups all [Flutternaut] widgets inside this class
/// under a named view in the generated keys file.
///
/// The generator scans for this annotation on widget classes and sets the
/// `view` field on all elements found within. The AI prompt then groups
/// labels by view so users can say "test the login view" and the AI knows
/// which elements belong there.
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
///       Flutternaut.input(label: 'email_input', child: TextField()),
///       Flutternaut.button(label: 'login_button', child: ElevatedButton(...)),
///     ]);
///   }
/// }
/// ```
class FlutternautView {
  /// The view name used for grouping in the keys file.
  final String name;

  const FlutternautView(this.name);
}
