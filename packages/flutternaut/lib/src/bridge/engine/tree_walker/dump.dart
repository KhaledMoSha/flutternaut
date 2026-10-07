part of '../tree_walker.dart';

/// The `/tree` and `/screen` dumps.
extension TreeWalkerDump on TreeWalker {
  /// Dumps the widget tree as a structured map, limited to [maxDepth].
  Map<String, dynamic> dumpTree({int maxDepth = 30}) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const {'error': 'No root element'};
    return _dumpElement(rootElement, 0, maxDepth);
  }

  /// Dumps only the widgets actually displayed on screen right now.
  ///
  /// Unlike [dumpTree], this prunes framework scaffolding
  /// (ProviderScope, MaterialApp, RestorationScope, …) and off-screen
  /// branches. A node is emitted only when it is both **on screen**
  /// (laid out, non-zero size, rect intersecting the viewport) and
  /// **meaningful** (keyed / text / interactive). Children always
  /// recurse, so a meaningful leaf under unmeaningful wrappers is still
  /// found — it just attaches to the nearest emitted ancestor, so the
  /// hierarchy that matters (a button inside a row) is preserved
  /// without the wrapper noise.
  Map<String, dynamic> dumpVisibleTree() {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const {'error': 'No root element'};

    final screen = _screenSize;
    final elements = <Map<String, dynamic>>[];

    // Per-axis scrollable lists share [findVisibleScrollables]' filter and
    // DFS order with the `/swipe` `scrollIndex` resolution and the
    // direction-only auto-pick, so the index a consumer reads from the dump
    // resolves to the same scrollable when it scrolls — they can never
    // disagree. That filter prunes hidden routes exactly as this walk does
    // ([_RouteLayers.hidesScope] below, one snapshot for both) and drops a
    // scrollable covered at every point as the node gate below does, so no
    // list takes a number the dump never shows.
    final layers = _routeLayers();
    final verticalScrollables = _visibleScrollables(Axis.vertical, layers);
    final horizontalScrollables = _visibleScrollables(Axis.horizontal, layers);
    final nthIndex = _NthIndex(this);

    // [parentLabel] is the text of the nearest already-emitted ancestor. A
    // descendant that only re-presents that label — a button's inner
    // GestureDetector/Text, or a Text's child RichText — is the same control's
    // render machinery, not a distinct element. Emitting it would flood the
    // catalog with duplicate, indistinguishable refs (one "Get Started" button
    // becoming four identical rows), so we emit the outermost node for a label
    // run and skip the inner echoes.
    void walk(
      Element element,
      List<Map<String, dynamic>> sink,
      String? parentLabel,
    ) {
      // A route hidden behind a dialog/sheet/page, or one that is closing,
      // is not on screen for the user: its whole subtree is skipped.
      if (layers.hidesScope(element)) return;

      var childSink = sink;
      var childLabel = parentLabel;
      Map<String, dynamic>? node;

      // A scroll view wrapper (ListView, PageView, …) is represented by the
      // single Scrollable it builds — the scrollable node adopts its type
      // name and key — so the wrapper itself is never emitted (a keyed
      // ListView must not become two nodes carrying the same key).
      final widget = element.widget;
      final coverage = _scrollContainerName(widget) == null &&
              _isMeaningful(element) &&
              _isOnScreen(element, screen)
          ? _coverage(element, screen)
          : _Coverage.covered;
      if (coverage != _Coverage.covered) {
        final info = extractInfo(element);
        final label = _nodeLabel(element, screen, layers);
        final nodeText = label?.text;
        if (!_isRedundant(element, info, nodeText, parentLabel)) {
          node = <String, dynamic>{'type': info.type};
          if (info.key != null) node['key'] = info.key;
          if (nodeText != null) node['text'] = nodeText;
          // A label read off a descendant text: that text's own rect, the
          // one a `near` locator anchored on this label measures rows by.
          final source = label?.source;
          final labelRect = source == null ? null : _rectOf(source);
          if (labelRect != null) node['label_rect'] = labelRect.toJson();
          final semantics = semanticsOf(element);
          if (semantics != null) node['semantics'] = semantics;
          final semanticsId = semanticsIdOf(element);
          if (semanticsId != null) node['semantics_id'] = semanticsId;
          final rect = _visibleRect(element, screen);
          if (rect != null) {
            node['rect'] = ElementRect(
              x: rect.left,
              y: rect.top,
              width: rect.width,
              height: rect.height,
            ).toJson();
          }
          if (coverage == _Coverage.partial) node['partial'] = true;
          final enabled = dumpState(element);
          if (enabled != null) node['enabled'] = enabled;
          if (info.checked != null) node['checked'] = info.checked;
          nthIndex.annotate(element, node, nodeText, semantics, semanticsId);
          if (widget is Scrollable) {
            _applyScrollInfo(
              element,
              widget,
              node,
              verticalScrollables,
              horizontalScrollables,
            );
          }
          final kids = <Map<String, dynamic>>[];
          node['children'] = kids;
          sink.add(node);
          childSink = kids;
          final trimmed = nodeText?.trim();
          if (trimmed != null && trimmed.isNotEmpty) childLabel = trimmed;
        }
      }

      element.visitChildren((child) => walk(child, childSink, childLabel));

      if (node != null && (node['children'] as List).isEmpty) {
        node.remove('children');
      }
    }

    rootElement.visitChildren((child) => walk(child, elements, null));

    return {
      if (screen != null) 'screen': {'w': screen.width, 'h': screen.height},
      'animating': isTransitioning,
      'animations': runningAnimations(),
      'elements': elements,
    };
  }

  /// Whether [element] would only duplicate an ancestor already in the dump —
  /// a render primitive carrying no addressable identity of its own — so it can
  /// be skipped to keep each on-screen control to a single node.
  ///
  /// Keyed, enabled/checked (interactive), and icon/image nodes always survive.
  /// A pure [Text]/[RichText]/[EditableText] is redundant when its text echoes
  /// the nearest emitted ancestor's label (the inner `Text`/`RichText` of a
  /// button or a `Text`), or when it carries no text at all (an empty leaf).
  bool _isRedundant(
    Element element,
    ElementInfo info,
    String? nodeText,
    String? parentLabel,
  ) {
    if (info.key != null || info.enabled != null || info.checked != null) {
      return false;
    }
    final widget = element.widget;
    if (widget is Icon || widget is Image) return false;
    final text = nodeText?.trim() ?? '';
    if (text.isEmpty) {
      // An empty EditableText is the input machinery of a TextField /
      // CupertinoTextField that is already a node of its own; a bare one
      // (a custom field built straight on EditableText) has no such
      // ancestor and must survive, or the empty field vanishes from the
      // screen readout until it has a value.
      if (widget is EditableText) return _hasFieldAncestor(element);
      return widget is Text || widget is RichText;
    }
    final parent = parentLabel?.trim() ?? '';
    return parent.isNotEmpty && text == parent;
  }

  /// Whether [element] sits inside a [TextField] or [CupertinoTextField] —
  /// the wrappers that are emitted as the field's own dump node.
  bool _hasFieldAncestor(Element element) {
    var found = false;
    element.visitAncestorElements((ancestor) {
      final w = ancestor.widget;
      if (w is TextField || w is CupertinoTextField) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  Map<String, dynamic> _dumpElement(Element element, int depth, int maxDepth) {
    final node = <String, dynamic>{
      'type': element.widget.runtimeType.toString(),
    };

    final key = TreeWalker.keyOf(element.widget);
    if (key != null) node['key'] = key;

    final text = extractText(element);
    if (text != null) node['text'] = text;

    final renderObject = element.renderObject;
    if (renderObject is RenderBox && renderObject.hasSize) {
      // A detached render object has no position on screen.
      if (renderObject.attached) {
        final offset = renderObject.localToGlobal(Offset.zero);
        node['rect'] = {
          'x': offset.dx,
          'y': offset.dy,
          'w': renderObject.size.width,
          'h': renderObject.size.height,
        };
      }
    }

    if (depth < maxDepth) {
      final children = <Map<String, dynamic>>[];
      element.visitChildren((child) {
        children.add(_dumpElement(child, depth + 1, maxDepth));
      });
      if (children.isNotEmpty) {
        node['children'] = children;
      }
    }

    return node;
  }
}

/// Computes, for dump nodes, the `nth` a text or semantics locator needs
/// to reach them — the one visible-match list every route indexes
/// ([TreeWalkerVisibility.visibleMatches]) — so a catalog ref resolves to
/// exactly the widget it names even when its label repeats on screen.
///
/// Emitted as `text_nth`/`text_matches`, `semantics_nth`/
/// `semantics_matches` and `semantics_id_nth`/`semantics_id_matches`, only
/// when the label has more than one visible match and the node is one of
/// them. An identifier is a `semantics` locator target too, so its
/// candidates are exactly what that locator resolves to. Candidate lists
/// are computed once per label per dump.
class _NthIndex {
  _NthIndex(this._walker);

  final TreeWalker _walker;
  final Map<String, List<Element>> _byText = {};
  final Map<String, List<Element>> _bySemantics = {};

  void annotate(
    Element node,
    Map<String, dynamic> out,
    String? text,
    String? semantics,
    String? semanticsId,
  ) {
    if (text != null && text.isNotEmpty) {
      final candidates = _byText.putIfAbsent(text, () {
        final matches = _walker.findAllElementsByText(text);
        return matches.length > 1 ? _walker.visibleMatches(matches) : const [];
      });
      _emit(node, out, 'text', candidates);
    }
    if (semantics != null) {
      _emit(node, out, 'semantics', _semanticsCandidates(semantics));
    }
    if (semanticsId != null) {
      _emit(node, out, 'semantics_id', _semanticsCandidates(semanticsId));
    }
  }

  /// The visible matches of a `semantics` locator [target] (label or
  /// identifier), or none when it matches at most one widget.
  List<Element> _semanticsCandidates(String target) =>
      _bySemantics.putIfAbsent(target, () {
        final matches = _walker.findAllElementsBySemantics(target);
        return matches.length > 1 ? _walker.visibleMatches(matches) : const [];
      });

  void _emit(
    Element node,
    Map<String, dynamic> out,
    String prefix,
    List<Element> candidates,
  ) {
    if (candidates.length < 2) return;
    final index = candidates.indexWhere(
      (c) => _related(c, node),
    );
    if (index < 0) return;
    out['${prefix}_nth'] = index;
    out['${prefix}_matches'] = candidates.length;
  }

  /// Whether [a] and [b] are the same element or one encloses the other —
  /// a button node's label is a Text leaf inside it; a node's semantics
  /// may come from a Tooltip around it.
  static bool _related(Element a, Element b) =>
      _encloses(a, b) || _encloses(b, a);

  static bool _encloses(Element ancestor, Element node) {
    if (identical(ancestor, node)) return true;
    var found = false;
    node.visitAncestorElements((e) {
      if (identical(e, ancestor)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }
}
