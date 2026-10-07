import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/element_info.dart';
import '../models/element_rect.dart';
import '../models/visibility_result.dart';

part 'tree_walker/results.dart';
part 'tree_walker/geometry.dart';
part 'tree_walker/coverage.dart';
part 'tree_walker/routes.dart';
part 'tree_walker/labels.dart';
part 'tree_walker/controls.dart';
part 'tree_walker/semantics.dart';
part 'tree_walker/near.dart';
part 'tree_walker/visibility.dart';
part 'tree_walker/scroll.dart';
part 'tree_walker/blockers.dart';
part 'tree_walker/tap.dart';
part 'tree_walker/fields.dart';
part 'tree_walker/find.dart';
part 'tree_walker/dump.dart';

/// How a `text` locator is compared with a widget's own visible text —
/// the `match` field of a bridge request (`"exact"`, `"contains"`,
/// `"starts_with"`).
///
/// Every mode compares against the same per-widget text (a [Text] or
/// `Text.rich`, a [RichText], or an [EditableText]'s value — never a
/// container's merged descendants), so the three modes only differ in the
/// comparison itself and resolve through the same nth / ambiguity /
/// visibility / hit-test pipeline.
enum TextMatch {
  /// The widget's text equals the locator, **case-sensitively** — the
  /// default, and the only mode a catalog ref records.
  exact,

  /// The widget's text contains the locator as a substring,
  /// case-insensitively — for labels a test only knows part of
  /// ("Start 7-Day Free Trial").
  contains,

  /// The widget's text begins with the locator, case-insensitively — for
  /// labels with a variable tail ("Bag · 3"), without also matching every
  /// label that merely mentions the locator somewhere inside.
  startsWith;

  /// How a locator [text] compared in this mode reads in a failure or
  /// visibility reason: `text "x"`, `text containing "x"`,
  /// `text starting with "x"`. One phrasing for every route, so a reason
  /// always says which comparison failed.
  String describe(String text) => switch (this) {
        TextMatch.exact => 'text "$text"',
        TextMatch.contains => 'text containing "$text"',
        TextMatch.startsWith => 'text starting with "$text"',
      };
}

/// Walks the Flutter element tree to find widgets by [ValueKey] or text,
/// read their properties, check visibility, and dump the tree structure.
///
/// All operations are synchronous and must run on the main UI thread.
///
/// The class holds the static helpers; everything else is an extension on
/// it, one concern per part file under `tree_walker/` (geometry, coverage,
/// routes, labels, controls, semantics, near, visibility, scroll, blockers,
/// tap, fields, find, dump).
class TreeWalker {
  /// The addressable key string of [widget], or null when it has none.
  ///
  /// Only a [ValueKey] whose value is a plain scalar — [String], [num],
  /// [bool] or an enum — is a locator a test can be written against.
  /// Packages routinely key widgets with objects (`octo_image` keys its
  /// `Image` with the `ImageProvider`, which stringifies to
  /// `ResizeImage(CachedNetworkImageProvider(...))`): those strings are
  /// noise in a screen readout and unstable as locators, so they do not
  /// count as keys anywhere in the bridge.
  static String? keyOf(Widget widget) {
    final key = widget.key;
    if (key is! ValueKey) return null;
    final value = key.value;
    if (value is String || value is num || value is bool || value is Enum) {
      return value.toString();
    }
    return null;
  }

  /// The accessibility label a widget carries for itself: an [Icon]'s
  /// `semanticLabel`, an [IconButton]'s `tooltip`, a [Tooltip]'s
  /// `message`, or a [Semantics] `label`. Null when [widget] declares
  /// none. This is what makes an icon-only control readable in the
  /// screen dump and addressable with the `semantics` locator.
  static String? ownSemanticsOf(Widget widget) {
    String? label;
    if (widget is Icon) {
      label = widget.semanticLabel;
    } else if (widget is IconButton) {
      label = widget.tooltip;
    } else if (widget is Tooltip) {
      label = widget.message;
    } else if (widget is Semantics) {
      label = widget.properties.label ?? widget.properties.tooltip;
    }
    final trimmed = label?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// The accessibility identifier a [Semantics] widget declares
  /// (`Semantics(identifier: 'btn:nav:search')` — Flutter's
  /// `resource-id` / `accessibilityIdentifier`), trimmed. Null for any
  /// other widget and for an empty identifier. Like [ownSemanticsOf], this
  /// is what the `semantics` locator matches.
  static String? ownSemanticsIdOf(Widget widget) {
    if (widget is! Semantics) return null;
    final trimmed = widget.properties.identifier?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// The object-replacement character `toPlainText` emits for each inline
  /// widget ([WidgetSpan]/[PlaceholderSpan]).
  static const String _placeholderChar = '￼';

  /// Canonical form of a display string: inline-widget placeholders
  /// removed (the whitespace they leave collapsed to one space) and the
  /// result trimmed. Applied to both sides of every text match.
  static String normalizeText(String raw) {
    if (!raw.contains(_placeholderChar)) return raw.trim();
    return raw
        .replaceAll(RegExp(r'[ \t]*￼[ \t]*'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
  }
}
