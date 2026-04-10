## 0.0.4 — 2026-04-10

* Add `topics` to pubspec.yaml for pub.dev discoverability.
* Add pub version and license badges to README.
* Add dates to all CHANGELOG entries.

## 0.0.3 — 2026-04-08

* Resolve `@FlutternautView` arguments that use static const references (e.g. `AppRoutes.trip`).
* Two-pass analysis: first collects all `static const` string declarations across the project, then resolves annotation arguments against them.
* Falls back to source text when a const reference cannot be resolved.

## 0.0.2 — 2026-03-28

* Fix compatibility with analyzer 7.x+ (`NamedType.name` → `name2` rename cycle).
* Widen analyzer constraint to `>=6.0.0 <11.0.0` to support Flutter 3.29.4 and newer.
* Add `view` field to generated output from `@FlutternautView` class annotation.
* Automatically propagate view from StatefulWidget to its State class.
* Change dynamic label placeholder from `{n}` to `{index}` to match engine's `${index}` variable.

## 0.0.1 — 2026-03-10

* Initial release.
* AST-based scanner for Flutternaut widget usages.
* Extracts labels, types, descriptions, and screen groupings.
* Dynamic label detection with pattern rewriting.
* CLI with configurable output path.
