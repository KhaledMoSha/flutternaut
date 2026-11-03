part of '../tree_walker.dart';

// ---------------------------------------------------------------------------
// Selection state (selected / not selected / mixed)
// ---------------------------------------------------------------------------
//
// One rule answers "is this control selected?" for the `/screen` dump
// (`selected` / `mixed` on a control's node) and for `/is_selected`, so a
// catalog mark and an `if not_selected` on it can never disagree.
//
// The state is read from the accessibility flags a control declares —
// `Semantics(checked:)`, `Semantics(toggled:)`, `Semantics(selected:)`,
// `Semantics(mixed:)` — and from nothing else. Every selectable Flutter
// control publishes its state that way (a Checkbox or Radio inside itself, a
// chip or a navigation destination on a wrapper above its tap surface, a tab
// as a leaf inside it), and an app-drawn row declares it the same way when it
// wraps its tap surface in a `Semantics` with those flags. A per-widget table
// of `value`/`groupValue` fields would duplicate that across SDK versions and
// miss every custom row.

/// How far up [TreeWalkerSelection.selectionOf] looks for the layers of one
/// control and for the `Semantics` wrapper that describes it: Material puts
/// some thirty elements between a navigation destination's tap surface and
/// the `Semantics(selected:)` that describes it (same depth as a button's
/// label run, [_stateRunHops]).
const int _selectionHops = _stateRunHops;

/// How far above a `ListTile` its `CheckboxListTile` / `SwitchListTile` /
/// `RadioListTile` wrapper sits (the tile is the wrapper's direct build).
const int _tileWrapperHops = 4;

/// The selection state of a control ([TreeWalkerSelection.selectionOf]).
sealed class Selection {
  const Selection();
}

/// The control declares a state: selected / checked / on ([value] true) or
/// not ([value] false).
final class SelectedState extends Selection {
  /// Whether the control is selected.
  final bool value;

  /// Creates a declared state.
  const SelectedState(this.value);
}

/// A tristate control in its mixed (partly selected) state.
final class MixedState extends Selection {
  /// Creates the mixed state.
  const MixedState();
}

/// The control declares no selection state: a plain button, a row whose
/// state lives on an enabled checkbox inside it, a tile's highlight.
final class NoSelection extends Selection {
  /// Creates the no-state answer.
  const NoSelection();
}

/// Selection state: which `Semantics` flags describe a control.
extension TreeWalkerSelection on TreeWalker {
  /// The selection state of [owner], the control [stateOwner] (the dump) or
  /// [resolveStateTarget] (the routes) returned.
  ///
  /// The two can name different layers of one control — the dump owns a
  /// row through its `InkWell`, a text locator through the `GestureDetector`
  /// the `InkWell` builds — so the rule first lifts [owner] to the outermost
  /// layer of its control ([_liftOwner]) and reads the state there:
  ///
  ///  1. A specific control (a `Checkbox`, a `Switch`, a `ListTile`, an
  ///     `IconButton`) carries its own flag inside itself ([_innerSelection]).
  ///  2. Otherwise the first flagged `Semantics` above the control describes
  ///     it, when nothing else tappable sits under that `Semantics`
  ///     ([_wrapperSelection]): an app row's wrapper, a chip's, a radio's, a
  ///     navigation destination's. A section-wide `Semantics(selected:)`
  ///     around several controls describes none of them.
  ///  3. A generic tap surface that is not a page wrapper shows its state on
  ///     an indicator inside it: a tab's state leaf, a display-only checkbox
  ///     in a custom row ([_innerSelection] again).
  Selection selectionOf(Element owner) {
    final top = _liftOwner(owner);
    if (_isSpecificControl(top)) {
      final own = _innerSelection(top, indicatorsOnly: false);
      if (own is! NoSelection) return own;
      return _wrapperSelection(top);
    }
    final wrapper = _wrapperSelection(top);
    if (wrapper is! NoSelection) return wrapper;
    if (_isPageWrapper(top)) return const NoSelection();
    return _innerSelection(top, indicatorsOnly: true);
  }

