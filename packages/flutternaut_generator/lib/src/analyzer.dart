import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// Widget-builder named arguments whose value is an `IndexedWidgetBuilder`
/// closure (the closure receives an `int index` as its second positional
/// argument). Used to detect list rows.
const _indexedBuilderArgs = {
  'itemBuilder',
  'separatorBuilder',
  'findChildIndexCallback',
  'pageBuilder',
};

/// Names commonly used for the iteration variable in `itemBuilder` closures.
/// Used to normalise interpolation placeholders so `'todo_$i'` and
/// `'todo_$index'` produce the same `'todo_{index}'` output.
const _indexLikeNames = {'index', 'i', 'idx', 'n', 'position', 'pos'};

/// Widget types whose `ValueKey` should be treated as the role/widget of
/// the wrapped child rather than the wrapper itself.
const _passthroughWrappers = {'KeyedSubtree'};

/// Widget types that count as a `field` role (text-displaying / text-input).
const _fieldWidgets = {
  'Text',
  'RichText',
  'EditableText',
  'TextField',
  'TextFormField',
  'SelectableText',
};

/// Named-argument names that signal interactivity (→ `action` role).
const _actionCallbacks = {
  'onPressed',
  'onTap',
  'onLongPress',
  'onChanged',
  'onSubmitted',
  'onDoubleTap',
};

/// Scans Dart source files for `ValueKey` literals inside
/// `@FlutternautView`-annotated screens and groups them into rows
/// (list-row members) and flat elements per view.
class FlutternautAnalyzer {
  /// Scans `lib/` under [rootPath] and returns a fully-built [KeysOutput]
  /// (without the timestamp / package fields — caller fills those in).
  Map<String, ViewKeys> scanDirectory(String rootPath) {
    final libDir = Directory(p.join(rootPath, 'lib'));
    if (!libDir.existsSync()) return const {};

    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    // Pass 1: parse every file once and collect (a) const string values
    // and (b) class declarations by name (for custom-row-widget resolution).
    final constMap = <String, String>{};
    final classMap = <String, _ResolvedClass>{};
    final parsedUnits = <File, CompilationUnit>{};

    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      final result = parseString(content: source, throwIfDiagnostics: false);
      parsedUnits[file] = result.unit;
      final relPath = p.relative(file.path, from: rootPath);

      final pre = _PreScanCollector(relPath);
      result.unit.accept(pre);
      constMap.addAll(pre.constants);
      for (final entry in pre.classes.entries) {
        // First definition wins on collisions; analyzer tests don't have
        // dupes and real-world dupes would already break Flutter compile.
        classMap.putIfAbsent(entry.key, () => entry.value);
      }
    }

    // Pass 2: walk every file with a visitor that emits keys + rows,
    // resolving custom row widgets through `classMap` when needed.
    final builder = _ViewBuilder();
    for (final file in dartFiles) {
      final relPath = p.relative(file.path, from: rootPath);
      final visitor =
          _KeyVisitor(relPath, builder: builder, classMap: classMap);
      parsedUnits[file]!.accept(visitor);
    }

    return builder.build();
  }
}

/// Returns the source-text name of a [NamedType], compatible across
/// analyzer 6.x through 9.x+.
String _namedTypeLexeme(NamedType type) {
  try {
    // ignore: deprecated_member_use, avoid_dynamic_calls
    return (type as dynamic).name2.lexeme as String;
  } on NoSuchMethodError {
    // ignore: avoid_dynamic_calls
    return (type as dynamic).name.lexeme as String;
  }
}

/// Holds a class declaration alongside the file it came from, so that
/// custom-row-widget detection can record the row's source location.
class _ResolvedClass {
  final ClassDeclaration declaration;
  final String filePath;
  _ResolvedClass(this.declaration, this.filePath);
}

/// Pass-1 collector: gathers static const strings (for resolving non-literal
/// annotation arguments) and class declarations by name (for custom-row
/// resolution).
class _PreScanCollector extends RecursiveAstVisitor<void> {
  final String filePath;
  final Map<String, String> constants = {};
  final Map<String, _ResolvedClass> classes = {};

  _PreScanCollector(this.filePath);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    classes[node.name.lexeme] = _ResolvedClass(node, filePath);

