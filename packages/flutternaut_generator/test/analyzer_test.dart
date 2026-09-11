import 'dart:io';

import 'package:flutternaut_generator/src/analyzer.dart';
import 'package:flutternaut_generator/src/models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Writes [files] (relative path → source) into a fresh temp directory
/// laid out as a Flutter-ish project (everything under `lib/`) and runs
/// [FlutternautAnalyzer.scanDirectory] on it.
Map<String, ViewKeys> _scan(Map<String, String> files) {
  final tmp = Directory.systemTemp.createTempSync('flutternaut_test_');
  try {
    for (final entry in files.entries) {
      final path = p.join(tmp.path, 'lib', entry.key);
      Directory(p.dirname(path)).createSync(recursive: true);
      File(path).writeAsStringSync(entry.value);
    }
    return FlutternautAnalyzer().scanDirectory(tmp.path);
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

void main() {
  group('basic key extraction', () {
    test('detects ValueKey on a bare widget call (no const)', () {
      final views = _scan({
        'screen.dart': '''
          import 'package:flutter/material.dart';
          import 'package:flutternaut/flutternaut.dart';

          @FlutternautView('Login')
          class LoginScreen extends StatelessWidget {
            @override
            Widget build(BuildContext context) {
              return ElevatedButton(
                key: const ValueKey('login_button'),
                onPressed: () {},
                child: const Text('Login'),
              );
            }
          }
        ''',
      });

      expect(views.keys, contains('Login'));
      final el = views['Login']!.elements
          .firstWhere((e) => e.label == 'login_button');
      expect(el.widget, 'ElevatedButton');
      expect(el.role, KeyRole.action);
      expect(el.isDynamic, isFalse);
    });

    test('detects ValueKey on a const-prefixed widget call', () {
      final views = _scan({
        'screen.dart': '''
          import 'package:flutter/material.dart';
          import 'package:flutternaut/flutternaut.dart';

          @FlutternautView('Home')
          class HomeScreen extends StatelessWidget {
            @override
            Widget build(BuildContext context) {
              return const Text('hello', key: ValueKey('greeting'));
            }
          }
        ''',
      });

      final el = views['Home']!.elements
          .firstWhere((e) => e.label == 'greeting');
      expect(el.widget, 'Text');
      expect(el.role, KeyRole.field);
    });

    test('KeyedSubtree wrapper inherits its child widget type', () {
      final views = _scan({
        'screen.dart': '''
          import 'package:flutter/material.dart';
          import 'package:flutternaut/flutternaut.dart';

          @FlutternautView('Login')
          class LoginScreen extends StatelessWidget {
            @override
            Widget build(BuildContext context) {
              return KeyedSubtree(
                key: const ValueKey('error_text'),
                child: Text('boom'),
              );
            }
          }
        ''',
      });

      final el = views['Login']!.elements
          .firstWhere((e) => e.label == 'error_text');
      expect(el.widget, 'Text', reason: 'KeyedSubtree should pass through');
      expect(el.role, KeyRole.field);
    });

    test('keys outside any @FlutternautView land in _ungrouped', () {
      final views = _scan({
        'utils.dart': '''
          import 'package:flutter/material.dart';

          Widget banner() {
            return ElevatedButton(
              key: const ValueKey('global_button'),
              onPressed: () {},
              child: const Text('Tap'),
            );
          }
        ''',
      });

      expect(views.keys, contains('_ungrouped'));
      expect(
        views['_ungrouped']!.elements.map((e) => e.label),
        contains('global_button'),
      );
    });
  });

  group('view inheritance', () {
    test('State<X> inherits @FlutternautView from its widget', () {
      final views = _scan({
        'screen.dart': '''
          import 'package:flutter/material.dart';
          import 'package:flutternaut/flutternaut.dart';

          @FlutternautView('Login')
          class LoginScreen extends StatefulWidget {
            @override
            State<LoginScreen> createState() => _LoginScreenState();
          }

          class _LoginScreenState extends State<LoginScreen> {
            @override
            Widget build(BuildContext context) {
              return TextField(key: const ValueKey('email_input'));
            }
          }
        ''',
      });

      expect(views['Login']!.elements.map((e) => e.label),
          contains('email_input'));
    });
  });

  group('inline itemBuilder rows', () {
    test('groups dynamic keys inside a ListView.builder closure', () {
      final views = _scan({
        'home.dart': '''
          import 'package:flutter/material.dart';
          import 'package:flutternaut/flutternaut.dart';

          @FlutternautView('Home')
          class HomeScreen extends StatelessWidget {
            final todos = const ['a', 'b'];
            @override
            Widget build(BuildContext context) {
              return ListView.builder(
                itemCount: todos.length,
                itemBuilder: (context, index) => ListTile(
                  leading: Checkbox(
                    key: ValueKey('check_\$index'),
                    value: false,
                    onChanged: (_) {},
                  ),
                  title: Text(
                    todos[index],
                    key: ValueKey('todo_text_\$index'),
                  ),
                  trailing: IconButton(
                    key: ValueKey('delete_\$index'),
                    icon: const Icon(Icons.delete),
                    onPressed: () {},
                  ),
                ),
              );
            }
          }
        ''',
      });

      expect(views['Home']!.rows, hasLength(1));
      final row = views['Home']!.rows.first;
      expect(row.searchPrefix, 'todo_text_');
      expect(row.members.map((m) => m.label), [
        'check_{index}',
        'todo_text_{index}',
        'delete_{index}',
      ]);
      // Row members are not duplicated in flat elements.
      expect(views['Home']!.elements.map((e) => e.label),
          isNot(contains('todo_text_{index}')));
    });

    test('normalises index variable name (idx) to {index}', () {
      final views = _scan({
        'home.dart': '''
          import 'package:flutter/material.dart';
          import 'package:flutternaut/flutternaut.dart';

          @FlutternautView('Home')
          class HomeScreen extends StatelessWidget {
            @override
            Widget build(BuildContext context) {
              return ListView.builder(
                itemBuilder: (context, idx) => Text(
                  'x',
                  key: ValueKey('row_text_\$idx'),
                ),
              );
            }
          }
        ''',
      });

      final row = views['Home']!.rows.first;
      expect(row.members.first.label, 'row_text_{index}');
      expect(row.searchPrefix, 'row_text_');
    });

    test('action-only row has no search_prefix', () {
      final views = _scan({
        'home.dart': '''
          import 'package:flutter/material.dart';
          import 'package:flutternaut/flutternaut.dart';

          @FlutternautView('Home')
          class HomeScreen extends StatelessWidget {
            @override
            Widget build(BuildContext context) {
              return ListView.builder(
                itemBuilder: (context, index) => IconButton(
                  key: ValueKey('delete_\$index'),
                  icon: const Icon(Icons.delete),
                  onPressed: () {},
                ),
              );
            }
          }
        ''',
      });

      final row = views['Home']!.rows.first;
      expect(row.searchPrefix, isNull);
      expect(row.members.first.role, KeyRole.action);
    });
  });

  group('custom row widget rows', () {
    test('walks into a custom row widget class wired via index:', () {
      final views = _scan({
        'home.dart': '''
          import 'package:flutter/material.dart';
          import 'package:flutternaut/flutternaut.dart';
          import 'todo_tile.dart';

          @FlutternautView('Home')
          class HomeScreen extends StatelessWidget {
            @override
            Widget build(BuildContext context) {
              return ListView.builder(
                itemBuilder: (context, index) => TodoTile(index: index),
              );
            }
          }
        ''',
        'todo_tile.dart': '''
          import 'package:flutter/material.dart';

          class TodoTile extends StatelessWidget {
            final int index;
            const TodoTile({required this.index});

            @override
            Widget build(BuildContext context) {
              return ListTile(
                title: Text(
                  'item',
                  key: ValueKey('todo_text_\$index'),
                ),
                trailing: IconButton(
                  key: ValueKey('delete_\$index'),
                  icon: const Icon(Icons.delete),
                  onPressed: () {},
                ),
              );
            }
          }
        ''',
      });

      final row = views['Home']!.rows.first;
      expect(row.rowClass, 'TodoTile');
      expect(row.searchPrefix, 'todo_text_');
      expect(row.members.map((m) => m.label),
          containsAll(['todo_text_{index}', 'delete_{index}']));
    });
  });

  group('JSON output shape', () {
    test('serialises views, rows, elements with expected keys', () {
      final views = _scan({
        'screen.dart': '''
          import 'package:flutter/material.dart';
          import 'package:flutternaut/flutternaut.dart';

          @FlutternautView('Login')
          class LoginScreen extends StatelessWidget {
            @override
            Widget build(BuildContext context) {
              return ElevatedButton(
                key: const ValueKey('login_button'),
                onPressed: () {},
                child: const Text('Login'),
              );
            }
          }
        ''',
      });

      final out = KeysOutput(
        generatedAt: DateTime.utc(2026, 4, 25),
        package: 'demo',
        views: views,
      );
      final json = out.toJson();
      expect(json['package'], 'demo');
      expect(json['generated_at'], '2026-04-25T00:00:00.000Z');
      expect((json['views'] as Map).keys, contains('Login'));
      final loginEl =
          ((json['views'] as Map)['Login'] as Map)['elements'] as List;
      expect(loginEl.first['label'], 'login_button');
      expect(loginEl.first['role'], 'action');
      expect(loginEl.first['widget'], 'ElevatedButton');
    });
  });
}