  /// The outermost layer of [owner]'s control: an ancestor tap control with
  /// the same bounds or the same text label is the same control (an
  /// `InkWell` over the `GestureDetector` it builds); any other control, a
  /// scroll view, a route or a field ends the lift.
  Element _liftOwner(Element owner) {
    var top = owner;
    final label = textRunLabel(owner);
    var hops = 0;
    owner.visitAncestorElements((a) {
      final w = a.widget;
      if (w is Scrollable || w is EditableText || _isLabelBoundary(w)) {
        return false;
      }
      if (_routeOfScope(a) != null) return false;
      if (_elementState(a) != null) {
        final sameLabel = label != null && textRunLabel(a) == label;
        if (!sameLabel && !_isLayerOf(a, top)) return false;
        top = a;
      }
      return ++hops < _selectionHops;
    });
    return top;
  }

  /// Step 2: the first flagged `Semantics` above [top] — reached without
  /// crossing another control, a scroll view, a route or a field — when its
  /// subtree holds no tap control outside [top]'s own subtree.
  Selection _wrapperSelection(Element top) {
    Selection found = const NoSelection();
    var hops = 0;
    top.visitAncestorElements((a) {
      final w = a.widget;
      if (w is Scrollable || w is EditableText || _isLabelBoundary(w)) {
        return false;
      }
      if (_routeOfScope(a) != null || _elementState(a) != null) return false;
      final flag = _flagOf(a, top);
      if (flag != null) {
        if (!_holdsForeignControl(a, top)) found = flag;
        return false;
      }
      return ++hops < _selectionHops;
    });
    return found;
  }

  /// Steps 1 and 3: the flags declared inside [top], in tree order. A nested
  /// enabled control keeps its own state (its subtree is skipped) unless
  /// [top] is the tile of a `CheckboxListTile` / `SwitchListTile` /
  /// `RadioListTile`, whose tap flips that control; a disabled nested
  /// control is a display-only indicator and is read. With [indicatorsOnly]
  /// a flagged `Semantics` that itself wraps an enabled control describes
  /// that control, not [top]. Several indicators that disagree (page dots)
  /// are no state.
  Selection _innerSelection(Element top, {required bool indicatorsOnly}) {
    final flags = <bool>[];
    var mixed = false;
    final tile = _isSelectableTile(top);
    void visit(Element e) {
      if (!identical(e, top)) {
        if (_isLabelBoundary(e.widget)) return;
        final flag = _flagOf(e, top);
        if (flag != null) {
          if (indicatorsOnly && _holdsEnabledControl(e)) return;
          if (flag is MixedState) mixed = true;
          if (flag is SelectedState) flags.add(flag.value);
          return;
        }
        final state = _elementState(e);
        if (state == true && !tile && !_isLayerOf(e, top)) return;
      }
      e.visitChildren(visit);
    }

    visit(top);
    if (mixed) return const MixedState();
    if (flags.isEmpty) return const NoSelection();
    if (flags.any((f) => f != flags.first)) return const NoSelection();
    return SelectedState(flags.first);
  }

  /// The selection flag a `Semantics` element declares, or null for any
  /// other widget and for a `Semantics` without one. Two flags never count:
  /// the `selected` a non-selectable `RawChip` (an `ActionChip`, an
  /// `InputChip` used as a button) always declares false, and the `selected`
  /// highlight every `ListTile` declares when [top] is that tile — a
  /// highlighted drawer row is not a selection a tap toggles.
  Selection? _flagOf(Element e, Element top) {
    final w = e.widget;
    if (w is! Semantics) return null;
    final p = w.properties;
    if (p.mixed == true) return const MixedState();
    final checked = p.checked ?? p.toggled;
    if (checked != null) return SelectedState(checked);
    final selected = p.selected;
    if (selected == null) return null;
    if (top.widget is ListTile) return null;
    if (_isInertChip(e)) return null;
    return SelectedState(selected);
  }

