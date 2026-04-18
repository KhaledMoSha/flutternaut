import '../models/element_info.dart';
import '../models/visibility_result.dart';
import '../router.dart';
import '../tree_walker.dart';

/// Resolves an element by the `key` or `text` locator field on [req].
/// Returns null if neither is present or neither matches.
ElementInfo? resolveLocator(BridgeRequest req, TreeWalker walker) {
  final key = req.string('key');
  if (key != null) return walker.findByKey(key);
  final text = req.string('text');
  if (text != null) return walker.findByText(text);
  return null;
}

/// Checks visibility for the `key` or `text` locator on [req].
/// Returns a not-found result when neither field is present.
VisibilityResult resolveVisibility(BridgeRequest req, TreeWalker walker) {
  final key = req.string('key');
  if (key != null) return walker.checkVisibleByKey(key);
  final text = req.string('text');
  if (text != null) return walker.checkTextVisible(text);
  return const VisibilityResult(exists: false, visible: false);
}
