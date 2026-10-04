## Unreleased

* The bridge works in **debug, profile and release** builds. The README's setup snippet is now unconditional: call `await FlutternautBridge.ensureInitialized();` and remove the call (or pass `enabled: false`) from builds you publish to a store.
* **The bridge now listens on the device's loopback interface (`127.0.0.1`) instead of every interface.** The engine reaches it the same way as before (`adb forward`, the Mac's loopback for iOS simulators, `iproxy` for iPhones), but nothing on the device's network can. Pass `ensureInitialized(bindAddress: InternetAddress.anyIPv4)` to drive a device over Wi-Fi. New: `FlutternautBridge.instance.address`.
* An Android release build without the `INTERNET` permission can't open the bridge's socket. `ensureInitialized` now says exactly that, naming the manifest line to add. Before, it blamed another app on the port.
* An internal error (a `FlutterError` thrown while serving a request) is described by its summary, description and hint in every build mode. Before, a release build kept only the first line.
* A detached render object is treated as not laid out instead of failing the request.
* Known limitation: builds made with `--obfuscate` are not supported yet.
* A tap on a label (a `Text`, an `Icon`) is no longer reported as done when the pointer would be swallowed before reaching it. An `AbsorbPointer` splash or loading layer, the Navigator right after a navigation and a list that is still scrolling now get a refusal naming the cause, e.g. `AbsorbPointer(SplashSurface)` or "a list that is still scrolling". The engine re-tries a refused step, so the tap lands once the layer is gone. A tap handler that wraps an `AbsorbPointer` field on purpose (`InkWell(child: AbsorbPointer(TextField))`, the date-picker idiom) still takes the tap. `tap_at` refuses a point an `AbsorbPointer` swallows in the same way.
* A label under a painted `AbsorbPointer` layer (a splash held over a page that is already built) is no longer visible to `/screen`, `wait_visible` or `expect_visible`. A transparent absorber, or one that wraps the label, still hides nothing.
* The tap gate and its messages work the same in profile and release builds as in debug. They used `RenderObject.debugCreator`, which Flutter sets only in debug builds, to find the widget behind a render object; the widget is now looked up in the element tree. Before this, a tap handler wrapping an `AbsorbPointer` field went unrecognized outside debug, and `reached …` showed only render-object type names.
* The hint text of an empty field is now visible in `/screen` and to the visibility checks. Before, the field's (empty) editor counted as painting over it.
* The bridge port can be chosen at launch: when the `FLUTTERNAUT_BRIDGE_PORT` environment variable is set in the app's process, the bridge binds that port instead of the `port:` argument or the default 8500. The Flutternaut engine sets it per iOS simulator (they share the Mac's ports) so several simulators can run tests at once. Nothing to change in your app.
* A `FLUTTERNAUT_BRIDGE_PORT` that is not a TCP port (digits only, 1–65535) makes `ensureInitialized()` throw a `FlutternautBridgeException`; the bridge never falls back to 8500.
* A port that cannot be bound now throws a `FlutternautBridgeException` that names the port, where it came from (environment variable, argument or default) and, for the default, the likely cause — another simulator's app already serving the bridge. Previously the raw `SocketException` was rethrown.
* `GET /health` adds `port` (the port the bridge is bound to) and, on an iOS simulator, `device_id` (the simulator's UDID, from `SIMULATOR_UDID`; absent on physical devices, Android and desktop). Bridge protocol 1.3.0.
* `ensureInitialized({int? port})` — `port` is now nullable (omitted = 8500, as before); `FlutternautBridge.defaultPort`, `FlutternautBridge.instance.port` and `FlutternautBridgeException` are new.
* The environment is read with C `getenv` through `dart:ffi` on iOS, where `Platform.environment` is empty. No new dependency. `dart:ffi` sits behind a conditional import, so an app that also targets the web keeps compiling (the bridge itself does not run on the web).
* A `text` locator takes `match: "starts_with"`: the widget's own text must begin with `text`, compared case-insensitively, with the same `nth`, ambiguity and hit-test rules as `contains`. `"Free"` matches "Free Trial" but not "Start Free Trial"; a miss reads `text starting with "…"`. It works wherever `contains` does — `/tap`, `/long_press`, the visibility routes (`/is_visible`, `/assert_visible`, `/assert_not_visible`, `/wait_until_visible`, `/wait_until_gone`) and the lookups (`/find`, `/get_text`, `/assert_exists`, `/wait_for`, …). `/type`, `/clear_text`, `/scroll`, `/swipe` and `/multi_tap` still match exactly.
* With `contains` or `starts_with`, a `text` that is empty or only whitespace is rejected with HTTP 400: it would match every text, so an assertion on it would pass whatever the screen shows.
* An unknown `match` value is now rejected with HTTP 400 — `match must be "exact", "contains" or "starts_with", got "<value>"`. Before, the bridge silently matched exactly.
* `/long_press` honours `match`. Before, it ignored the field, so `match: "contains"` was silently matched exactly.
* The `contains` locator text is normalized like the text it is compared with (inline-widget placeholders dropped, surrounding whitespace trimmed), so `" Log in "` finds "Log in".
* Bridge protocol 1.4.0.

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
