part of 'gesture_dispatcher.dart';

/// Scroll gestures on a resolved [Scrollable]: which one a swipe acts on
/// (by locator, by `scrollIndex`, or the direction-only auto-pick), and how
/// far the swipe moved it ([ScrollMove]).
extension GestureDispatcherScroll on GestureDispatcher {
  /// A scrollable must be at least this many times larger (visible area)
  /// than the next candidate to be chosen as the screen's main list.
  static const double _dominantAreaRatio = 2.0;

  /// Swipes by [distance] in [direction] starting from [center]. Shared by
  /// the element-targeted [swipe] and the swipes on a resolved scrollable
  /// ([swipeAtIndex], [swipeAuto]).
  Future<void> swipeAt(
    Offset center,
    String direction,
    double distance, {
    bool fling = true,
  }) {
    return _dispatchMovement(
      center,
      _directionToDelta(direction, distance),
      fling: fling,
    );
  }

  /// The pointer travel of a [distance] swipe in [direction]: "up" moves
  /// the finger up (the content scrolls forward), "down" down, "left" and
  /// "right" sideways. Anything else is treated as "up".
  static Offset _directionToDelta(String direction, double distance) {
    return switch (direction) {
      'up' => Offset(0, -distance),
      'down' => Offset(0, distance),
      'left' => Offset(-distance, 0),
      'right' => Offset(distance, 0),
      _ => Offset(0, -distance),
    };
  }

  /// Swipes a widget found by [key] or [text] in the given [direction].
  /// With [fling] false the pointer stops before it lifts, so a scroll view
  /// moves about [distance] and no further (see
  /// [GestureDispatcher._dispatchMovement]).
  ///
  /// `found` is false — and nothing is dispatched — when no widget matches
  /// or it has no laid-out geometry. `move` reports what the swipe did to
  /// the [Scrollable] it moved ([TreeWalkerScroll.scrollableMovedBy]: the
  /// located list itself, the one a keyed `ListView` builds, or the list
  /// the located widget sits in); null when no [Scrollable] on the
  /// direction's axis is involved, or its position cannot be read.
  Future<({bool found, ScrollMove? move})> swipe({
    String? key,
    String? text,
    required String direction,
    double distance = 300,
    bool fling = true,
  }) async {
    final element = key != null
        ? walker.findElementByKey(key)
        : (text != null ? walker.findElementByText(text) : null);
    final center = element == null ? null : walker.centerOfElement(element);
    if (element == null || center == null) return (found: false, move: null);

    final scrollable =
        walker.scrollableMovedBy(element, _axisForDirection(direction));
    Future<void> gesture() =>
        swipeAt(center, direction, distance, fling: fling);
    if (scrollable == null) {
      await gesture();
      return (found: true, move: null);
    }
    return (found: true, move: await _measured(scrollable, direction, gesture));
  }

  /// Swipes the single on-screen [Scrollable] whose axis matches
  /// [direction], for a screen-level scroll when no scroll container is
  /// specified. Throws [ActionFailure] if none or more than one match
  /// (see [resolveScrollable]). Returns how far the swipe moved it (see
  /// [_measured]).
  Future<ScrollMove?> swipeAuto(
    String direction,
    double distance, {
    bool fling = true,
  }) async {
    final scrollable = resolveScrollable(direction);
    return _swipeScrollable(scrollable, direction, distance, fling: fling);
  }

  /// Swipes the [index]-th on-screen [Scrollable] — element-tree DFS order,
  /// exactly the `scrollIndex` the `/screen` dump reports — whose axis
  /// matches [direction]. Throws [ActionFailure] when the index is out of
  /// range, so a stale recorded index fails loudly instead of scrolling the
  /// wrong container. Returns how far the swipe moved it (see [_measured]).
  Future<ScrollMove?> swipeAtIndex(
    int index,
    String direction,
    double distance, {
    bool fling = true,
  }) async {
    final axis = _axisForDirection(direction);
    final axisName = axis == Axis.vertical ? 'vertical' : 'horizontal';
    final matches = walker.findVisibleScrollables(axis);
    if (index < 0 || index >= matches.length) {
      throw ActionFailure(
        'scrollIndex $index is out of range: ${matches.length} $axisName '
        'scrollable(s) are visible.',
      );
    }
    return _swipeScrollable(matches[index], direction, distance, fling: fling);
  }

