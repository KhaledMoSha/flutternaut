# Flutternaut

A concise Semantics wrapper for Flutter test automation with [Flutternaut AI](https://flutternaut.app).

Wrap your widgets with `Flutternaut` to make them discoverable by the Flutternaut test engine. Named constructors auto-configure the right semantics flags for common UI patterns.

## Installation

Add the package to your Flutter project:

```bash
flutter pub add flutternaut
```

Install the generator CLI globally:

```bash
dart pub global activate flutternaut_generator
```

Then import it in your Dart code:

```dart
import 'package:flutternaut/flutternaut.dart';
```

## Usage

### Buttons

```dart
Flutternaut.button(
  label: 'login_button',
  child: ElevatedButton(onPressed: _login, child: Text('Login')),
)
```

### Text inputs

```dart
Flutternaut.input(
  label: 'email_input',
  child: TextField(controller: _emailController),
)
```

### Dynamic text

Pass `value` so the test engine can read the current text content.

```dart
Flutternaut.text(
  label: 'todo_count',
  value: '${todos.length} items',
  child: Text('${todos.length} items'),
)
```

### List items

```dart
Flutternaut.item(
  label: 'todo_text_$index',
  value: todo.text,
  child: ListTile(title: Text(todo.text)),
)
```

### Checkboxes

```dart
Flutternaut.checkbox(
  label: 'check_$index',
  checked: todo.completed,
  child: Checkbox(value: todo.completed, onChanged: _toggle),
)
```

### Default constructor

For elements that don't fit other categories.

```dart
Flutternaut(
  label: 'drag_target',
  container: true,
  child: DragTarget<String>(...),
)
```

## Constructors

| Constructor | `container` | `excludeSemantics` | `button` | Use for |
|---|---|---|---|---|
| `Flutternaut(...)` | `true` | `false` | `false` | Drag targets, scroll containers, generic wrappers |
| `Flutternaut.input(...)` | `false` | `true` | `false` | TextField, TextFormField |
| `Flutternaut.button(...)` | `true` | `false` | `true` | ElevatedButton, IconButton, GestureDetector |
| `Flutternaut.text(...)` | `false` | `true` | `false` | Counters, status labels, error messages |
| `Flutternaut.item(...)` | `true` | `false` | `false` | ListTile, list items |
| `Flutternaut.checkbox(...)` | `true` | `false` | `false` | Checkbox, Switch |

- `excludeSemantics: true` (`.input`, `.text`) — gives the element a clean accessibility label by hiding child widget semantics.
- `excludeSemantics: false` (`.button`, `.item`, `.checkbox`, default) — preserves child semantics so interactive actions (tap, check) propagate correctly.

## The `description` parameter

All constructors accept an optional `description` for AI context. It is **not** passed to `Semantics` — it exists purely as metadata for the [Flutternaut Generator](https://pub.dev/packages/flutternaut_generator) and AI test authoring.

```dart
Flutternaut.text(
  label: 'flow_item_count',
  description: 'Shows total number of items in the list',
  value: '${items.length} items',
  child: Text('${items.length} items'),
)
```

Most elements don't need it — labels like `login_button` or `email_input` are self-explanatory. Use `description` for ambiguous labels where the AI might not understand the element's purpose.

## View grouping with `@FlutternautView`

Annotate your screen widgets with `@FlutternautView` to group elements by view in the generated keys file. This helps the AI understand which elements belong to which screen — when a user says "test the login view", the AI knows exactly which labels to use.

```dart
@FlutternautView('Login')
class LoginScreen extends StatefulWidget {
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}
```

The annotation automatically propagates from a `StatefulWidget` to its `State` class — elements inside `_LoginScreenState` will have `"view": "Login"` in the keys file.

For widgets in separate files that belong to the same view, repeat the annotation:

```dart
// In login_form.dart
@FlutternautView('Login')
class LoginForm extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Flutternaut.input(label: 'email_input', child: TextField());
  }
}
```

The generated keys file groups elements by view:

```json
{
  "elements": [
    {"label": "email_input", "type": "input", "view": "Login", "file": "lib/login_form.dart"},
    {"label": "login_button", "type": "button", "view": "Login", "file": "lib/login_screen.dart"}
  ]
}
```

## Key generation

Run the [Flutternaut Generator](https://pub.dev/packages/flutternaut_generator) to extract all labels into a `flutternaut_keys.json` file:

```bash
dart run flutternaut
```

This JSON is fed to the AI so it only targets real elements in your app.

## How it works

`Flutternaut` wraps Flutter's `Semantics` widget:

- `label` → `Semantics.label` — the accessibility ID used by Appium to find elements
- `value` → `Semantics.value` — dynamic text readable by the test engine
- `button` → `Semantics.button` — marks interactive controls
- `container` → `Semantics.container` — marks semantic containers (list items)
- `checked` → `Semantics.checked` — tracks checkbox/toggle state
- `excludeSemantics` — `true` for `.input`/`.text` (clean label), `false` for `.button`/`.item`/`.checkbox` (preserves child actions)

## Requirements

- Flutter >= 3.24.0
- Dart >= 3.5.0
