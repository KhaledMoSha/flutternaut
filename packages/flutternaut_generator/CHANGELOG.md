## 0.0.2

* Fix compatibility with analyzer 7.x+ (`NamedType.name` → `name2` rename cycle).
* Widen analyzer constraint to `>=6.0.0 <11.0.0` to support Flutter 3.29.4 and newer.
* Add `view` field to generated output from `@FlutternautView` class annotation.
* Automatically propagate view from StatefulWidget to its State class.
* Change dynamic label placeholder from `{n}` to `{index}` to match engine's `${index}` variable.

## 0.0.1

* Initial release.
* AST-based scanner for Flutternaut widget usages.
* Extracts labels, types, descriptions, and screen groupings.
* Dynamic label detection with pattern rewriting.
* CLI with configurable output path.
