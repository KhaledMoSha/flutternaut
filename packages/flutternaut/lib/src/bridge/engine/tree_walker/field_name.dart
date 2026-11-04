part of '../tree_walker.dart';

// ---------------------------------------------------------------------------
// A field's name
// ---------------------------------------------------------------------------
//
// A text locator never matches what a text field holds (bridge protocol
// 1.10.0, [_drawnText]). A field is therefore named by its key, by the name
// its decoration declares — `labelText` / `hintText` / `placeholder`, faded
// out once the field is filled but still its name — or by a caption beside
// it (protocol 1.11.1). The `/screen` dump carries the declared name as
// `field_name` on the field's node, so a filled field keeps the locator it
// had when empty; the field routes (`/type`, `/clear_text`, `/get_text`,
// `/read`, `/wait_for_text`) act on the field a name or caption resolves to,
// and a declared name resolves to the field on the visibility and tap routes
// too ([fieldAwareMatches]).

/// A field's name and reading a field through it.
extension TreeWalkerFieldName on TreeWalker {
  /// The name of the field [fieldOrEditable] is (a [TextField] /
  /// [CupertinoTextField] wrapper, or the [EditableText] inside one): the
  /// text its decoration declares — `InputDecoration.labelText`, else
  /// `hintText`, else a Cupertino `placeholder` — trimmed, with a letter or
  /// digit in it. Never a text merely drawn inside the wrapper (a dial-code
  /// prefix, a counter, helper or error text): those are not the field's
  /// name, and a person calls the field by its label or hint. Kept only
  /// when that name resolves back to this very field
  /// ([_resolveEditableElementByText]): two fields sharing a hint leave the
  /// second unnamed. Null for a bare [EditableText] with no wrapper, and
  /// for a field that declares no name (a caption beside it names it then,
  /// see [findReadableByTextMatch]).
  String? fieldNameOf(Element fieldOrEditable) {
    final wrapper = _fieldWrapperOf(fieldOrEditable);
    if (wrapper == null) return null;
    final editable = _editableOf(wrapper);
    if (editable == null) return null;
    final name = _declaredName(wrapper.widget);
    if (name == null) return null;
    final resolved = _resolveEditableElementByText(name);
    return resolved != null && identical(resolved, editable) ? name : null;
  }

  /// The name a field wrapper declares for itself, or null.
  String? _declaredName(Widget wrapper) {
    String? raw;
    if (wrapper is TextField) {
      final d = wrapper.decoration;
      raw = d?.labelText ?? d?.hintText;
    } else if (wrapper is CupertinoTextField) {
      raw = wrapper.placeholder;
    }
    final name = raw == null ? null : TreeWalker.normalizeText(raw);
    return name == null || !_hasAlnum(name) ? null : name;
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
  /// [match] mode — or, when that text names a field, the field itself,
  /// whose [ElementInfo.text] is its value (`""` when empty). A text names a
  /// field when it is drawn inside a [TextField] / [CupertinoTextField]
  /// (its label, hint or placeholder — [_fieldNamedBy]) or when it is a
  /// caption beside one: the on-screen field on the same row or just below
  /// it, within a row's height ([_nearestFieldElement]) — the one rule
  /// `/type` and `/clear_text` already name a field by, so the label that
  /// types into a field is the label that reads it. A text with no field to
  /// name reads itself. Known limit: a heading drawn right above an
  /// unrelated field, within a row, reads that field; a wrong expected
  /// value then fails, never passes. Null when nothing matches.
  ElementInfo? findReadableByTextMatch(String text, TextMatch match) {
    final layers = _routeLayers();
    Element? el;
    for (final match in _findAllElementsWhere(_textMatcher(text, match))) {
      if (layers.hides(match) || _isOffstage(match)) continue;
      el = match;
      break;
    }
    if (el == null) return null;
    final named = _fieldNamedBy(el);
    if (named != null) return extractInfo(named);
    final rect = _rectOf(el);
    final beside = rect == null ? null : _nearestFieldElement(rect, layers);
    return extractInfo(beside ?? el);
  }

  /// [matches] of a text locator with every match that is drawn inside a
  /// field wrapper (its label, hint or placeholder — [_fieldNamedBy])
  /// replaced by that field's [EditableText], in order, each field once.
  /// Applied only when every match names a field: the catalog hands out a
  /// field's hint as its locator, and the hint is faded out once the field
  /// is filled — a visibility check on that locator judges the field, not
  /// the hint. Taps keep resolving the hint themselves (a field under an
  /// `AbsorbPointer` is reached through the handler over it). A caption
  /// beside a field is never mapped here: it stays the caption.
  List<Element> fieldAwareMatches(List<Element> matches) {
    if (matches.isEmpty) return matches;
    final mapped = <Element>[];
    for (final m in matches) {
      final field = _fieldNamedBy(m);
      if (field == null) return matches;
      if (!mapped.any((e) => identical(e, field))) mapped.add(field);
    }
    return mapped;
  }
}