    for (final member in node.members) {
      if (member is FieldDeclaration && member.isStatic) {
        final vars = member.fields;
        if (vars.isConst) {
          for (final variable in vars.variables) {
            final init = variable.initializer;
            if (init is SimpleStringLiteral) {
              constants['${node.name.lexeme}.${variable.name.lexeme}'] =
                  init.value;
            }
          }
        }
      }
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    if (node.variables.isConst) {
      for (final v in node.variables.variables) {
        final init = v.initializer;
        if (init is SimpleStringLiteral) {
          constants[v.name.lexeme] = init.value;
        }
      }
    }
    super.visitTopLevelVariableDeclaration(node);
  }
}

/// Mutable accumulator for the final per-view output.
class _ViewBuilder {
  final Map<String, List<KeyElement>> _elements = {};
  final Map<String, List<KeysRow>> _rows = {};
  // Track keys that are members of a row so we don't double-count them
  // as flat elements.
  final Set<String> _rowMemberLabels = {};

  void addElement(String view, KeyElement element) {
    if (_rowMemberLabels.contains(_membershipKey(view, element.label))) {
      return;
    }
    _elements.putIfAbsent(view, () => []).add(element);
  }

  void addRow(String view, KeysRow row) {
    _rows.putIfAbsent(view, () => []).add(row);
    for (final m in row.members) {
      _rowMemberLabels.add(_membershipKey(view, m.label));
    }
  }

  Map<String, ViewKeys> build() {
    final viewNames = <String>{..._elements.keys, ..._rows.keys};
    final out = <String, ViewKeys>{};
    for (final v in viewNames) {
      // Filter out elements that turned out to be row members (rows may be
      // detected after their members were emitted).
      final keptElements = (_elements[v] ?? const <KeyElement>[]).where((e) {
        return !_rowMemberLabels.contains(_membershipKey(v, e.label));
      }).toList();

      out[v] = ViewKeys(
        rows: _rows[v] ?? const [],
        elements: keptElements,
      );
    }
    return out;
  }

  String _membershipKey(String view, String label) => '$view::$label';
}

/// Pass-2 visitor: walks each file and surfaces ValueKey-bearing widgets
/// into [_ViewBuilder]. Tracks the current `@FlutternautView` value, the
/// stack of `itemBuilder` index parameter names, and recursively dives
/// into custom row widget classes when they're constructed inside a
/// closure.
class _KeyVisitor extends RecursiveAstVisitor<void> {
  final String filePath;
  final _ViewBuilder builder;
  final Map<String, _ResolvedClass> classMap;

  /// View names propagated down the AST. Pushed when entering a class
  /// annotated with `@FlutternautView`; also used to inherit views into
  /// `State<X>` classes.
  String _currentView = '_ungrouped';

  /// View names declared on `StatefulWidget` classes, indexed by class
  /// name. Used to inherit the view onto the matching `State<X>`.
  final Map<String, String> _widgetViews = {};

  /// Stack of iteration-parameter names for currently-active `itemBuilder`
  /// (or similar) closures. Innermost on top.
  final List<String> _indexParamStack = [];

  /// While iterating a closure, members detected at the current depth
  /// accumulate here so we can emit them as a single [KeysRow] when the
  /// closure exits.
  final List<List<_PendingRowMember>> _rowMemberStack = [];

  /// Track which classes we've already walked as a "custom row widget"
  /// so we don't recurse forever on cyclic references.
  final Set<String> _walkedRowClasses = {};

  _KeyVisitor(this.filePath,
      {required this.builder, required this.classMap});

  // ---------------------------------------------------------------------------
  // View tracking
  // ---------------------------------------------------------------------------

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final prevView = _currentView;

    final annotated = _extractViewAnnotation(node);
    if (annotated != null) {
      _currentView = annotated;
      _widgetViews[node.name.lexeme] = annotated;
    } else {
      // Inherit view from a `StatefulWidget`'s `@FlutternautView`
      // annotation onto its `State<X>` class.
      final superclass = node.extendsClause?.superclass;
      if (superclass != null && _namedTypeLexeme(superclass) == 'State') {
        final args = superclass.typeArguments?.arguments;
        if (args != null && args.isNotEmpty) {
          final widgetType = args.first;
          if (widgetType is NamedType) {
            final inherited = _widgetViews[_namedTypeLexeme(widgetType)];
            if (inherited != null) _currentView = inherited;
          }
        }
      }
    }

