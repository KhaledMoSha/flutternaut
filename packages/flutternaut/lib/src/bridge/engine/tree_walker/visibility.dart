part of '../tree_walker.dart';

/// Visibility to a person: the one predicate behind the dump, waits and
/// assertions.
extension TreeWalkerVisibility on TreeWalker {
  /// Checks whether a widget whose text equals [text] is visible — to a
  /// person looking at the screen, by the same rules the `/screen` dump
  /// uses (see [_visibilityOf]): laid out, not offstage, painted above
  /// [_visibleOpacityThreshold], not clipped away, not on a route hidden
  /// by a modal or being closed, and not covered at every sample point.
  ///
  /// Every match is considered, not just the first in tree order: a hidden
  /// duplicate (a page kept alive underneath, a faded-out cross-fade layer)
  /// never masks a visible one. With [nth], exactly the nth visible match
  /// (reading order, stacked copies of one control counted once) must
  /// exist — the same index the dump reports as `text_nth`.
  VisibilityResult checkTextVisible(String text, {int? nth}) =>
      checkTextMatchVisible(text, TextMatch.exact, nth: nth);

  /// Visibility of the widget(s) whose own visible text matches [text] in
  /// [match] mode (see [TextMatch] and [checkTextVisible]). The reason names
  /// the comparison — `text "x"`, `text containing "x"` or
  /// `text starting with "x"` (see [TextMatch.describe]).
  VisibilityResult checkTextMatchVisible(
    String text,
    TextMatch match, {
    int? nth,
  }) {
    return _checkVisibility(
      findAllElementsByTextMatch(text, match),
      match.describe(text),
      nth: nth,
    );
  }

  /// Visibility of the widget(s) with [ValueKey] [keyValue] (see
  /// [checkTextVisible]).
  VisibilityResult checkVisibleByKey(String keyValue, {int? nth}) {
    return _checkVisibility(
      findAllElementsByKey(keyValue),
      'key "$keyValue"',
      nth: nth,
    );
  }

  /// Visibility of the widget(s) whose visible text contains [substring]
  /// (case-insensitive) — the `match: "contains"` form, for labels such as
  /// "Start 7-Day Free Trial" that a test only knows part of (see
  /// [checkTextVisible]).
  VisibilityResult checkTextContainsVisible(String substring, {int? nth}) =>
      checkTextMatchVisible(substring, TextMatch.contains, nth: nth);

  /// Visibility of the widget(s) with accessibility label or identifier
  /// [label] (see [findAllElementsBySemantics] and [checkTextVisible]).
  VisibilityResult checkVisibleBySemantics(String label, {int? nth}) {
    return _checkVisibility(
      findAllElementsBySemantics(label),
      'semantics "$label"',
      nth: nth,
    );
  }

  /// Visibility of a locator's [matches] ([desc] names the locator in
  /// reasons). Visible when any match is visible — or, with [nth], when
  /// the nth distinct visible match exists (reading order; stacked copies
  /// of one control count once). When nothing is visible the result
  /// carries the reason for the first match in reading order, so a failed
  /// wait or assertion says exactly why ("… is at opacity 0.00").
  VisibilityResult _checkVisibility(
    List<Element> matches,
    String desc, {
    int? nth,
  }) {
    if (matches.isEmpty) {
      return VisibilityResult(
        exists: false,
        visible: false,
        reason: 'no widget matches $desc',
      );
    }

    final ordered = inReadingOrder(matches);
    if (ordered.isEmpty) {
      return VisibilityResult(
        exists: true,
        visible: false,
        info: extractInfo(matches.first),
        reason: '$desc exists but is not laid out',
      );
    }

    final (:visible, :firstHidden) = _scanVisible(ordered, desc);

    if (nth != null) {
      if (nth >= 0 && nth < visible.length) return visible[nth].$2;
      return VisibilityResult(
        exists: true,
        visible: false,
        onScreen: visible.isNotEmpty,
        info: extractInfo(ordered.first),
        reason: 'nth $nth is out of range for $desc: ${visible.length} '
            'visible match(es)'
            '${firstHidden?.reason != null ? ' (${firstHidden!.reason})' : ''}',
      );
    }
    if (visible.isNotEmpty) return visible.first.$2;
    return firstHidden!;
  }

