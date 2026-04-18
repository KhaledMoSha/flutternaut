import '../main_thread_runner.dart';
import '../router.dart';
import '../tree_walker.dart';

/// Handles element finding endpoints.
class FindHandler {
  final TreeWalker _walker;
  final MainThreadRunner _runner;

  /// Creates a [FindHandler] backed by [walker] and scheduled via [runner].
  FindHandler({required TreeWalker walker, required MainThreadRunner runner})
      : _walker = walker,
        _runner = runner;

  /// Registers the find-family routes on [router].
  void register(BridgeRouter router) {
    router.post('/find', _find);
    router.post('/find_text', _findText);
  }

  Future<Map<String, dynamic>> _find(BridgeRequest req) async {
    req.requireLocator();
    final key = req.string('key');
    final text = req.string('text');

    return _runner.run(() {
      final info = key != null ? _walker.findByKey(key) : _walker.findByText(text!);
      if (info != null) return info.toJson();
      return {
        'found': false,
        if (key != null) 'key': key,
        if (text != null) 'text': text,
      };
    });
  }

  Future<Map<String, dynamic>> _findText(BridgeRequest req) async {
    req.require('text');
    final text = req.string('text')!;
    final exact = req.boolean('exact', defaultValue: true);

    return _runner.run(() {
      final info = exact ? _walker.findByText(text) : _walker.findByTextContains(text);
      return info?.toJson() ?? {'found': false, 'text': text};
    });
  }
}
