import '../engine/tree_walker.dart';
import '../models/element_info.dart';
import '../models/visibility_result.dart';
import '../router.dart';

/// Whether the request asks for substring text matching
/// (`"match": "contains"`, case-insensitive) instead of the exact default.
bool _wantsContains(BridgeRequest req) => req.string('match') == 'contains';

/// Resolves an element by the `key`, `text` or `semantics` locator field on
/// [req]. `text` honours `match: "contains"`. Returns null if no locator is
/// present or nothing matches.
ElementInfo? resolveLocator(BridgeRequest req, TreeWalker walker) {
  final key = req.string('key');
  if (key != null) return walker.findByKey(key);
  final text = req.string('text');
  if (text != null) {
    return _wantsContains(req)
        ? walker.findByTextContains(text)
        : walker.findByText(text);
  }
  final semantics = req.string('semantics');
  if (semantics != null) return walker.findBySemantics(semantics);
  return null;
}

/// Checks visibility for the `key`, `text` or `semantics` locator on [req].
/// `text` honours `match: "contains"`. Returns a not-found result when no
/// locator field is present.
VisibilityResult resolveVisibility(BridgeRequest req, TreeWalker walker) {
  final key = req.string('key');
  if (key != null) return walker.checkVisibleByKey(key);
  final text = req.string('text');
  if (text != null) {
    return _wantsContains(req)
        ? walker.checkTextContainsVisible(text)
        : walker.checkTextVisible(text);
  }
  final semantics = req.string('semantics');
  if (semantics != null) return walker.checkVisibleBySemantics(semantics);
  return const VisibilityResult(exists: false, visible: false);
}
