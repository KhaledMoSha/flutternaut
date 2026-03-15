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

    final elements = <FlutternautElement>[];
    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in dartFiles) {
      final relativePath = p.relative(file.path, from: rootPath);
      final source = file.readAsStringSync();
      elements.addAll(analyzeSource(source, relativePath));
    }

    return elements;
  }

  /// Analyzes a single Dart source string and returns any elements found.
  ///
  /// [filePath] is stored on each element for traceability.
  List<FlutternautElement> analyzeSource(String source, String filePath) {
    final result = parseString(content: source, throwIfDiagnostics: false);
    final visitor = _FlutternautVisitor(filePath);
    result.unit.accept(visitor);
    return visitor.elements;
  }
}

class _FlutternautVisitor extends RecursiveAstVisitor<void> {
  final String filePath;
  final List<FlutternautElement> elements = [];

  _FlutternautVisitor(this.filePath);

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
    final typeName = constructorName.type.name.lexeme;
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
      file: filePath,
    ));
  }

  /// Rewrites a `StringInterpolation` into a placeholder pattern.
  ///
  /// e.g. `"todo_$index"` → `"todo_{n}"`
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
            buffer.write('{n}');
          } else {
            buffer.write('{$name}');
          }
        } else {
          // Complex expressions like ${items.length} → {n}
          buffer.write('{n}');
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
