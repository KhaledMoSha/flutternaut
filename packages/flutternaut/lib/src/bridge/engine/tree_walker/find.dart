part of '../tree_walker.dart';

/// Finding elements by key and by text.
extension TreeWalkerFind on TreeWalker {
  /// Finds the first element whose [ValueKey] value matches [keyValue].
  ElementInfo? findByKey(String keyValue) {
    return _findWhere(
        (element) => TreeWalker.keyOf(element.widget) == keyValue);
  }

  /// The one text predicate behind every text finder: whether an
  /// element's own text ([_widgetOwnText]) matches the locator [text] in
  /// [match] mode.
  ///
  /// The locator is normalized once, here, rather than per element.
  ///  * [TextMatch.exact] — `own == normalizeText(text)`, case-sensitive.
  ///    The own text is compared as [_widgetOwnText] returns it, so a
  ///    field's value still has to equal the locator verbatim.
  ///  * [TextMatch.contains] / [TextMatch.startsWith] — both sides
  ///    normalized and lower-cased. Normalizing the field value too means
  ///    a value with surrounding spaces still starts with its first word;
  ///    normalizing the locator means `" Log in "` and `"Log in"` are the
  ///    same needle, as they already are for exact.
  bool Function(Element) _textMatcher(String text, TextMatch match) {
    final needle = TreeWalker.normalizeText(text);
    // An empty needle is a prefix and a substring of every text: a contains
    // or starts_with check on it would match any widget, and an assertion
    // built on it would pass whatever the screen shows.
    if (needle.isEmpty && match != TextMatch.exact) {
      throw ArgumentError(
        '${match.describe(text)} needs at least one visible character to '
        'match; got ${text.isEmpty ? 'an empty text' : 'only whitespace'}',
      );
    }
    switch (match) {
      case TextMatch.exact:
        return (element) => _widgetOwnText(element.widget) == needle;
      case TextMatch.contains:
        final lower = needle.toLowerCase();
        return (element) => _foldedOwnText(element)?.contains(lower) ?? false;
      case TextMatch.startsWith:
        final lower = needle.toLowerCase();
        return (element) => _foldedOwnText(element)?.startsWith(lower) ?? false;
    }
  }

  /// [element]'s own text normalized and lower-cased — the haystack of the
  /// case-insensitive modes (see [_textMatcher]); null when the widget
  /// carries no text of its own.
  String? _foldedOwnText(Element element) {
    final own = _widgetOwnText(element.widget);
    return own == null ? null : TreeWalker.normalizeText(own).toLowerCase();
  }

  /// Finds the first text-bearing widget ([Text], `Text.rich`,
  /// [RichText], [EditableText]) whose visible text matches [text]
  /// exactly.
  ElementInfo? findByText(String text) =>
      findByTextMatch(text, TextMatch.exact);

  /// Finds the first text-bearing widget whose own visible text matches
  /// [text] in [match] mode (see [TextMatch]).
  ElementInfo? findByTextMatch(String text, TextMatch match) {
    return _findWhere(_textMatcher(text, match));
  }

  /// Finds the first text-bearing widget whose visible text contains
  /// [substring], **case-insensitively** (contains is the fuzzy,
  /// opt-in path; exact matching via [findByText] stays case-sensitive).
  ElementInfo? findByTextContains(String substring) =>
      findByTextMatch(substring, TextMatch.contains);

  /// Finds the first [Element] whose [ValueKey] value matches [keyValue].
  Element? findElementByKey(String keyValue) {
    return _findElementWhere(
        (element) => TreeWalker.keyOf(element.widget) == keyValue);
  }

  /// Finds the first [Element] whose own visible text equals [text]
  /// exactly (case-sensitive — see [findByText]).
  Element? findElementByText(String text) {
    return _findElementWhere(_textMatcher(text, TextMatch.exact));
  }

  /// Every [Element] whose [ValueKey] value matches [keyValue]. Used to
  /// detect ambiguous locators; more than one on-screen, hittable match
  /// is a fatal authoring error.
  List<Element> findAllElementsByKey(String keyValue) {
    return _findAllElementsWhere(
      (element) => TreeWalker.keyOf(element.widget) == keyValue,
    );
  }

  /// Every text-bearing [Element] whose own visible text equals [text]
  /// exactly (case-sensitive).
  List<Element> findAllElementsByText(String text) =>
      findAllElementsByTextMatch(text, TextMatch.exact);

  /// Every text-bearing [Element] whose own visible text matches [text] in
  /// [match] mode (see [TextMatch]) — every match, for ambiguity detection
  /// and visibility checks.
  List<Element> findAllElementsByTextMatch(String text, TextMatch match) {
    return _findAllElementsWhere(_textMatcher(text, match));
  }

  /// Every text-bearing [Element] whose own visible text equals [text]
  /// exactly AND is currently on screen. Used to resolve a row anchor —
  /// off-screen duplicates of the anchor text are not real conflicts.
  List<Element> findOnScreenElementsByText(String text) {
    final screen = _screenSize;
    return findAllElementsByText(text)
        .where((e) => _isOnScreen(e, screen))
        .toList();
  }

  /// Returns all elements that have a [ValueKey].
  List<ElementInfo> findAllKeyed() {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const [];

    final results = <ElementInfo>[];
    void visitor(Element element) {
      if (TreeWalker.keyOf(element.widget) != null) {
        results.add(extractInfo(element));
      }
      element.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);
    return results;
  }

  ElementInfo? _findWhere(bool Function(Element) test) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return null;

    ElementInfo? result;
    void visitor(Element element) {
      if (result != null) return;
      if (test(element)) {
        result = extractInfo(element);
        return;
      }
      element.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);
    return result;
  }

  /// Like [_findWhere] but returns the matched [Element] itself.
  Element? _findElementWhere(bool Function(Element) test) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return null;

    Element? result;
    void visitor(Element element) {
      if (result != null) return;
      if (test(element)) {
        result = element;
        return;
      }
      element.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);
    return result;
  }

  /// Like [_findElementWhere] but returns every matching [Element].
  ///
  /// Does not descend into a matched element's own subtree (mirroring
  /// [_findWhere]'s early-return), so a [Text] and the [RichText] it
  /// builds internally — which share the same visible string — are not
  /// both counted as separate matches.
  List<Element> _findAllElementsWhere(bool Function(Element) test) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const [];

    final results = <Element>[];
    void visitor(Element element) {
      if (test(element)) {
        results.add(element);
        return; // do not descend into a match's own subtree
      }
      element.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);
    return results;
  }
}
