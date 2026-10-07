// Measures the package's Dart sources for the structure limits test
// (structure_test.dart). Mirrors the Go engine's engine/structure test: every
// measure is keyed so baseline.json can name it, and a measure over its limit
// fails unless the baseline allows exactly its current value.
//
// Keys name the owning **library** (the file a `part` belongs to), never the
// part file, so moving code between the parts of one library keeps its keys.

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

/// A function, method, getter or constructor: at most this many lines,
/// counted from its first token after the doc comment and annotations.
const maxFunctionLines = 80;

/// A file under `lib/` or `bin/`.
const maxFileLines = 800;

/// A class, mixin, enum, extension or extension type.
const maxTypeLines = 500;

/// A library: its file plus all of its parts.
const maxLibraryLines = 5000;

/// Distinct libraries of this package one library imports.
const maxInternalImports = 10;

/// The environment variable that rewrites baseline.json from the current
/// measures instead of checking them.
const updateEnv = 'UPDATE_STRUCTURE_BASELINE';

/// The baseline file, relative to the package root.
const baselinePath = 'test/structure/baseline.json';

/// The command that rewrites the baseline, as failure messages name it.
const updateCommand = '$updateEnv=1 flutter test test/structure';

const _packageName = 'flutternaut';

/// The bridge's layers, by the components of `lib/src/bridge/`: a component
/// must never import the ones listed for it. `router` holds the request and
/// route primitives the handlers register on, so it imports only models;
/// `server` wires everything together and nothing imports it.
const forbiddenImports = <String, List<String>>{
  'models': ['engine', 'router', 'handlers', 'server'],
  'engine': ['router', 'handlers', 'server'],
  'router': ['engine', 'handlers', 'server'],
  'handlers': ['server'],
};

const _hintFunction = 'Split it into named phase helpers with early returns.';
const _hintFile = 'Split the file by concern (a part file per concern keeps '
    'one library, see lib/src/bridge/engine/tree_walker/).';
const _hintType = 'Split the type by concern (extensions in part files, '
    'or collaborators of its own).';
const _hintLibrary = 'A library owns one concern: split it into libraries.';
const _hintImports = 'Too many internal imports: narrow it behind an '
    'interface or split it.';
const _hintGlobal = 'No new global mutable state: pass it in, or hold it in '
    'an instance.';

/// One thing the test counts, with its limit and what to do when it is over.
class Measure {
  /// Creates a measure.
  const Measure(this.value, this.limit, this.hint);

  /// What was counted.
  final int value;

  /// The largest allowed [value].
  final int limit;

  /// How to bring an offender within its limit.
  final String hint;

  /// Whether [value] is over [limit].
  bool get over => value > limit;
}

