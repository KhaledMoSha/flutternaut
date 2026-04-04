# Flutternaut Generator

A CLI tool that scans Flutter projects for [Flutternaut](https://pub.dev/packages/flutternaut) widgets and extracts all labels into a structured JSON file. This JSON powers AI-driven test authoring by telling the AI exactly which elements exist in your app.

## Installation

This package is **automatically included** when you add `flutternaut`:

```yaml
dependencies:
  flutternaut: ^0.0.1
```

You can also use it standalone:

```bash
dart pub global activate flutternaut_generator
```

Or add as a dev dependency:

```yaml
dev_dependencies:
  flutternaut_generator: ^0.0.1
```

## Usage

Run from your Flutter project root:

```bash
# If using flutternaut (recommended)
dart run flutternaut

# Global activation
flutternaut_generator .

# As a standalone dev dependency
dart run flutternaut_generator

# Custom output path
dart run flutternaut -o keys.json
```

## Configuration

Configure the output path in your project's `pubspec.yaml`:

```yaml
flutternaut:
  output: lib/generated/flutternaut_keys.json
```

The `flutternaut_generator:` config key is also supported for backwards compatibility.

The `-o` CLI flag takes priority over the pubspec config. If neither is set, defaults to `flutternaut_keys.json` in the project root.

## What it does

1. Scans all `.dart` files in `lib/`
2. Finds all `Flutternaut` widget usages (ignores raw `Semantics`)
3. Extracts: `label`, `description`, constructor type, source file path
4. Detects dynamic labels (e.g. `"todo_$index"`) and rewrites them as patterns (`"todo_{n}"`)
5. Resolves `@FlutternautView` arguments — supports string literals (`'Login'`) and static const references (`AppRoutes.trip`)
6. Outputs `flutternaut_keys.json`

## Output format

```json
{
  "generated_at": "2026-03-10T12:00:00.000Z",
  "package": "my_flutter_app",
  "elements": [
    {
      "label": "email_input",
      "type": "input",
      "description": null,
      "file": "lib/screens/login_screen.dart"
    },
    {
      "label": "login_button",
      "type": "button",
      "description": null,
      "file": "lib/screens/login_screen.dart"
    },
    {
      "label": "error_text",
      "type": "text",
      "description": "Shows validation error when login fails",
      "file": "lib/screens/login_screen.dart"
    },
    {
      "label": "todo_text_{n}",
      "type": "item",
      "dynamic": true,
      "description": null,
      "file": "lib/screens/home_screen.dart"
    }
  ]
}
```

## Type mapping

| Constructor | Output type |
|---|---|
| `Flutternaut(...)` | `"element"` |
| `Flutternaut.input(...)` | `"input"` |
| `Flutternaut.button(...)` | `"button"` |
| `Flutternaut.text(...)` | `"text"` |
| `Flutternaut.item(...)` | `"item"` |
| `Flutternaut.checkbox(...)` | `"checkbox"` |

## Dynamic label detection

Labels containing string interpolation are detected and rewritten as patterns:

| Source code | Output label | Dynamic |
|---|---|---|
| `label: "login_button"` | `login_button` | `false` |
| `label: "todo_$index"` | `todo_{n}` | `true` |
| `label: "item_${name}_btn"` | `item_{name}_btn` | `true` |

Index-like variables (`index`, `i`, `n`, `idx`, `position`, `pos`) are normalized to `{n}`.

## How it's used

1. Run the generator in your Flutter project
2. Upload the `flutternaut_keys.json` to the Flutternaut desktop app
3. When you describe a test in natural language, the AI uses the keys to target real elements
4. The app validates generated test steps against the keys and warns about unknown labels

## Requirements

- Dart >= 3.5.0
