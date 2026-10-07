// The package's size and layering limits (README.md → Development; the
// Flutternaut-AI agent guide, CLAUDE.md hard rule 13). Every .dart file under
// lib/ and bin/ is parsed and measured (scanner.dart). Offenders that already
// existed when the rule was introduced are listed in baseline.json and may
// only shrink: a baselined item that grows fails, and so does one that has
// shrunk or been fixed while its baseline entry stays — lower it with
// UPDATE_STRUCTURE_BASELINE=1 flutter test test/structure.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'scanner.dart';

void main() {
  test('structure limits', () {
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync() ||
        !RegExp(r'^name: flutternaut$', multiLine: true)
            .hasMatch(pubspec.readAsStringSync())) {
      fail('run from the flutternaut package directory (it reads lib/, bin/ '
          'and $baselinePath relative to it); cwd is ${Directory.current}');
    }
    final got = collectDirectory(Directory.current.path);
    final baseline = File(baselinePath);

    if (Platform.environment[updateEnv] == '1') {
      baseline.writeAsStringSync(encodeBaseline(baselineOf(got)));
      markTestSkipped('$baselinePath rewritten');
      return;
    }

    final problems = ratchet(got, decodeBaseline(baseline.readAsStringSync()));
    if (problems.isNotEmpty) {
      fail('structure limits (README.md → Development) violated:\n  '
          '${problems.join('\n  ')}');
    }
  });

  group('scanner', () {
    String fn(int lines, {String name = 'f'}) =>
        'void $name() {\n${'  0;\n' * (lines - 2)}}\n';

    test('a function of 80 lines is within its limit; 81 lines is over', () {
      final at = collectSources({'lib/a.dart': fn(80)})['func:lib/a.dart.f']!;
      expect((at.value, at.over), (80, false));
      final got = collectSources({'lib/a.dart': fn(81)});
      expect(ratchet(got, const {}), [
        'func:lib/a.dart.f = 81, limit 80. '
            'Split it into named phase helpers with early returns.',
      ]);
    });

    test('the doc comment and annotations are not counted', () {
      final src = "${'/// Docs.\n' * 5}@pragma('vm:prefer-inline')\n${fn(80)}";
      expect(
          collectSources({'lib/a.dart': src})['func:lib/a.dart.f']!.value, 80);
    });

    test('a multi-line arrow body counts to its semicolon', () {
      const src = 'int f() =>\n    1 +\n    2 +\n    3;\n';
      expect(
          collectSources({'lib/a.dart': src})['func:lib/a.dart.f']!.value, 4);
    });

    test('members are keyed by their type; local functions are not', () {
      const src = 'class C {\n'
          '  C();\n'
          '  int get g => 1;\n'
          '  set g(int v) {}\n'
          '  void m() {\n'
          '    void local() {}\n'
          '    local();\n'
          '  }\n'
          '}\n';
      final got = collectSources({'lib/a.dart': src});
      expect(got['func:lib/a.dart.C.new']!.value, 1);
      expect(got['func:lib/a.dart.C.g']!.value, 1);
      expect(got['func:lib/a.dart.C.g=']!.value, 1);
      expect(got['func:lib/a.dart.C.m']!.value, 4);
      expect(got['type:lib/a.dart.C']!.value, 9);
      expect(got.keys.where((k) => k.contains('local')), isEmpty);
    });

    test('a part is measured as part of its library', () {
      final got = collectSources({
        'lib/a.dart': "part 'a/b.dart';\n\nclass A {}\n",
        'lib/a/b.dart': "part of '../a.dart';\n\n"
            'extension E on A {\n  void m() {\n    0;\n  }\n}\n',
      });
      expect(got['func:lib/a.dart.E.m']!.value, 3);
      expect(got['type:lib/a.dart.E']!.value, 5);
      expect(got['file:lib/a/b.dart']!.value, 7);
      expect(got['lib-loc:lib/a.dart']!.value, 3 + 7);
      expect(got.keys.where((k) => k.contains('lib/a/b.dart.')), isEmpty);
      expect(got.containsKey('lib-loc:lib/a/b.dart'), isFalse);
    });

    test('an upward import is flagged, relative or by package URI', () {
      final got = collectSources({
        'lib/src/bridge/engine/x.dart': "import '../handlers/y.dart';\n",
        'lib/src/bridge/handlers/y.dart': "import '../router.dart';\n",
        'lib/src/bridge/router.dart': 'class R {}\n',
        'lib/src/bridge/models/m.dart':
            "import 'package:flutternaut/src/bridge/engine/x.dart';\n",
      });
      expect(got['import:engine->handlers']!.value, 1);
      expect(got['import:models->engine']!.value, 1);
      expect(got['import:handlers->server']!.value, 0);
      expect(got['import:engine->router']!.value, 0);
      expect(ratchet(got, const {}), hasLength(2));
    });

    test('internal imports are counted per library, external ones are not', () {
      final got = collectSources({
        'lib/a.dart': "import 'dart:io';\n"
            "import 'package:flutter/widgets.dart';\n"
            "import 'b.dart';\n"
            "import 'package:flutternaut/c.dart';\n",
        'lib/b.dart': '',
        'lib/c.dart': '',
      });
      expect(got['lib-imports:lib/a.dart']!.value, 2);
    });

    test('global mutable state is flagged; final and const are not', () {
      const src = 'var a = 1;\n'
          'final b = 2;\n'
          'const c = 3;\n'
          'class K {\n'
          '  static int d = 0;\n'
          '  static final e = 0;\n'
          '  int f = 0;\n'
          '}\n';
      final globals = collectSources({'lib/g.dart': src})
          .keys
          .where((k) => k.startsWith('global:'))
          .toList()
        ..sort();
      expect(globals, ['global:lib/g.dart.K.d', 'global:lib/g.dart.a']);
    });

    test('a part of a file that is not scanned fails loudly', () {
      expect(
        () => collectSources({'lib/p.dart': "part of 'missing.dart';\n"}),
        throwsA(isA<StateError>()),
      );
    });

    group('ratchet', () {
      const hint = 'Do it.';
      Map<String, Measure> one(int value) => {'k': Measure(value, 80, hint)};

      test('a new offender fails', () {
        expect(ratchet(one(81), const {}), ['k = 81, limit 80. Do it.']);
      });

      test('an offender that grew fails', () {
        expect(ratchet(one(83), const {'k': 82}),
            ['k grew to 83 (baseline 82, limit 80). Do it.']);
      });

      test('an offender that shrank fails until the baseline is lowered', () {
        expect(ratchet(one(81), const {'k': 82}), [
          'k shrank to 81 (baseline 82, limit 80): lower it with '
              'UPDATE_STRUCTURE_BASELINE=1 flutter test test/structure',
        ]);
      });

      test('a baseline entry for a fixed or removed item fails', () {
        const stale = 'k is within its limit or gone but still in '
            'test/structure/baseline.json: remove it with '
            'UPDATE_STRUCTURE_BASELINE=1 flutter test test/structure';
        expect(ratchet(one(80), const {'k': 82}), [stale]);
        expect(ratchet(const {}, const {'k': 82}), [stale]);
      });

      test('an offender at exactly its baseline passes', () {
        expect(ratchet(one(82), const {'k': 82}), isEmpty);
      });

      test('the baseline round-trips, sorted, over-limit entries only', () {
        final got = {
          'z': const Measure(90, 80, hint),
          'a': const Measure(81, 80, hint),
          'm': const Measure(80, 80, hint),
        };
        final encoded = encodeBaseline(baselineOf(got));
        expect(encoded, '{\n  "a": 81,\n  "z": 90\n}\n');
        expect(decodeBaseline(encoded), {'a': 81, 'z': 90});
      });
    });
  });
}