/// Measures every `.dart` file under `lib/` and `bin/` of the package at
/// [packageRoot].
Map<String, Measure> collectDirectory(String packageRoot) {
  final sources = <String, String>{};
  for (final top in const ['lib', 'bin']) {
    final dir = Directory('$packageRoot/$top');
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = entity.path.substring(packageRoot.length + 1);
      sources[rel.replaceAll(r'\', '/')] = entity.readAsStringSync();
    }
  }
  if (sources.isEmpty) {
    throw StateError('no Dart sources under $packageRoot/lib or /bin');
  }
  return collectSources(sources);
}

/// Measures [sources]: package-relative POSIX path (`lib/src/a.dart`) to
/// file content.
Map<String, Measure> collectSources(Map<String, String> sources) {
  final files = <String, _ParsedFile>{
    for (final e in sources.entries) e.key: _parse(e.key, e.value),
  };

  // The library each file belongs to: itself, or the file its `part of`
  // names.
  final libraryOf = <String, String>{};
  for (final f in files.values) {
    final partOf = f.partOf;
    if (partOf == null) {
      libraryOf[f.path] = f.path;
      continue;
    }
    if (!files.containsKey(partOf)) {
      throw StateError('${f.path} is `part of` $partOf, which is not a '
          'scanned file');
    }
    libraryOf[f.path] = partOf;
  }

  final out = <String, Measure>{};
  final libraryLines = <String, int>{};
  final libraryImports = <String, Set<String>>{};
  final componentImports = <String, Set<String>>{};

  for (final f in files.values) {
    final lib = libraryOf[f.path]!;
    out['file:${f.path}'] = Measure(f.lines, maxFileLines, _hintFile);
    libraryLines[lib] = (libraryLines[lib] ?? 0) + f.lines;

    final imports = libraryImports.putIfAbsent(lib, () => <String>{});
    final from = componentOf(f.path);
    for (final target in f.imports) {
      if (target != lib) imports.add(target);
      final to = componentOf(target);
      if (from != null && to != null && to != from) {
        componentImports.putIfAbsent(from, () => <String>{}).add(to);
      }
    }

    for (final d in f.declarations) {
      final key = '${d.kind}:$lib.${d.name}';
      switch (d.kind) {
        case 'func':
          final prev = out[key];
          if (prev == null || d.lines > prev.value) {
            out[key] = Measure(d.lines, maxFunctionLines, _hintFunction);
          }
        case 'type':
          out[key] = Measure(d.lines, maxTypeLines, _hintType);
        case 'global':
          out[key] = const Measure(1, 0, _hintGlobal);
        default:
          throw StateError('unknown declaration kind ${d.kind}');
      }
    }
  }

  for (final lib in libraryLines.keys) {
    out['lib-loc:$lib'] =
        Measure(libraryLines[lib]!, maxLibraryLines, _hintLibrary);
    out['lib-imports:$lib'] = Measure(
      libraryImports[lib]?.length ?? 0,
      maxInternalImports,
      _hintImports,
    );
  }
  for (final from in forbiddenImports.keys) {
    for (final to in forbiddenImports[from]!) {
      final value = (componentImports[from]?.contains(to) ?? false) ? 1 : 0;
      out['import:$from->$to'] = Measure(
        value,
        0,
        '$from must not import $to (layers: models <- engine <- handlers '
        '<- server; router imports only models).',
      );
    }
  }
  return out;
}

/// The bridge component a package path belongs to (`models`, `engine`,
/// `handlers`, `router`, `server`), or null outside them.
String? componentOf(String path) {
  const bridge = 'lib/src/bridge/';
  if (!path.startsWith(bridge)) return null;
  final rest = path.substring(bridge.length);
  for (final dir in const ['models', 'engine', 'handlers']) {
    if (rest.startsWith('$dir/')) return dir;
  }
  if (rest == 'router.dart') return 'router';
  if (rest == 'server.dart') return 'server';
  return null;
}

/// The problems of [got] against [baseline] — empty when the package is
/// within its limits. Identical rules to engine/structure/structure_test.go:
/// a new offender, one that grew, one that shrank while its baseline entry
/// stayed, and a baseline entry for something now within its limit or gone.
List<String> ratchet(Map<String, Measure> got, Map<String, int> baseline) {
  final problems = <String>[];
  for (final key in got.keys.toList()..sort()) {
    final m = got[key]!;
    if (!m.over) continue;
    final allowed = baseline[key];
    if (allowed == null) {
      problems.add('$key = ${m.value}, limit ${m.limit}. ${m.hint}');
    } else if (m.value > allowed) {
      problems.add('$key grew to ${m.value} (baseline $allowed, limit '
          '${m.limit}). ${m.hint}');
    } else if (m.value < allowed) {
      problems.add('$key shrank to ${m.value} (baseline $allowed, limit '
          '${m.limit}): lower it with $updateCommand');
    }
  }
  for (final key in baseline.keys.toList()..sort()) {
    final m = got[key];
    if (m == null || !m.over) {
      problems.add('$key is within its limit or gone but still in '
          '$baselinePath: remove it with $updateCommand');
    }
  }
  return problems;
}

/// The baseline [got] calls for: every measure over its limit, at its
/// current value.
Map<String, int> baselineOf(Map<String, Measure> got) => {
      for (final e in got.entries)
        if (e.value.over) e.key: e.value.value,
    };

/// [baseline] as baseline.json stores it: keys sorted, two-space indent,
/// trailing newline.
String encodeBaseline(Map<String, int> baseline) {
  final sorted = {
    for (final key in baseline.keys.toList()..sort()) key: baseline[key],
  };
  return '${const JsonEncoder.withIndent('  ').convert(sorted)}\n';
}

/// Parses baseline.json [raw]: an object of measure key to allowed value.
Map<String, int> decodeBaseline(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('baseline must be a JSON object');
  }
  return {
    for (final e in decoded.entries)
      e.key: e.value is int
          ? e.value as int
          : throw FormatException('baseline ${e.key} is not an integer'),
  };
}

class _Declaration {
  const _Declaration(this.kind, this.name, this.lines);

  /// `func`, `type` or `global`.
  final String kind;

  /// `name`, or `Type.name` for a member.
  final String name;
  final int lines;
}

class _ParsedFile {
  _ParsedFile(this.path, this.lines, this.partOf);

  final String path;
  final int lines;

  /// The package path of the library this part belongs to; null for a
  /// library file.
  final String? partOf;

  /// Package paths of the files of this package it imports.
  final List<String> imports = [];
  final List<_Declaration> declarations = [];
}

