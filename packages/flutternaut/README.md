# flutternaut

[![pub package](https://img.shields.io/pub/v/flutternaut.svg)](https://pub.dev/packages/flutternaut)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An in-app HTTP bridge that lets external test engines interact with the Flutter widget tree directly — no Appium, no accessibility layer required.

## Who is this for?

Flutter teams and QA engineers who want real E2E automation without changing their app. No `Semantics` widgets to add, no accessibility hints to configure, no workarounds for `getText()` returning empty — drop the package in, start the bridge in `main()`, and your tests can reach the whole widget tree.

This package is the "inside half" of the [Flutternaut](https://flutternaut.app) test automation stack. It runs an HTTP server inside your app that gives an external test engine direct, synchronous access to the live widget tree.

## Why the bridge exists

Flutter renders to a canvas, so accessibility-based automation (Appium, Maestro, XCUITest) only sees what the Semantics tree exposes — which is often empty text, broken `sendKeys`, and platform-specific workarounds. The usual fix is to wrap every button and field in `Semantics` nodes so the automation layer can see them. That is app-side work your team did not sign up for.

Flutternaut runs inside the app, in the same Dart isolate as your widgets, and walks the real widget tree. No `Semantics` annotations. No build-mode gymnastics. Text reading, tapping, typing, scrolling, and assertions all go through Flutter's own gesture and rendering systems — the same path as a real user tap.

## Quickstart

**1. Add the dependency**

```bash
flutter pub add flutternaut
```

**2. Start the bridge in `main()`**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutternaut/flutternaut.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    await FlutternautBridge.ensureInitialized();
  }
  runApp(const MyApp());
}
```

**3. (Optional) Add `ValueKey`s for widgets without text**

Most widgets can be targeted by their visible text — buttons, links, list items, error messages — no code change required:

```
POST /tap      {"text": "Sign In"}
POST /type     {"target": "Email", "text": "user@example.com"}
```

(`/type` locates the field by `key` or by the visible label/hint in `target`, and types the `text` value.)

For widgets that have no text or whose text is ambiguous — a leading checkbox inside a `ListTile`, an icon-only button, an item inside a list of identical rows — add a `ValueKey` so the bridge can pick it out:

```dart
ListTile(
  leading: Checkbox(
    key: ValueKey('todo_${index}_done'),
    value: done,
    onChanged: _toggle,
  ),
  title: const Text('Buy milk'),
)
```

## How it works

When `FlutternautBridge.ensureInitialized()` is called, it starts a standard Dart `HttpServer` inside the app process. Incoming requests are routed to handler groups (find, gesture, query, assert, wait) that walk the live `WidgetsBinding` element tree to locate widgets and dispatch actions.

All tree access is scheduled on the main UI thread so reads happen after layout and paint, against a stable tree. Gestures are dispatched through Flutter's `GestureBinding` — the same path as real user input.

The bridge is designed to pair with the Flutternaut engine (written in Go), which manages device sessions, test execution, and result reporting. You call the engine; the engine calls the bridge.

## Configuration

```dart
await FlutternautBridge.ensureInitialized(
  port: 8500,          // default; the engine forwards this port
  enabled: !kReleaseMode, // false disables the bridge without removing the call
);
```

Both parameters are optional. `ensureInitialized()` is idempotent — safe to call multiple times; subsequent calls are ignored if the server is already running. `FlutternautBridge.instance` returns the running bridge and `FlutternautBridge.isRunning` reports its state.

**Security:** the server binds `0.0.0.0` (all interfaces) so emulators, simulators and USB-forwarded devices can reach it, and the package has **no built-in build-mode gate**. Always wrap the call in `kDebugMode` (or pass `enabled: !kReleaseMode`) so a release build never exposes the bridge.

To shut down the server (e.g. in tests or on app teardown):

```dart
await FlutternautBridge.dispose();
```

## FlutternautView annotation

`@FlutternautView` is a build-time annotation read by the `flutternaut_generator` CLI tool (separate package). It marks a widget class with a screen name so generated keys JSON groups elements by view.

```dart
import 'package:flutternaut/flutternaut.dart';

@FlutternautView('Login')
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  // ...
}
```

The annotation is consumed by `flutternaut_generator` at code-gen time — it has no runtime effect. It does not need to be on every widget, only on screens where you want explicit grouping in the output keys file.

The package also exposes the generator as an executable, so `dart run flutternaut` from your project root produces `flutternaut_keys.json` without adding the generator as a separate dependency.

## Platform setup

The Flutternaut engine (or desktop app) handles port forwarding automatically when it creates a session — you do not need to run `adb forward` or `iproxy` yourself.

If you are calling the bridge directly from a host script (no engine in the picture), forward the bridge port once before your test run:

```bash
# Android emulator or device
adb forward tcp:<bridge-port> tcp:<bridge-port>

# Physical iOS device (via libimobiledevice)
iproxy <bridge-port> <bridge-port> <UDID>
```

iOS simulators share the host network, so no forwarding is needed there.

## Requirements

- Dart `>=3.5.0 <4.0.0`
- Flutter `>=3.24.0`
- Android or iOS. The bridge runs in any build mode; gate it yourself with `kDebugMode` so it never ships in release

## License

MIT
