## Unreleased

* The bridge port can be chosen at launch: when the `FLUTTERNAUT_BRIDGE_PORT` environment variable is set in the app's process, the bridge binds that port instead of the `port:` argument or the default 8500. The Flutternaut engine sets it per iOS simulator (they share the Mac's ports) so several simulators can run tests at once. Nothing to change in your app.
* A `FLUTTERNAUT_BRIDGE_PORT` that is not a TCP port (digits only, 1–65535) makes `ensureInitialized()` throw a `FlutternautBridgeException`; the bridge never falls back to 8500.
* A port that cannot be bound now throws a `FlutternautBridgeException` that names the port, where it came from (environment variable, argument or default) and, for the default, the likely cause — another simulator's app already serving the bridge. Previously the raw `SocketException` was rethrown.
* `GET /health` adds `port` (the port the bridge is bound to) and, on an iOS simulator, `device_id` (the simulator's UDID, from `SIMULATOR_UDID`; absent on physical devices, Android and desktop). Bridge protocol 1.3.0.
* `ensureInitialized({int? port})` — `port` is now nullable (omitted = 8500, as before); `FlutternautBridge.defaultPort`, `FlutternautBridge.instance.port` and `FlutternautBridgeException` are new.
* The environment is read with C `getenv` through `dart:ffi` on iOS, where `Platform.environment` is empty. No new dependency. `dart:ffi` sits behind a conditional import, so an app that also targets the web keeps compiling (the bridge itself does not run on the web).

## 0.0.6 — 2026-04-10

* Add `topics` to pubspec.yaml for pub.dev discoverability.
* Add pub version and license badges to README.
* Add dates to all CHANGELOG entries.
* Add example/README.md with link to getting started guide.
* Clarify `@FlutternautView` is optional with no runtime effect.

## 0.0.5 — 2026-04-08

* Document `@FlutternautView` annotation usage in README.
* Fix stale semantics documentation — update constructors table and `excludeSemantics` behavior.

## 0.0.4 — 2026-04-08

* Add `@FlutternautView` annotation for grouping elements by view/screen.
* View annotation propagates from StatefulWidget to its State class in the generator.
* Example app with 5 screens and test data covering all actions.

## 0.0.3 — 2026-03-28

* Update installation steps with generator CLI setup.

## 0.0.2 — 2026-03-20

* Fix homepage link.

## 0.0.1 — 2026-03-10

* Initial release.
* Semantics wrapper widget with named constructors for common UI patterns.
* Optional `description` parameter for AI test authoring metadata.