_ParsedFile _parse(String path, String content) {
  final CompilationUnit unit;
  final LineInfo lineInfo;
  try {
    final result = parseString(content: content, path: path);
    unit = result.unit;
    lineInfo = result.lineInfo;
  } on ArgumentError catch (e) {
    throw StateError('parse $path: ${e.message}');
  }

  String? partOf;
  final imports = <String>[];
  for (final directive in unit.directives) {
    if (directive is PartOfDirective) {
      final uri = directive.uri?.stringValue;
      if (uri == null) {
        throw StateError('$path: `part of` a library name is not supported; '
            'name the library file instead');
      }
      partOf = _resolve(path, uri);
      if (partOf == null) {
        throw StateError('$path: `part of $uri` is outside this package');
      }
    } else if (directive is ImportDirective) {
      final uri = directive.uri.stringValue;
      if (uri == null) {
        throw StateError('$path: an import with an interpolated URI');
      }
      final target = _resolve(path, uri);
      if (target != null) imports.add(target);
    }
  }

  final file = _ParsedFile(path, _lineCount(content), partOf)
    ..imports.addAll(imports);
  int span(AstNode node, Token first) =>
      lineInfo.getLocation(node.end - 1).lineNumber -
      lineInfo.getLocation(first.offset).lineNumber +
      1;

  for (final d in unit.declarations) {
    switch (d) {
      case FunctionDeclaration():
        if (d.functionExpression.body is EmptyFunctionBody) continue;
        file.declarations.add(_Declaration(
          'func',
          _accessorName(d.name.lexeme, isSetter: d.isSetter),
          span(d, d.firstTokenAfterCommentAndMetadata),
        ));
      case TopLevelVariableDeclaration():
        final list = d.variables;
        if (list.isConst || list.isFinal) continue;
        for (final v in list.variables) {
          file.declarations.add(_Declaration('global', v.name.lexeme, 1));
        }
      default:
        final type = _typeName(d);
        if (type == null) continue;
        file.declarations.add(_Declaration(
          'type',
          type,
          span(d, d.firstTokenAfterCommentAndMetadata),
        ));
        d.accept(_MemberVisitor(type, file.declarations, span));
    }
  }
  return file;
}

/// The name of a type declaration; null for a declaration that is not one
/// (a typedef, a mixin application) and has no members to measure.
String? _typeName(CompilationUnitMember d) => switch (d) {
      ClassDeclaration() => d.namePart.typeName.lexeme,
      MixinDeclaration() => d.name.lexeme,
      EnumDeclaration() => d.namePart.typeName.lexeme,
      ExtensionDeclaration() => d.name?.lexeme ?? '<unnamed extension>',
      ExtensionTypeDeclaration() => d.primaryConstructor.typeName.lexeme,
      _ => null,
    };

String _accessorName(String name, {required bool isSetter}) =>
    isSetter ? '$name=' : name;

/// Records the members of one type declaration: methods, getters, setters
/// and constructors as `func`, mutable static fields as `global`. Does not
/// descend into member bodies: local functions belong to their member.
class _MemberVisitor extends RecursiveAstVisitor<void> {
  _MemberVisitor(this.type, this.sink, this.span);

  final String type;
  final List<_Declaration> sink;
  final int Function(AstNode node, Token first) span;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.body is EmptyFunctionBody) return;
    sink.add(_Declaration(
      'func',
      '$type.${_accessorName(node.name.lexeme, isSetter: node.isSetter)}',
      span(node, node.firstTokenAfterCommentAndMetadata),
    ));
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    sink.add(_Declaration(
      'func',
      '$type.${node.name?.lexeme ?? 'new'}',
      span(node, node.firstTokenAfterCommentAndMetadata),
    ));
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    final list = node.fields;
    if (!node.isStatic || list.isConst || list.isFinal) return;
    for (final v in list.variables) {
      sink.add(_Declaration('global', '$type.${v.name.lexeme}', 1));
    }
  }
}

/// Lines in [content], as `wc -l` counts them (a last line without a
/// newline still counts).
int _lineCount(String content) {
  if (content.isEmpty) return 0;
  final newlines = '\n'.allMatches(content).length;
  return content.endsWith('\n') ? newlines : newlines + 1;
}

/// The package path [uri] (imported from the file at [from]) points to, or
/// null when it is outside this package (`dart:`, another package).
String? _resolve(String from, String uri) {
  if (uri.startsWith('package:')) {
    const own = 'package:$_packageName/';
    return uri.startsWith(own) ? 'lib/${uri.substring(own.length)}' : null;
  }
  if (uri.contains(':')) return null;
  final segments = from.split('/')..removeLast();
  for (final part in uri.split('/')) {
    if (part == '..') {
      if (segments.isEmpty) return null;
      segments.removeLast();
    } else if (part != '.' && part.isNotEmpty) {
      segments.add(part);
    }
  }
  return segments.join('/');
}
