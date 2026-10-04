import '../engine/tree_walker.dart';
import '../models/element_info.dart';
import '../models/visibility_result.dart';
import '../router.dart';

/// The [TextMatch] a request's `match` field asks for: absent (or JSON
/// `null`) is [TextMatch.exact]; `"exact"`, `"contains"` and
/// `"starts_with"` name the three modes.
///
/// Any other value — a typo, a mode this bridge does not know, a non-string
/// — throws an [ArgumentError] (HTTP 400). Treating it as exact would
/// quietly run a different comparison than the one the test asked for: a
/// test written for a newer bridge would pass or fail for the wrong reason.
TextMatch textMatchOf(BridgeRequest req) {
  final raw = req.body['match'];
  return switch (raw) {
    null => TextMatch.exact,
    'exact' => TextMatch.exact,
    'contains' => TextMatch.contains,
    'starts_with' => TextMatch.startsWith,
    _ => throw ArgumentError(
        'match must be "exact", "contains" or "starts_with", got "$raw"',
      ),
  };
}

/// Resolves an element by the `key`, `text` or `semantics` locator field on
/// [req]. `text` honours `match` (see [textMatchOf]); an unknown `match` is
/// rejected whichever locator is present. Returns null if no locator is
/// present or nothing matches.
ElementInfo? resolveLocator(BridgeRequest req, TreeWalker walker) {
  final match = textMatchOf(req);
  final key = req.string('key');
  if (key != null) return walker.findByKey(key);
  final text = req.string('text');
  if (text != null) return walker.findByTextMatch(text, match);
  final semantics = req.string('semantics');
  if (semantics != null) return walker.findBySemantics(semantics);
  return null;
}

/// Checks visibility for the `key`, `text` or `semantics` locator on [req].
/// `text` honours `match` (see [textMatchOf]); `nth` (when present) requires
/// the nth distinct visible match — the index a catalog ref carries. Returns
/// a not-found result when no locator field is present.
VisibilityResult resolveVisibility(BridgeRequest req, TreeWalker walker) {
  final match = textMatchOf(req);
  final nth = req.body.containsKey('nth') ? req.integer('nth') : null;
  final key = req.string('key');
  if (key != null) return walker.checkVisibleByKey(key, nth: nth);
  final text = req.string('text');
  if (text != null) return walker.checkTextMatchVisible(text, match, nth: nth);
  final semantics = req.string('semantics');
  if (semantics != null) {
    return walker.checkVisibleBySemantics(semantics, nth: nth);
  }
  return const VisibilityResult(
    exists: false,
    visible: false,
    reason: 'no "key", "text" or "semantics" locator given',
  );
}
