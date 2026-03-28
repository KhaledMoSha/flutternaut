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

| Constructor | Semantics flags | Use for |
|---|---|---|
| `Flutternaut(...)` | Manual control | Drag targets, scroll containers, generic wrappers |
| `Flutternaut.input(...)` | — | TextField, TextFormField |
| `Flutternaut.button(...)` | `button: true` | ElevatedButton, IconButton, GestureDetector |
| `Flutternaut.text(...)` | — | Counters, status labels, error messages |
| `Flutternaut.item(...)` | `container: true` | ListTile, list items |
| `Flutternaut.checkbox(...)` | `container: true`, `checked` | Checkbox, Switch |

All constructors set `excludeSemantics: true` to prevent child semantics from polluting accessibility IDs.

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
- `excludeSemantics: true` — always set, prevents child semantics from merging into the parent's accessibility ID

## Requirements

- Flutter >= 3.24.0
- Dart >= 3.5.0
