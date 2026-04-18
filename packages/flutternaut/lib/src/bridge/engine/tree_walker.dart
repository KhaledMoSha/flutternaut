import 'package:flutter/material.dart';

import '../models/element_info.dart';
import '../models/element_rect.dart';
import '../models/visibility_result.dart';

/// Walks the Flutter element tree to find widgets by [ValueKey] or text,
/// read their properties, check visibility, and dump the tree structure.
///
/// All operations are synchronous and must run on the main UI thread.
class TreeWalker {
  // ---------------------------------------------------------------------------
  // Finding
  // ---------------------------------------------------------------------------

  /// Finds the first element whose [ValueKey] value matches [keyValue].
  ElementInfo? findByKey(String keyValue) {
    return _findWhere((element) {
      final key = element.widget.key;
      return key is ValueKey && key.value.toString() == keyValue;
    });
  }

  /// Finds the first [Text] or [EditableText] whose content matches [text] exactly.
  ElementInfo? findByText(String text) {
    return _findWhere((element) {
      final widget = element.widget;
      if (widget is Text && widget.data == text) return true;
      if (widget is EditableText && widget.controller.text == text) return true;
      return false;
    });
  }

  /// Finds the first [Text] or [EditableText] whose content contains [substring].
  ElementInfo? findByTextContains(String substring) {
    return _findWhere((element) {
      final widget = element.widget;
      if (widget is Text &&
          widget.data != null &&
          widget.data!.contains(substring)) {
        return true;
      }
      if (widget is EditableText &&
          widget.controller.text.contains(substring)) {
        return true;
      }
      return false;
    });
  }

  /// Returns all elements that have a [ValueKey].
  List<ElementInfo> findAllKeyed() {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const [];

    final results = <ElementInfo>[];
    void visitor(Element element) {
      if (element.widget.key is ValueKey) {
        results.add(extractInfo(element));
      }
      element.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);
    return results;
  }

  // ---------------------------------------------------------------------------
  // Visibility
  // ---------------------------------------------------------------------------

  /// Checks if a widget found by text is visible within the screen viewport.
  VisibilityResult checkTextVisible(String text) {
    final info = findByText(text);
    return _checkVisibility(info);
  }

  /// Checks if a widget found by key is visible within the screen viewport.
  VisibilityResult checkVisibleByKey(String keyValue) {
    final info = findByKey(keyValue);
    return _checkVisibility(info);
  }

  // ---------------------------------------------------------------------------
  // Tree dump
  // ---------------------------------------------------------------------------

  /// Dumps the widget tree as a structured map, limited to [maxDepth].
  Map<String, dynamic> dumpTree({int maxDepth = 30}) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const {'error': 'No root element'};
    return _dumpElement(rootElement, 0, maxDepth);
  }

  // ---------------------------------------------------------------------------
  // Element info extraction
  // ---------------------------------------------------------------------------

  /// Extracts full info from an [Element], including type, key, text,
  /// position, enabled/checked state.
  ///
  /// Visible for testing.
  ElementInfo extractInfo(Element element) {
    final widget = element.widget;
    final key = widget.key;
    final keyStr = key is ValueKey ? key.value.toString() : null;

    ElementRect? rect;
    final renderObject = element.renderObject;
    if (renderObject is RenderBox && renderObject.hasSize) {
      try {
        final offset = renderObject.localToGlobal(Offset.zero);
        rect = ElementRect(
          x: offset.dx,
          y: offset.dy,
          width: renderObject.size.width,
          height: renderObject.size.height,
        );
      } on Exception {
        // RenderObject may not be attached or laid out.
      }
    }

    return ElementInfo(
      type: widget.runtimeType.toString(),
      key: keyStr,
      text: extractText(element),
      rect: rect,
      enabled: _extractEnabled(widget),
      checked: _extractChecked(widget),
    );
  }

  /// Extracts text content from an element or its first text-bearing descendant.
  ///
  /// Visible for testing.
  String? extractText(Element element) {
    final widget = element.widget;
    if (widget is Text) return widget.data;
    if (widget is EditableText) return widget.controller.text;

    String? found;
    element.visitChildren((child) {
      if (found != null) return;
      found = extractText(child);
    });
    return found;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

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

  VisibilityResult _checkVisibility(ElementInfo? info) {
    if (info == null) {
      return const VisibilityResult(exists: false, visible: false);
    }

    final screenSize = _screenSize;
    if (info.rect == null || screenSize == null) {
      return VisibilityResult(exists: true, visible: false, info: info);
    }

    final r = info.rect!;
    final visible = r.x + r.width > 0 &&
        r.x < screenSize.width &&
        r.y + r.height > 0 &&
        r.y < screenSize.height;

    return VisibilityResult(exists: true, visible: visible, info: info);
  }

  Size? get _screenSize {
    final rootElement = WidgetsBinding.instance.rootElement;
    return rootElement?.renderObject?.paintBounds.size;
  }

  Map<String, dynamic> _dumpElement(Element element, int depth, int maxDepth) {
    final node = <String, dynamic>{
      'type': element.widget.runtimeType.toString(),
    };

    final key = element.widget.key;
    if (key is ValueKey) {
      node['key'] = key.value.toString();
    }

    final text = extractText(element);
    if (text != null) node['text'] = text;

    final renderObject = element.renderObject;
    if (renderObject is RenderBox && renderObject.hasSize) {
      try {
        final offset = renderObject.localToGlobal(Offset.zero);
        node['rect'] = {
          'x': offset.dx,
          'y': offset.dy,
          'w': renderObject.size.width,
          'h': renderObject.size.height,
        };
      } on Exception {
        // Skip position if not available.
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

  bool? _extractEnabled(Widget widget) {
    if (widget is TextField) return widget.enabled ?? true;
    if (widget is ElevatedButton) return widget.onPressed != null;
    if (widget is TextButton) return widget.onPressed != null;
    if (widget is OutlinedButton) return widget.onPressed != null;
    if (widget is FilledButton) return widget.onPressed != null;
    if (widget is IconButton) return widget.onPressed != null;
    if (widget is Switch) return widget.onChanged != null;
    if (widget is Checkbox) return widget.onChanged != null;
    return null;
  }

  bool? _extractChecked(Widget widget) {
    if (widget is Checkbox) return widget.value;
    if (widget is Switch) return widget.value;
    return null;
  }
}