  /// The matches a person can see, in reading order, stacked copies of one
  /// control (a nav icon's two glyph layers, a cross-fading label) counted
  /// once — **the one list every `nth` indexes**: visibility waits and
  /// assertions, taps, state assertions and the `/screen` dump's
  /// `text_nth`/`semantics_nth`. An action then checks what it needs of the
  /// chosen match (a tap: that it is reachable) and fails loudly when that
  /// does not hold, rather than silently counting differently.
  List<Element> visibleMatches(List<Element> matches) => [
        for (final v in _scanVisible(inReadingOrder(matches), '').visible) v.$1,
      ];

  /// The visible matches among [ordered] (already in reading order) with
  /// their results, stacked copies merged, and the first hidden match's
  /// result — the reason given when nothing is visible.
  ({List<(Element, VisibilityResult)> visible, VisibilityResult? firstHidden})
      _scanVisible(List<Element> ordered, String desc) {
    final screen = _screenSize;
    final layers = _routeLayers();
    final visible = <(Element, VisibilityResult)>[];
    VisibilityResult? firstHidden;
    for (final element in ordered) {
      final result = _visibilityOf(element, screen, layers, desc);
      if (!result.visible) {
        firstHidden ??= result;
      } else if (!visible.any((v) => _sameStackedControl(v.$1, element))) {
        visible.add((element, result));
      }
    }
    return (visible: visible, firstHidden: firstHidden);
  }

  /// Whether [element] is visible to a person looking at the screen — the
  /// single predicate shared by the `/screen` dump and every visibility
  /// wait/assertion, so the two can never disagree:
  ///
  ///  1. laid out and not under an active `Offstage`;
  ///  2. painted at ≥ [_visibleOpacityThreshold] effective opacity;
  ///  3. a non-empty rect after clipping to the screen and every clipping
  ///     ancestor;
  ///  4. not on a route hidden by a modal route above it, or being closed
  ///     ([_RouteLayers]);
  ///  5. not covered at every sample point ([_coverage]).
  VisibilityResult _visibilityOf(
    Element element,
    Size? screen,
    _RouteLayers layers,
    String desc,
  ) {
    final info = extractInfo(element);
    VisibilityResult hidden(String why, {bool onScreen = false}) =>
        VisibilityResult(
          exists: true,
          visible: false,
          onScreen: onScreen,
          obstructed: onScreen,
          info: info,
          reason: '$desc exists but $why',
        );

    if (info.rect == null || screen == null) return hidden('is not laid out');
    if (_isOffstage(element)) {
      return hidden('is offstage (an inactive tab or a page kept alive '
          'underneath)');
    }
    final opacity = _effectiveOpacity(element);
    if (opacity < _visibleOpacityThreshold) {
      return hidden('is at opacity ${opacity.toStringAsFixed(2)}');
    }
    final rect = _visibleRect(element, screen);
    if (rect == null || rect.width <= 0 || rect.height <= 0) {
      return hidden('is off-screen or clipped out of view');
    }
    if (layers.hides(element)) {
      return hidden(
        'is on a route hidden behind a dialog/sheet/page, or on a route '
        'that is closing',
        onScreen: true,
      );
    }
    if (_coverage(element, screen) == _Coverage.covered) {
      final center = rect.center;
      final blocker = _coverAt(element, center);
      return hidden(
        'is covered by ${blocker ?? 'another widget'} at every point',
        onScreen: true,
      );
    }
    return VisibilityResult(
      exists: true,
      visible: true,
      onScreen: true,
      info: info,
    );
  }
}
