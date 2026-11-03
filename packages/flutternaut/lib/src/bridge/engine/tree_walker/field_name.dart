part of '../tree_walker.dart';

// ---------------------------------------------------------------------------
// A field's name
// ---------------------------------------------------------------------------
//
// A text locator never matches what a text field holds (bridge protocol
// 1.10.0, [_drawnText]). A field is therefore named by its key, by the text
// drawn inside it — its `labelText` / `hintText` / `placeholder`, faded out
// once the field is filled but still its name — or by a caption beside it.
// The `/screen` dump carries that name as `field_name` on the field's node,
// so a filled field keeps the locator it had when empty, and the read routes
// (`/get_text`, `/read`, `/wait_for_text`) answer with the field's value when
// a locator names the field.

/// A field's name and reading a field through it.
extension TreeWalkerFieldName on TreeWalker {
  /// The name of the field [fieldOrEditable] is (a [TextField] /
  /// [CupertinoTextField] wrapper, or the [EditableText] inside one): the
  /// first text with a letter or digit drawn inside the wrapper, outside
  /// the input itself, in tree order, whatever its opacity, that is not
  /// below the input (helper, error and counter text sit under it). Kept
  /// only when that text resolves back to this very field
  /// ([_resolveEditableElementByText]): two fields sharing a hint, or a
  /// heading drawn earlier with the same text, leave the field unnamed.
  /// Null for a bare [EditableText] with no wrapper.
  String? fieldNameOf(Element fieldOrEditable) {
    final wrapper = _fieldWrapperOf(fieldOrEditable);
    if (wrapper == null) return null;
    final editable = _editableOf(wrapper);
    if (editable == null) return null;
    final inputRect = _rectOf(editable);
    final inputBottom =
        inputRect == null ? null : inputRect.y + inputRect.height;

    String? name;
    void visit(Element child) {
      if (name != null || identical(child, editable)) return;
      final text = _drawnText(child.widget);
      if (text != null) {
        if (!_hasAlnum(text)) return;
        final rect = _rectOf(child);
        if (inputBottom != null &&
            rect != null &&
            rect.y + rect.height / 2 > inputBottom) {
          return;
        }
        name = text;
        return;
      }
      child.visitChildren(visit);
    }

    wrapper.visitChildren(visit);
    final found = name;
    if (found == null) return null;
    final resolved = _resolveEditableElementByText(found);
    return resolved != null && identical(resolved, editable) ? found : null;
  }

  /// The [TextField] / [CupertinoTextField] element that is
  /// [fieldOrEditable] or wraps it, or null for a bare [EditableText].
  Element? _fieldWrapperOf(Element fieldOrEditable) {
    final w = fieldOrEditable.widget;
    if (w is TextField || w is CupertinoTextField) return fieldOrEditable;
    if (w is! EditableText) return null;
    Element? wrapper;
    fieldOrEditable.visitAncestorElements((a) {
      if (a.widget is TextField || a.widget is CupertinoTextField) {
        wrapper = a;
        return false;
      }
      return true;
    });
    return wrapper;
  }

  /// The element a text locator reads: the first drawn match of [text] in
  /// [match] mode — or, when that text names a field (it is drawn inside a
  /// [TextField] / [CupertinoTextField]: a label, a hint, a placeholder),
  /// the field itself, whose [ElementInfo.text] is its value (`""` when
  /// empty). A caption beside a field reads itself. Null when nothing
  /// matches.
  ElementInfo? findReadableByTextMatch(String text, TextMatch match) {
    final el = _findElementWhere(_textMatcher(text, match));
    if (el == null) return null;
    final field = _fieldNamedBy(el);
    return extractInfo(field ?? el);
  }
}