  /// Whether [semantics] is the node a `RawChip` builds for a chip that
  /// cannot be selected (`onSelected` null and not selected).
  bool _isInertChip(Element semantics) {
    RawChip? chip;
    semantics.visitAncestorElements((a) {
      final w = a.widget;
      if (w is RawChip) chip = w;
      return false;
    });
    final c = chip;
    return c != null && c.onSelected == null && !c.selected;
  }

  /// Whether [top] is the `ListTile` a `CheckboxListTile`, `SwitchListTile`
  /// or `RadioListTile` builds — the one tile whose tap flips the control
  /// inside it.
  bool _isSelectableTile(Element top) {
    if (top.widget is! ListTile) return false;
    var found = false;
    var hops = 0;
    top.visitAncestorElements((a) {
      final w = a.widget;
      if (w is CheckboxListTile || w is SwitchListTile || w is RadioListTile) {
        found = true;
        return false;
      }
      return ++hops < _tileWrapperHops;
    });
    return found;
  }

  /// Whether the subtree of [semantics] holds a tap control that is not
  /// part of [top] — then the `Semantics` describes a group, not [top].
  bool _holdsForeignControl(Element semantics, Element top) {
    var foreign = false;
    void visit(Element e) {
      if (foreign || identical(e, top)) return;
      if (_isLabelBoundary(e.widget)) return;
      if (_elementState(e) != null) {
        foreign = true;
        return;
      }
      e.visitChildren(visit);
    }

    semantics.visitChildren(visit);
    return foreign;
  }

  /// Whether the subtree of [semantics] holds an enabled tap control — a
  /// flagged wrapper around a control of its own, inside a generic surface.
  bool _holdsEnabledControl(Element semantics) {
    var held = false;
    void visit(Element e) {
      if (held) return;
      if (_isLabelBoundary(e.widget)) return;
      if (_elementState(e) == true) {
        held = true;
        return;
      }
      e.visitChildren(visit);
    }

    semantics.visitChildren(visit);
    return held;
  }

  /// Whether [e] is a layer of the control [top] rather than a control of
  /// its own: the same bounds (within the `Semantics`-wrapper slack), or
  /// essentially the same pixels (intersection over union of at least
  /// [_stackedOverlap] — the `InkWell` a Material button keeps inside its
  /// padding). A checkbox in a row shares far less of the row.
  bool _isLayerOf(Element e, Element top) {
    final ra = _rectOf(e);
    final rb = _rectOf(top);
    if (ra == null || rb == null) return false;
    if (_sameRect(ra, rb)) return true;
    final x1 = ra.x > rb.x ? ra.x : rb.x;
    final y1 = ra.y > rb.y ? ra.y : rb.y;
    final x2 = (ra.x + ra.width) < (rb.x + rb.width)
        ? ra.x + ra.width
        : rb.x + rb.width;
    final y2 = (ra.y + ra.height) < (rb.y + rb.height)
        ? ra.y + ra.height
        : rb.y + rb.height;
    if (x2 <= x1 || y2 <= y1) return false;
    final inter = (x2 - x1) * (y2 - y1);
    final union = ra.width * ra.height + rb.width * rb.height - inter;
    return union > 0 && inter / union >= _stackedOverlap;
  }

  /// Whether [top] is a page-sized surface (a keyboard-dismiss detector, a
  /// card filling the screen): an indicator inside it describes something
  /// smaller than the surface.
  bool _isPageWrapper(Element top) {
    final rect = _rectOf(top);
    final screen = _screenSize;
    if (rect == null || screen == null) return false;
    return rect.height >= screen.height / 2;
  }

  /// Why a control without a selection state cannot answer `/is_selected`.
  String notSelectableReason(Element control) {
    final suffix = control.widget is ListTile
        ? " (a ListTile's selected highlight is not a selection state)"
        : '';
    return '${describeControl(control)} has no selected state: it is not a '
        'checkbox, radio, switch, chip, tab, segment or navigation '
        'destination, and no Semantics(checked:, selected:, toggled:) around '
        'it or inside it declares one for it alone — address the selection '
        'control itself (a row\'s state may sit on the checkbox or radio '
        'inside it)$suffix';
  }
}
