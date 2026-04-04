import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// Scans Dart source files for Flutternaut widget usages and extracts
/// structured element metadata.
class FlutternautAnalyzer {
  /// Scans all `.dart` files under `lib/` and returns all elements found.
  ///
  /// [rootPath] is the project root, used to compute relative file paths.
  List<FlutternautElement> scanDirectory(String rootPath) {
    final libDir = Directory(p.join(rootPath, 'lib'));
    if (!libDir.existsSync()) return [];

    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    // Pass 1: Parse all files and collect static const string declarations.
    final constMap = <String, String>{};
    final parsedFiles = <File, CompilationUnit>{};
    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      final result = parseString(content: source, throwIfDiagnostics: false);
      parsedFiles[file] = result.unit;
      final collector = _ConstStringCollector();
      result.unit.accept(collector);
      constMap.addAll(collector.constants);
    }

    // Pass 2: Analyze with const resolution.
    final elements = <FlutternautElement>[];
    for (final file in dartFiles) {
      final relativePath = p.relative(file.path, from: rootPath);
      final visitor = _FlutternautVisitor(relativePath, constMap: constMap);
      parsedFiles[file]!.accept(visitor);
      elements.addAll(visitor.elements);
    }

    return elements;
  }

  /// Analyzes a single Dart source string and returns any elements found.
  ///
  /// [filePath] is stored on each element for traceability.
  /// [constMap] provides pre-collected const string values for resolving
  /// non-literal annotation arguments (e.g. `AppRoutes.trip` → `'/tripView'`).
  List<FlutternautElement> analyzeSource(String source, String filePath,
      {Map<String, String> constMap = const {}}) {
    final result = parseString(content: source, throwIfDiagnostics: false);
    final visitor = _FlutternautVisitor(filePath, constMap: constMap);
    result.unit.accept(visitor);
    return visitor.elements;
  }
}

/// Returns the name of a [NamedType] as a String, compatible across
/// analyzer 6.x through 9.x+.
///
/// analyzer <8: `name2` (Token), >=8: `name` (Token).
String _namedTypeLexeme(NamedType type) {
  try {
    // ignore: deprecated_member_use
    return (type as dynamic).name2.lexeme as String;
  } catch (_) {
    return (type as dynamic).name.lexeme as String;
  }
}

/// Collects static const String fields and top-level const strings.
///
/// Result map keys use `"ClassName.fieldName"` for class members and
/// bare `"variableName"` for top-level declarations.
class _ConstStringCollector extends RecursiveAstVisitor<void> {
  final Map<String, String> constants = {};

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final className = node.name.lexeme;
    for (final member in node.members) {
      if (member is FieldDeclaration && member.isStatic) {
        final vars = member.fields;
        if (vars.isConst) {
          for (final variable in vars.variables) {
            final init = variable.initializer;
            if (init is SimpleStringLiteral) {
              constants['$className.${variable.name.lexeme}'] = init.value;
            }
          }
        }
      }
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    final vars = node.variables;
    if (vars.isConst) {
      for (final variable in vars.variables) {
        final init = variable.initializer;
        if (init is SimpleStringLiteral) {
          constants[variable.name.lexeme] = init.value;
        }
      }
    }
    super.visitTopLevelVariableDeclaration(node);
  }
}

class _FlutternautVisitor extends RecursiveAstVisitor<void> {
  final String filePath;
  final Map<String, String> constMap;
  final List<FlutternautElement> elements = [];
  String? _currentView;

  /// Maps StatefulWidget class names to their @FlutternautView value.
  /// Populated on first visit so State<X> classes can inherit the view.
  final Map<String, String> _widgetViews = {};

  _FlutternautVisitor(this.filePath, {this.constMap = const {}});

