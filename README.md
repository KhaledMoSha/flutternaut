# Flutternaut

Dart & Flutter packages for [Flutternaut](https://flutternaut.app) — AI-powered E2E testing for Flutter apps.

## Packages

| Package | pub.dev | Description |
|---|---|---|
| [flutternaut](packages/flutternaut/) | [![pub](https://img.shields.io/pub/v/flutternaut.svg)](https://pub.dev/packages/flutternaut) | Concise Semantics wrapper for Flutter test automation |
| [flutternaut_generator](packages/flutternaut_generator/) | [![pub](https://img.shields.io/pub/v/flutternaut_generator.svg)](https://pub.dev/packages/flutternaut_generator) | CLI tool that extracts Flutternaut labels into JSON |

## Quick start

```bash
flutter pub add flutternaut
```

This installs both the widget library and the generator CLI. Wrap your widgets:

```dart
import 'package:flutternaut/flutternaut.dart';

Flutternaut.button(
  label: 'login_button',
  child: ElevatedButton(onPressed: _login, child: Text('Login')),
)
```

Then generate the keys file:

```bash
dart run flutternaut
```

## Development

Checks for `packages/flutternaut` (run from that directory):

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze   # the path dependency on flutternaut_generator is reported as
                  # invalid_dependency (a warning) and makes it exit non-zero
flutter test      # includes test/structure (the structure limits below)
```

### Structure limits

`test/structure/structure_test.dart` parses every `.dart` file under `lib/` and `bin/`
(`package:analyzer`, a dev dependency) and fails when the package grows past these limits:

| Limit | Value |
|---|---|
| a function, method, getter or constructor (doc comment and annotations not counted) | ≤ 80 lines |
| a file under `lib/` or `bin/` | ≤ 800 lines |
| a class, mixin, enum, extension or extension type | ≤ 500 lines |
| a library (its file plus all of its `part` files) | ≤ 5,000 lines, ≤ 10 internal imports |
| layering in `lib/src/bridge/` | `models` imports none of the others; `engine` and `router` import only `models`; `handlers` never import `server` |
| global mutable state (a top-level `var`, a `static` field that is not `final`/`const`) | none |

Measures are keyed by the owning library, so moving code between the parts of one library keeps
its keys. Offenders that existed when the rule was introduced are listed in
`test/structure/baseline.json` and may only shrink: a new offender fails, a baselined one that
grew fails, and one that shrank or was fixed fails until its entry is lowered or removed with

```bash
UPDATE_STRUCTURE_BASELINE=1 flutter test test/structure
```

New code never gets a baseline entry: split it instead. `TreeWalker`
(`lib/src/bridge/engine/tree_walker.dart`) shows the pattern: the class keeps its static helpers,
and each concern is an `extension TreeWalker<Concern> on TreeWalker` in a part file under
`tree_walker/`. Inside an extension a static of the class must be written `TreeWalker.keyOf`
(statics are not in an extension's scope); an unqualified name inside an extension resolves to a
top-level declaration of the same name (in any part, or imported) before it reaches a member of
the class or of another extension, so a new top-level name must not repeat a member name; and a
library that calls an extension member must import `tree_walker.dart` itself (an extension is only
in scope where its library is imported).

The same rules, for the Go engine, live in the Flutternaut-AI repository (`engine/structure`).

## License

[Functional Source License 1.1, MIT Future License](packages/flutternaut/LICENSE) (FSL-1.1-MIT). Source-available: you may
use, modify and redistribute it for any purpose, including in commercial apps, except to offer a
competing product or service. Each version becomes available under the MIT license two years after its
release.