  /// Swipes [scrollable] (one [TreeWalkerScroll.findVisibleScrollables]
  /// counts) from a point where the gesture lands on it
  /// ([TreeWalkerScroll.scrollStartOf]): the centre of its visible part, else
  /// the first inset sample point nothing covers and the pointer reaches. Its
  /// unclipped centre is not used — it can be off screen while a page
  /// slides in, or under a card or a closing page. When no such point
  /// exists the swipe is refused, never dispatched blind and reported done.
  /// Returns how far the swipe moved it (see [_measured]).
  Future<ScrollMove?> _swipeScrollable(
    Element scrollable,
    String direction,
    double distance, {
    required bool fling,
  }) async {
    final start = walker.scrollStartOf(scrollable);
    final point = start.point;
    if (point == null) {
      final axis = _axisForDirection(direction);
      final axisName = axis == Axis.vertical ? 'vertical' : 'horizontal';
      final index = walker.findVisibleScrollables(axis).indexOf(scrollable);
      final which = index >= 0 ? ' at scrollIndex $index' : '';
      final rect = walker.rectOfElement(scrollable);
      final where = rect != null ? ' @ ${_fmtRect(rect)}' : '';
      throw ActionFailure(
        'Cannot swipe the $axisName scrollable$which$where "$direction": '
        'no visible point of it takes the pointer — ${start.blocker}.',
      );
    }
    return _measured(
      scrollable,
      direction,
      () => swipeAt(point, direction, distance, fling: fling),
    );
  }

  /// Runs [gesture] on [scrollable] and reports what it did ([ScrollMove]):
  /// how far it moved, and whether the list had room in [direction] before
  /// the gesture ([_hasRoom]). Never refuses after the fact — a swipe that
  /// moved nothing is reported as such, for the caller to judge.
  ///
  /// `moved` is the most any list that shares the drag moved
  /// ([_sharingDrags]), `pixels` read just before and right after: a
  /// `NestedScrollView` moves its outer list (the header) before the inner
  /// list a swipe lands on, so the list named can stay put while the drag
  /// scrolls the screen.
  ///
  /// Null (the gesture still runs) when [scrollable] has no scroll position
  /// with pixels before the gesture, or none after it (it left the tree —
  /// the swipe opened another page): there is nothing to measure against.
  Future<ScrollMove?> _measured(
    Element scrollable,
    String direction,
    Future<void> Function() gesture,
  ) async {
    final position = walker.scrollPositionOf(scrollable);
    if (position == null || !position.hasPixels) {
      await gesture();
      return null;
    }
    final room = _hasRoom(position, direction);
    final before = <Element, double>{};
    for (final e in _sharingDrags(scrollable, _axisForDirection(direction))) {
      final pixels = _pixelsOf(e);
      if (pixels != null) before[e] = pixels;
    }
    await gesture();
    // The Scrollable replaces its position when its physics or controller
    // change (the new one takes the old one's pixels): read the current one.
    if (_pixelsOf(scrollable) == null) return null;
    var moved = 0.0;
    before.forEach((element, pixels) {
      final now = _pixelsOf(element);
      if (now == null) return;
      final delta = (now - pixels).abs();
      if (delta > moved) moved = delta;
    });
    return ScrollMove(moved: moved, room: room);
  }

  /// The scroll offset of the [Scrollable] element [e] now, or null when it
  /// left the tree or has no position with pixels.
  double? _pixelsOf(Element e) {
    if (!e.mounted) return null;
    final position = walker.scrollPositionOf(e);
    return position != null && position.hasPixels ? position.pixels : null;
  }

  /// [scrollable] and every [Scrollable] on [axis] a drag on it can move
  /// instead: the ones it sits in and the ones inside it. A
  /// `NestedScrollView` hands a drag to its outer list first (the header
  /// collapses) or to its inner one, and a keyed wrapper's swipe lands on a
  /// list inside the one it is measured by.
  List<Element> _sharingDrags(Element scrollable, Axis axis) {
    bool onAxis(Element e) {
      final widget = e.widget;
      return widget is Scrollable &&
          axisDirectionToAxis(widget.axisDirection) == axis;
    }

    final family = <Element>[scrollable];
    scrollable.visitAncestorElements((ancestor) {
      if (onAxis(ancestor)) family.add(ancestor);
      return true;
    });
    void visit(Element e) {
      if (onAxis(e)) family.add(e);
      e.visitChildren(visit);
    }

    scrollable.visitChildren(visit);
    return family;
  }

  /// The room (logical px) a list must have more than in a swipe's
  /// direction to count as able to move ([ScrollMove.room]) — the engine
  /// catalog's `scrollSlack` (engine/catalog/scroll_room.go), so the bridge
  /// and the dump's reader agree on where a list's end is. A ballistic or
  /// bouncing scroll can come to rest a fraction of a pixel short of its
  /// extent; counting that as room would report the fraction it can still
  /// move as a drag the list refused.
  static const double _roomSlack = 1.0;

  /// Whether [position] has more than [_roomSlack] left in [direction]:
  /// "up"/"left" advance the offset towards `maxScrollExtent` (infinite for
  /// an endless list), "down"/"right" retreat it towards `minScrollExtent`.
  /// False without content dimensions.
  bool _hasRoom(ScrollPosition position, String direction) {
    if (!position.hasContentDimensions) return false;
    final forward = direction == 'up' || direction == 'left';
    return forward
        ? position.maxScrollExtent - position.pixels > _roomSlack
        : position.pixels - position.minScrollExtent > _roomSlack;
  }