  /// Extracts the @FlutternautView annotation value from a class, if present.
  String? _extractViewAnnotation(ClassDeclaration node) {
    for (final annotation in node.metadata) {
      final name = annotation.name.name;
      if (name == 'FlutternautView') {
        final args = annotation.arguments;
        if (args != null && args.arguments.isNotEmpty) {
          final arg = args.arguments.first;
          if (arg is SimpleStringLiteral) {
            return arg.value;
          }
          // Try resolving const reference via the collected map.
          final source = arg.toSource();
          if (constMap.containsKey(source)) {
            return constMap[source];
          }
          // Fallback: use source text as-is.
          return source;
        }
      }
    }
    return null;
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final prevView = _currentView;

    // Check for @FlutternautView on this class.
    final annotatedView = _extractViewAnnotation(node);
    if (annotatedView != null) {
      _currentView = annotatedView;
      // Store so State<ClassName> can inherit it.
      _widgetViews[node.name.lexeme] = annotatedView;
    }

    // If this is a State<X> class, inherit the view from the StatefulWidget X.
    if (_currentView == null) {
      final superclass = node.extendsClause?.superclass;
      if (superclass != null) {
        final superName = _namedTypeLexeme(superclass);
        if (superName == 'State') {
          final typeArgs = superclass.typeArguments?.arguments;
          if (typeArgs != null && typeArgs.isNotEmpty) {
            final widgetType = typeArgs.first;
            if (widgetType is NamedType) {
              final widgetName = _namedTypeLexeme(widgetType);
              final inherited = _widgetViews[widgetName];
              if (inherited != null) {
                _currentView = inherited;
              }
            }
          }
        }
      }
    }

    super.visitClassDeclaration(node);
    _currentView = prevView;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    String? type;

    if (node.target == null && node.methodName.name == 'Flutternaut') {
      // Flutternaut(...) — default constructor (parsed as function call)
      type = 'element';
    } else if (node.target is SimpleIdentifier &&
        (node.target as SimpleIdentifier).name == 'Flutternaut') {
      // Flutternaut.button(...) — named constructor (parsed as method call)
      type = node.methodName.name;
    }

    if (type != null) {
      _extractElement(type, node.argumentList);
    }

    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    // Handles `const Flutternaut(...)` and `new Flutternaut(...)`
    final constructorName = node.constructorName;
    final typeName = _namedTypeLexeme(constructorName.type);
    final prefix = constructorName.type.importPrefix?.name.lexeme;

    if (typeName == 'Flutternaut') {
      // `const Flutternaut(...)` — default constructor
      final namedConstructor = constructorName.name?.name;
      final type = namedConstructor ?? 'element';
      _extractElement(type, node.argumentList);
    } else if (prefix == 'Flutternaut') {
      // `const Flutternaut.button(...)` — parser treats as prefix.type
      _extractElement(typeName, node.argumentList);
    }

    super.visitInstanceCreationExpression(node);
  }

  void _extractElement(String type, ArgumentList argumentList) {
    String? label;
    String? description;
    var isDynamic = false;

    for (final argument in argumentList.arguments) {
      if (argument is! NamedExpression) continue;

      final paramName = argument.name.label.name;

      if (paramName == 'label') {
        final expr = argument.expression;
        if (expr is SimpleStringLiteral) {
          label = expr.value;
        } else if (expr is StringInterpolation) {
          isDynamic = true;
          label = _rewriteInterpolation(expr);
        }
      } else if (paramName == 'description') {
        final expr = argument.expression;
        if (expr is SimpleStringLiteral) {
          description = expr.value;
        }
      }
    }

    if (label == null) return;

    elements.add(FlutternautElement(
      label: label,
      type: type,
      description: description,
      isDynamic: isDynamic,
      view: _currentView,
      file: filePath,
    ));
  }

  /// Rewrites a `StringInterpolation` into a placeholder pattern.
  ///
  /// e.g. `"todo_$index"` → `"todo_{index}"`
  ///      `"item_${name}_btn"` → `"item_{name}_btn"`
  String _rewriteInterpolation(StringInterpolation node) {
    final buffer = StringBuffer();

    for (final element in node.elements) {
      if (element is InterpolationString) {
        buffer.write(element.value);
      } else if (element is InterpolationExpression) {
        final expr = element.expression;
        if (expr is SimpleIdentifier) {
          final name = expr.name;
          if (_isIndexLike(name)) {
            buffer.write('{index}');
          } else {
            buffer.write('{$name}');
          }
        } else {
          // Complex expressions like ${items.length} → {index}
          buffer.write('{index}');
        }
      }
    }

    return buffer.toString();
  }

  bool _isIndexLike(String name) {
    const indexNames = {'index', 'i', 'n', 'idx', 'position', 'pos'};
    return indexNames.contains(name);
  }
}
