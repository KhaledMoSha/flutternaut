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

## License

MIT