  /// Maps a swipe [direction] to the scroll axis it moves along.
  Axis _axisForDirection(String direction) =>
      (direction == 'up' || direction == 'down')
          ? Axis.vertical
          : Axis.horizontal;

  /// Resolves the visible [Scrollable] to scroll for [direction], or
  /// throws [ActionFailure]. Direction maps to an axis (up/down →
  /// vertical, left/right → horizontal). Among the scrollables on that
  /// axis the `/screen` dump shows
  /// ([TreeWalkerScroll.findVisibleScrollables] — never one on a page
  /// hidden behind another route, on a closing route, showing less than a
  /// logical pixel of itself, or covered at every point by something
  /// painted over it, such as a loading layer or a drawer's scrim):
  ///
  ///  1. only those that can still move in [direction] count — a list
  ///     already at its end, or a bottom nav bar that never overflows,
  ///     is not a candidate;
  ///  2. one remaining candidate wins;
  ///  3. several: the one with the clearly largest **visible** area (the
  ///     part inside the screen and its clipping ancestors, at least
  ///     [_dominantAreaRatio]× the runner-up) is the screen's main list
  ///     and wins; otherwise the choice is genuinely ambiguous and the
  ///     author must pass a scroll target or `scrollIndex` — listed in
  ///     the error — rather than have the engine scroll the wrong list.
  ///
  /// Never scrolls a random candidate: every choice is either the only
  /// one that can move or dominant by area, and the alternative is loud.
  Element resolveScrollable(String direction) {
    final axis = _axisForDirection(direction);
    final axisName = axis == Axis.vertical ? 'vertical' : 'horizontal';

    final visible = walker.findVisibleScrollables(axis);
    if (visible.isEmpty) {
      throw ActionFailure(
        'No $axisName scrollable is visible to scroll "$direction": every '
        'list on that axis is off screen, covered, or on a page that is not '
        'showing. Something may be in the way — a dialog, bottom sheet, menu '
        'or page over the list, or a loading layer painted on it — or a '
        'route transition is still running (wait_idle waits for it). Check '
        'the current screen before scrolling.',
      );
    }

    final movable = visible.where((e) => _canScroll(e, direction)).toList();
    if (movable.isEmpty) {
      throw ActionFailure(
        'None of the ${visible.length} visible $axisName scrollable(s) can '
        'scroll "$direction" (at the end of its content, or nothing to '
        'scroll) — ${_describeScrollables(visible, visible)}.',
      );
    }
    if (movable.length == 1) return movable.single;

    final byArea = [...movable]
      ..sort((a, b) => _visibleArea(b).compareTo(_visibleArea(a)));
    final first = _visibleArea(byArea[0]);
    final second = _visibleArea(byArea[1]);
    if (second > 0 && first >= second * _dominantAreaRatio) return byArea[0];

    throw ActionFailure(
      'Ambiguous scroll: ${movable.length} $axisName scrollables are visible '
      'and can scroll "$direction" — ${_describeScrollables(movable, visible)}. '
      'Pass a scroll target (the scrollable\'s key) or its scrollIndex to '
      'disambiguate.',
    );
  }

  /// Whether the [Scrollable] element can move further in [direction] —
  /// it has content dimensions and is not already at the edge the swipe
  /// pushes it toward. Swiping "up"/"left" advances the scroll offset;
  /// "down"/"right" retreats it.
  bool _canScroll(Element scrollable, String direction) {
    final position = walker.scrollPositionOf(scrollable);
    if (position == null ||
        !position.hasPixels ||
        !position.hasContentDimensions) {
      return false;
    }
    final forward = direction == 'up' || direction == 'left';
    return forward
        ? position.pixels < position.maxScrollExtent
        : position.pixels > position.minScrollExtent;
  }

  /// The area of the part of [element] a person can see — its rect clipped
  /// to the screen and every clipping ancestor
  /// ([TreeWalkerGeometry.visibleRectOf]). Its unclipped rect is not used:
  /// a list mostly scrolled or slid out of view, or a `PageView` page with
  /// a sliver of itself on screen, would rank by pixels nobody sees.
  double _visibleArea(Element element) {
    final rect = walker.visibleRectOf(element);
    const side = TreeWalkerGeometry.minVisibleSide;
    if (rect == null || rect.width < side || rect.height < side) return 0;
    return rect.width * rect.height;
  }

  /// Describes scrollable candidates with the `scrollIndex` a caller can
  /// pass back — the index into [all], the same DFS order as the `/screen`
  /// dump — so an ambiguity error is directly actionable.
  String _describeScrollables(List<Element> shown, List<Element> all) {
    return shown.map((e) {
      final index = all.indexOf(e);
      final rect = walker.rectOfElement(e);
      final rectPart = rect != null ? ' @ ${_fmtRect(rect)}' : '';
      return '[scrollIndex $index ${e.widget.runtimeType}$rectPart]';
    }).join(', ');
  }
}
