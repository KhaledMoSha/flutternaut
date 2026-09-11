# flutternaut_generator

[![pub package](https://img.shields.io/pub/v/flutternaut_generator.svg)](https://pub.dev/packages/flutternaut_generator)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A CLI tool that walks a Flutter project's AST for classes annotated with `@FlutternautView`, collects every `ValueKey` inside each one, and writes them to a JSON file grouped by view. The Flutternaut desktop **Test Editor** reads this file to offer per-screen target dropdowns and row-aware list helpers.

> The AI authoring flow does **not** need this file — it reads the live widget tree through the [flutternaut](https://pub.dev/packages/flutternaut) bridge. Generate keys when you hand-author tests in the visual editor.

## Installation

```bash
flutter pub add --dev flutternaut_generator
```

Or activate globally:

```bash
dart pub global activate flutternaut_generator
```

The `flutternaut` package also ships the generator as an executable (`dart run flutternaut`).

## Usage

Run from your Flutter project root:

```bash
# As a dev dependency
dart run flutternaut_generator

# Global activation
flutternaut_generator .

# Custom output path
dart run flutternaut_generator -o keys.json
```

## Configuration

Configure the output path in your project's `pubspec.yaml`:

```yaml
flutternaut:
  output: lib/generated/flutternaut_keys.json
```

The legacy `flutternaut_generator:` key is still read as a fallback. The `-o` CLI flag takes priority over the pubspec config. If neither is set, the file is written to `flutternaut_keys.json` in the project root.

## What it does

1. Scans every `.dart` file under `lib/` (fails if `lib/` is missing).
2. Finds every class annotated `@FlutternautView('ScreenName')` and files the keys inside it under that view. Keys outside any annotated class go to `_ungrouped`. Annotation arguments may be string literals or static const references (`AppRoutes.trip`).
3. Collects `ValueKey('...')` (and bare `Key('...')`) literals, looking through `KeyedSubtree` wrappers to the real child. Captures the owning widget type and infers a role:
   - `field` for `Text`, `RichText`, `EditableText`, `TextField`, `TextFormField`, `SelectableText`
   - `action` for widgets with `onPressed`, `onTap`, `onLongPress`, `onChanged`, `onSubmitted` or `onDoubleTap`
   - `other` otherwise
4. **Detects list rows.** Dynamic keys inside an `itemBuilder` / `separatorBuilder` / `pageBuilder` closure (or inside a custom row widget that receives the loop index, e.g. `TodoTile(index: index)`) are grouped into a row with a `search_prefix` (the shortest field-role member label, `{index}` stripped), `row_class`, `index_token` and `members`.
5. Rewrites interpolated keys as patterns: `'todo_$index'` → `todo_{index}`, `'item_${name}_btn'` → `item_{name}_btn`. Index-like variables (`index`, `i`, `idx`, `n`, `position`, `pos`) become `{index}`; complex expressions such as `${item.id}` also collapse to `{index}`.
6. Writes `flutternaut_keys.json`.

## Output format

```json
{
  "generated_at": "2026-04-25T12:00:00.000Z",
  "package": "my_flutter_app",
  "views": {
    "Login": {
      "rows": [],
      "elements": [
        { "label": "email_input",  "role": "field",  "widget": "TextField",      "file": "lib/screens/login_screen.dart" },
        { "label": "login_button", "role": "action", "widget": "ElevatedButton", "file": "lib/screens/login_screen.dart" }
      ]
    },
    "Home": {
      "rows": [
        {
          "name": "todo_row",
          "row_class": "TodoTile",
          "search_prefix": "todo_text_",
          "index_token": "{index}",
          "members": [
            { "label": "todo_text_{index}", "role": "field",  "widget": "Text",       "dynamic": true, "file": "lib/widgets/todo_tile.dart" },
            { "label": "delete_{index}",    "role": "action", "widget": "IconButton", "dynamic": true, "file": "lib/widgets/todo_tile.dart" }
          ],
          "file": "lib/widgets/todo_tile.dart"
        }
      ],
      "elements": [
        { "label": "todo_input", "role": "field",  "widget": "TextField",      "file": "lib/screens/home_screen.dart" },
        { "label": "add_button", "role": "action", "widget": "ElevatedButton", "file": "lib/screens/home_screen.dart" }
      ]
    }
  }
}
```

`dynamic` is emitted only when `true`; `widget` is omitted when it cannot be inferred; `search_prefix` is `null` for rows with no field-role member.

## How it's used

1. Annotate your screen classes with `@FlutternautView('ScreenName')`.
2. Add `ValueKey`s to widgets the editor should target (typically the text-less or ambiguous ones).
3. Run `dart run flutternaut_generator`.
4. Import the file on the desktop app's **Keys** screen and pick it as the Keys Project in the Test Editor.

## Requirements

- Dart `>=3.5.0 <4.0.0`

## License

MIT