    super.visitClassDeclaration(node);
    _currentView = prevView;
  }

  String? _extractViewAnnotation(ClassDeclaration node) {
    for (final ann in node.metadata) {
      if (ann.name.name != 'FlutternautView') continue;
      final args = ann.arguments;
      if (args == null || args.arguments.isEmpty) continue;
      final arg = args.arguments.first;
      if (arg is SimpleStringLiteral) return arg.value;
      // Const reference fallback: keep the source text.
      return arg.toSource();
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Closure tracking — for inline-itemBuilder rows
  // ---------------------------------------------------------------------------

  @override
  void visitNamedExpression(NamedExpression node) {
    final name = node.name.label.name;
    if (_indexedBuilderArgs.contains(name)) {
      final closure = node.expression;
      if (closure is FunctionExpression) {
        final indexParam = _extractIndexParam(closure);
        if (indexParam != null) {
          _indexParamStack.add(indexParam);
          _rowMemberStack.add(<_PendingRowMember>[]);
          super.visitNamedExpression(node);
          final pending = _rowMemberStack.removeLast();
          _indexParamStack.removeLast();
          _emitRowFromPending(
            pending,
            rowClass: null,
            file: filePath,
          );
          return;
        }
      }
    }
    super.visitNamedExpression(node);
  }

  /// Extracts the second positional parameter name from a closure that
  /// looks like `IndexedWidgetBuilder` — `(BuildContext context, int index)`.
  String? _extractIndexParam(FunctionExpression closure) {
    final params = closure.parameters?.parameters;
    if (params == null || params.length < 2) return null;
    final indexParam = params[1];
    final name = indexParam.name?.lexeme;
    return name;
  }

  // ---------------------------------------------------------------------------
  // The main detection: a widget construction with `key: ValueKey(...)`.
  //
  // Without `const` or `new`, Dart's parser can't tell whether `Foo(...)` is
  // a constructor call or a top-level function call. Bare `Foo(...)` parses
  // as `MethodInvocation`; only `const Foo(...)` / `new Foo(...)` parse as
  // `InstanceCreationExpression`. We handle both.
  // ---------------------------------------------------------------------------

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final typeName = _namedTypeLexeme(node.constructorName.type);
    _processWidgetConstruction(typeName, node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final typeName = _widgetTypeFromMethodInvocation(node);
    if (typeName != null) {
      _processWidgetConstruction(typeName, node.argumentList);
    }
    super.visitMethodInvocation(node);
  }

  /// Returns the widget-class name if [node] looks like a constructor call
  /// in widget form. `Foo(...)` → `"Foo"`. `Foo.bar(...)` → `"Foo"`.
  /// Returns `null` for ordinary function calls (`print(...)`, `setState(...)`).
  String? _widgetTypeFromMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (target == null) {
      final name = node.methodName.name;
      if (_isClassNameLike(name)) return name;
      return null;
    }
    if (target is SimpleIdentifier && _isClassNameLike(target.name)) {
      return target.name;
    }
    return null;
  }

  bool _isClassNameLike(String name) =>
      name.isNotEmpty && name[0] == name[0].toUpperCase() && name[0] != '_';

  void _processWidgetConstruction(String widgetType, ArgumentList args) {
    final keyArg = _findNamedArg(args, 'key');
    final extracted = keyArg == null ? null : _extractValueKey(keyArg);

    if (extracted != null) {
      final effectiveWidget = _passthroughWrappers.contains(widgetType)
          ? _inferChildWidget(args) ?? widgetType
          : widgetType;
      final effectiveArgs = _passthroughWrappers.contains(widgetType)
          ? _childArgList(args) ?? args
          : args;
      final role = _inferRole(effectiveWidget, effectiveArgs);

      final element = KeyElement(
        label: extracted.label,
        widget: effectiveWidget,
        role: role,
        isDynamic: extracted.isDynamic,
        file: filePath,
      );

      if (extracted.isDynamic &&
          extracted.referencesIndex &&
          _indexParamStack.isNotEmpty) {
        _rowMemberStack.last.add(_PendingRowMember(
          element: element,
          referencesParamName: extracted.referencesParamName!,
        ));
      } else {
        builder.addElement(_currentView, element);
      }
    }

    // Custom-row-widget recursion: inside an active itemBuilder, if this
    // construction has an `index:` argument wired to the active loop's
    // index variable, walk into the widget's class definition.
    if (_indexParamStack.isNotEmpty) {
      _maybeWalkCustomRowWidget(widgetType, args);
    }
  }

  // ---------------------------------------------------------------------------
  // Custom row widget recursion
  // ---------------------------------------------------------------------------

  /// Detects a call like `TodoTile(index: index, ...)` inside an active
  /// itemBuilder closure, finds the matching class, and walks its
  /// `build()` method as if its body were inlined into the closure.
  void _maybeWalkCustomRowWidget(String widgetType, ArgumentList args) {
    if (_walkedRowClasses.contains(widgetType)) return;

    final outerIndexParam = _indexParamStack.last;
    final paramWiredToIndex = _findParamWiredTo(args, outerIndexParam);
    if (paramWiredToIndex == null) return;

    final cls = classMap[widgetType];
    if (cls == null) return;

    _indexParamStack.add(paramWiredToIndex);
    _rowMemberStack.add(<_PendingRowMember>[]);
    _walkedRowClasses.add(widgetType);

    cls.declaration.accept(this);

    _walkedRowClasses.remove(widgetType);
    final pending = _rowMemberStack.removeLast();
    _indexParamStack.removeLast();

    _emitRowFromPending(
      pending,
      rowClass: widgetType,
      file: cls.filePath,
    );
  }

  /// Finds the constructor parameter name in [args] whose value is the
  /// [SimpleIdentifier] [identName].
  ///
  /// E.g. for `TodoTile(index: index, todo: todos[i])` and
  /// [identName] = `'index'` returns `'index'`.
  String? _findParamWiredTo(ArgumentList args, String identName) {
    for (final arg in args.arguments) {
      if (arg is! NamedExpression) continue;
      final expr = arg.expression;
      if (expr is SimpleIdentifier && expr.name == identName) {
        return arg.name.label.name;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Row emission
  // ---------------------------------------------------------------------------

  void _emitRowFromPending(
    List<_PendingRowMember> pending, {
    String? rowClass,
    required String file,
  }) {
    if (pending.isEmpty) return;

    final members = pending.map((p) => p.element).toList(growable: false);

    // Search prefix: first field-role member whose label ends with `_{index}`.
    String? searchPrefix;
    for (final m in members) {
      if (m.role != KeyRole.field) continue;
      const suffix = '_{index}';
      if (m.label.endsWith(suffix)) {
        final candidate = m.label.substring(0, m.label.length - '{index}'.length);
        if (searchPrefix == null || candidate.length < searchPrefix.length) {
          searchPrefix = candidate;
        }
      }
    }

    // Stable name: prefer the rowClass; otherwise derive from search prefix
    // or first member's label root.
    final name = rowClass != null
        ? _snakeCase(rowClass)
        : (searchPrefix != null
            ? '${searchPrefix.replaceAll(RegExp(r'_+$'), '')}_row'
            : '${_stripIndexToken(members.first.label)}_row');

    final row = KeysRow(
      name: name,
      rowClass: rowClass,
      searchPrefix: searchPrefix,
      indexToken: '{index}',
      members: members,
      file: file,
    );

    builder.addRow(_currentView, row);
  }

  String _stripIndexToken(String label) {
    return label
        .replaceAll('{index}', '')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  String _snakeCase(String camel) {
    return camel
        .replaceAllMapped(
          RegExp(r'(?<!^)([A-Z])'),
          (m) => '_${m.group(1)!.toLowerCase()}',
        )
        .toLowerCase();
  }

  // ---------------------------------------------------------------------------
  // ValueKey extraction helpers
  // ---------------------------------------------------------------------------

  Expression? _findNamedArg(ArgumentList args, String name) {
    for (final arg in args.arguments) {
      if (arg is NamedExpression && arg.name.label.name == name) {
        return arg.expression;
      }
    }
    return null;
  }

  /// Decodes a `ValueKey('label')` / `ValueKey('todo_$i')` call site.
  ///
  /// Handles all of:
  /// - `const ValueKey(...)`              → `InstanceCreationExpression`
  /// - `new ValueKey(...)`                → `InstanceCreationExpression`
  /// - `ValueKey(...)`                    → `MethodInvocation` (parser
  ///                                         can't tell w/o resolution)
  /// - `Key('...')`                       → either form
  ///
  /// Returns `null` if [expr] isn't recognisably a key constructor call,
  /// or its argument isn't a string literal / interpolation.
  _ExtractedKey? _extractValueKey(Expression expr) {
    String? typeName;
    ArgumentList? args;

    if (expr is InstanceCreationExpression) {
      typeName = _namedTypeLexeme(expr.constructorName.type);
      args = expr.argumentList;
    } else if (expr is MethodInvocation && expr.target == null) {
      typeName = expr.methodName.name;
      args = expr.argumentList;
    }

    if (typeName != 'ValueKey' && typeName != 'Key') return null;
    if (args == null || args.arguments.isEmpty) return null;

    final firstArg = args.arguments.first;
    if (firstArg is SimpleStringLiteral) {
      return _ExtractedKey(label: firstArg.value, isDynamic: false);
    }
    if (firstArg is StringInterpolation) {
      final rewrite = _rewriteInterpolation(firstArg);
      return _ExtractedKey(
        label: rewrite.label,
        isDynamic: true,
        referencesIndex: rewrite.referencesIndex,
        referencesParamName: rewrite.referencedParamName,
      );
    }
    return null;
  }

  /// Rewrites a `StringInterpolation` into a placeholder pattern, returning
  /// both the rewritten string and the name of the iteration parameter it
  /// references (if any).
  _InterpolationRewrite _rewriteInterpolation(StringInterpolation node) {
    final buffer = StringBuffer();
    String? referencedParam;
    var referencesIndex = false;
    final activeIndexParams = _indexParamStack.toSet();

    for (final element in node.elements) {
      if (element is InterpolationString) {
        buffer.write(element.value);
        continue;
      }
      if (element is InterpolationExpression) {
        final expr = element.expression;
        if (expr is SimpleIdentifier) {
          final name = expr.name;
          if (activeIndexParams.contains(name) ||
              _indexLikeNames.contains(name)) {
            buffer.write('{index}');
            if (activeIndexParams.contains(name)) {
              referencedParam = name;
              referencesIndex = true;
            }
          } else {
            buffer.write('{$name}');
          }
        } else {
          // Complex expression (e.g. ${item.id}) — punt to {index}.
          buffer.write('{index}');
          if (activeIndexParams.isNotEmpty) {
            referencedParam = activeIndexParams.first;
            referencesIndex = true;
          }
        }
      }
    }

    return _InterpolationRewrite(
      label: buffer.toString(),
      referencedParamName: referencedParam,
      referencesIndex: referencesIndex,
    );
  }

  // ---------------------------------------------------------------------------
  // Role inference
  // ---------------------------------------------------------------------------

  KeyRole _inferRole(String widgetType, ArgumentList args) {
    if (_fieldWidgets.contains(widgetType)) return KeyRole.field;
    for (final arg in args.arguments) {
      if (arg is! NamedExpression) continue;
      if (_actionCallbacks.contains(arg.name.label.name)) {
        return KeyRole.action;
      }
    }
    return KeyRole.other;
  }

  /// For pass-through wrappers like `KeyedSubtree`, look at the `child:`
  /// argument and try to infer the wrapped widget's type.
  String? _inferChildWidget(ArgumentList wrapperArgs) {
    final child = _findNamedArg(wrapperArgs, 'child');
    if (child is InstanceCreationExpression) {
      return _namedTypeLexeme(child.constructorName.type);
    }
    if (child is MethodInvocation) {
      return _widgetTypeFromMethodInvocation(child);
    }
    return null;
  }

  /// For pass-through wrappers, return the `child:` widget's argument
  /// list so role inference (`onPressed`, `onTap` etc) sees the real
  /// widget's args instead of the wrapper's.
  ArgumentList? _childArgList(ArgumentList wrapperArgs) {
    final child = _findNamedArg(wrapperArgs, 'child');
    if (child is InstanceCreationExpression) return child.argumentList;
    if (child is MethodInvocation) return child.argumentList;
    return null;
  }
}

class _ExtractedKey {
  final String label;
  final bool isDynamic;
  final bool referencesIndex;
  final String? referencesParamName;
  _ExtractedKey({
    required this.label,
    required this.isDynamic,
    this.referencesIndex = false,
    this.referencesParamName,
  });
}

class _InterpolationRewrite {
  final String label;
  final String? referencedParamName;
  final bool referencesIndex;
  _InterpolationRewrite({
    required this.label,
    required this.referencedParamName,
    required this.referencesIndex,
  });
}

class _PendingRowMember {
  final KeyElement element;
  final String referencesParamName;
  _PendingRowMember({
    required this.element,
    required this.referencesParamName,
  });
}
