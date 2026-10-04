# flutternaut

[![pub package](https://img.shields.io/pub/v/flutternaut.svg)](https://pub.dev/packages/flutternaut)
[![License: FSL-1.1-MIT](https://img.shields.io/badge/License-FSL--1.1--MIT-blue.svg)](LICENSE)

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
import 'package:flutter/material.dart';
import 'package:flutternaut/flutternaut.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutternautBridge.ensureInitialized();
  runApp(const MyApp());
}
```

The bridge works in every build mode (debug, profile and release) on Android and iOS, so the call is unconditional. **Remove it (or pass `enabled: false`) in a build you publish to a store**: the bridge gives full control of the app to whoever can reach it. See [Build modes](#build-modes).

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
  port: 8500,          // default; see "Which port the bridge uses"
  enabled: true,       // default; false disables the bridge without removing the call
  bindAddress: null,   // default = the device's loopback (127.0.0.1); see "Build modes"
);
```

All parameters are optional. `ensureInitialized()` is idempotent — safe to call multiple times; subsequent calls are ignored if the server is already running. `FlutternautBridge.instance` returns the running bridge, `FlutternautBridge.instance.isRunning` reports its state and `FlutternautBridge.instance.port` the port it is bound to and `FlutternautBridge.instance.address` the address it listens on.

### Which port the bridge uses

In order, the first that applies:

1. the `FLUTTERNAUT_BRIDGE_PORT` environment variable of the app's process;
2. the `port:` argument;
3. `8500`.

**You do not need to do anything about the variable.** The Flutternaut engine sets it when it launches your app, and only where it has to: iOS simulators share the Mac's network stack, so two simulators' apps cannot both listen on 8500, and the engine gives each simulator its own port to run them side by side. Your `main()` is compiled long before the engine picks a port, which is why the environment wins over the `port:` argument. On Android each device has its own network, the variable is normally absent, and the bridge stays on 8500 (if something does set it, it is honoured the same way).

The bridge fails loudly rather than listen somewhere the engine is not looking. `ensureInitialized()` throws a `FlutternautBridgeException` and the bridge stays stopped when:

- `FLUTTERNAUT_BRIDGE_PORT` is set to something that is not a TCP port (digits only, 1–65535) — it never falls back to 8500;
- the chosen port is already in use — the message names the port and where it came from (the variable, the argument or the default). On the default port that usually means another simulator's app is already serving the bridge.

`GET /health` reports where a bridge is: `port` (the port it is bound to) and, on an iOS simulator, `device_id` (that simulator's UDID).

**Security:** by default the server listens only on the device's loopback interface (`127.0.0.1`), so it is not reachable from the network. The engine reaches it through `adb forward` (Android), the Mac's own loopback (iOS simulators) or a USB forward (`usbmux` / `iproxy`, physical iPhones). The package has **no built-in build-mode gate**: the bridge gives full control of the app to whoever can reach it, so do not ship it in a build you publish to a store (see [Build modes](#build-modes)).

## Build modes

The bridge works in **debug, profile and release** builds, on Android and iOS. Use whichever build you want to test; do not publish a build that contains the bridge.

- **Listening address.** The default is the device's loopback (`127.0.0.1`). To drive a device over Wi-Fi, pass `bindAddress: InternetAddress.anyIPv4` (`InternetAddress` is from `dart:io`) to listen on all interfaces. Anyone on that network can then control the app, so use it only on a network you trust.
- **Android release builds need the `INTERNET` permission.** Flutter adds it only to the debug and profile manifests. Add it to `android/app/src/main/AndroidManifest.xml`:

  ```xml
  <uses-permission android:name="android.permission.INTERNET"/>
  ```

  Without it the bridge cannot open its socket and `ensureInitialized()` throws a `FlutternautBridgeException` that says so.
- **iOS profile and release builds run only on a physical iPhone** (a Flutter limitation); simulators run debug builds. Physical iPhone support in the Flutternaut engine is partial for now: you start `iproxy 8500 8500` yourself (the engine does not manage it), and parallel runs do not accept physical iOS devices.
- **`--obfuscate` is not supported yet.** The bridge relies on Flutter type names for some decisions, so a build made with `--obfuscate` is not supported.

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

The Flutternaut engine (or desktop app) forwards the bridge port for Android devices and emulators automatically when it creates a session — you do not need to run `adb forward` yourself. For a **physical iPhone** you run `iproxy 8500 8500` yourself (the engine does not manage it).

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
- Android or iOS. The bridge runs in any build mode (debug, profile, release); see [Build modes](#build-modes), and leave it out of builds you publish to a store

## License

[Functional Source License 1.1, MIT Future License](LICENSE) (FSL-1.1-MIT). Source-available: you may
use, modify and redistribute it for any purpose, including in commercial apps, except to offer a
competing product or service. Each version becomes available under the MIT license two years after its
release.
