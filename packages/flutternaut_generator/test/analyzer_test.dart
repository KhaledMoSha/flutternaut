import 'dart:convert';

import 'package:test/test.dart';

import 'package:flutternaut_generator/flutternaut_generator.dart';

/// Wraps a widget expression in a valid Dart function body.
String _wrap(String expr) => 'void f() { $expr; }';

void main() {
  late FlutternautAnalyzer analyzer;

  setUp(() {
    analyzer = FlutternautAnalyzer();
  });

  group('constructor type detection', () {
    test('default constructor maps to "element"', () {
      final source = _wrap(
          "Flutternaut(label: 'drag_target', child: Container())");
      final elements = analyzer.analyzeSource(source, 'lib/my_widget.dart');
      expect(elements, hasLength(1));
      expect(elements.first.type, 'element');
    });

    test('named constructors map to their names', () {
      final source = _wrap('''
Column(children: [
  Flutternaut.input(label: 'email_input', child: TextField()),
  Flutternaut.button(label: 'login_button', child: ElevatedButton(onPressed: () {}, child: Text('Login'))),
  Flutternaut.text(label: 'error_text', child: Text('Error')),
  Flutternaut.item(label: 'list_item', child: ListTile()),
  Flutternaut.checkbox(label: 'agree_check', checked: false, child: Checkbox(value: false, onChanged: (_) {})),
])''');
      final elements = analyzer.analyzeSource(source, 'lib/login.dart');
      expect(elements, hasLength(5));
      expect(elements[0].type, 'input');
      expect(elements[1].type, 'button');
      expect(elements[2].type, 'text');
      expect(elements[3].type, 'item');
      expect(elements[4].type, 'checkbox');
    });
  });

  group('label extraction', () {
    test('extracts static string labels', () {
      final source = _wrap('''
Flutternaut.button(
  label: 'submit_button',
  child: ElevatedButton(onPressed: () {}, child: Text('Submit')),
)''');
      final elements = analyzer.analyzeSource(source, 'lib/home.dart');
      expect(elements.first.label, 'submit_button');
      expect(elements.first.isDynamic, false);
    });

    test(r'detects dynamic labels with $index', () {
      final source =
          _wrap(r"Flutternaut.item(label: 'todo_item_$index', child: Text('item'))");
      final elements = analyzer.analyzeSource(source, 'lib/todo.dart');
      expect(elements.first.isDynamic, true);
      expect(elements.first.label, 'todo_item_{index}');
    });

    test(r'detects dynamic labels with ${expr}', () {
      final source = _wrap(
          r"Flutternaut.item(label: 'row_${items.indexOf(item)}', child: Text('row'))");
      final elements = analyzer.analyzeSource(source, 'lib/list.dart');
      expect(elements.first.isDynamic, true);
      expect(elements.first.label, 'row_{index}');
    });

    test('rewrites named variables in interpolation', () {
      final source = _wrap(
          r"Flutternaut.text(label: 'user_${name}_label', child: Text('name'))");
      final elements = analyzer.analyzeSource(source, 'lib/profile.dart');
      expect(elements.first.isDynamic, true);
      expect(elements.first.label, 'user_{name}_label');
    });
  });

  group('description extraction', () {
    test('extracts description when present', () {
      final source = _wrap('''
Flutternaut.text(
  label: 'item_count',
  description: 'Shows total number of items',
  child: Text('5 items'),
)''');
      final elements = analyzer.analyzeSource(source, 'lib/dash.dart');
      expect(elements.first.description, 'Shows total number of items');
    });

    test('description is null when not provided', () {
      final source =
          _wrap("Flutternaut.button(label: 'btn', child: Container())");
      final elements = analyzer.analyzeSource(source, 'lib/simple.dart');
      expect(elements.first.description, isNull);
    });
  });

  group('file tracking', () {
    test('elements include their file path', () {
      final source =
          _wrap("Flutternaut.button(label: 'btn', child: Container())");
      final elements = analyzer.analyzeSource(source, 'lib/login.dart');
      expect(elements.first.file, 'lib/login.dart');
    });

    test('multiple elements from same file share the path', () {
      final source = _wrap('''
Column(children: [
  Flutternaut.input(label: 'name_input', child: TextField()),
  Flutternaut.input(label: 'email_input', child: TextField()),
  Flutternaut.button(label: 'submit_btn', child: ElevatedButton(onPressed: () {}, child: Text('Go'))),
])''');
      final elements = analyzer.analyzeSource(source, 'lib/form.dart');
      expect(elements, hasLength(3));
      expect(elements.every((e) => e.file == 'lib/form.dart'), true);
    });
  });

  group('edge cases', () {
    test('file with no Flutternaut widgets returns empty', () {
      final source = _wrap('Container()');
      final elements = analyzer.analyzeSource(source, 'lib/plain.dart');
      expect(elements, isEmpty);
    });

    test('ignores raw Semantics widgets', () {
      final source =
          _wrap("Semantics(label: 'raw_label', child: Container())");
      final elements = analyzer.analyzeSource(source, 'lib/raw.dart');
      expect(elements, isEmpty);
    });

    test('handles const Flutternaut constructors', () {
      const source =
          "final x = const Flutternaut.button(label: 'const_btn', child: SizedBox());";
      final elements = analyzer.analyzeSource(source, 'lib/const.dart');
      expect(elements, hasLength(1));
      expect(elements.first.label, 'const_btn');
      expect(elements.first.type, 'button');
    });
  });

  group('view annotation', () {
    test('@FlutternautView sets view on elements', () {
      const source = '''
@FlutternautView('Login')
class LoginScreen extends StatelessWidget {
  Widget build(BuildContext context) {
    return Flutternaut.button(label: 'login_button', child: Container());
  }
}
''';
      final elements = analyzer.analyzeSource(source, 'lib/login.dart');
      expect(elements, hasLength(1));
      expect(elements.first.view, 'Login');
    });

    test('@FlutternautView on StatefulWidget propagates to State class', () {
      const source = '''
@FlutternautView('Login')
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  Widget build(BuildContext context) {
    return Flutternaut.input(label: 'email_input', child: TextField());
  }
}
''';
      final elements = analyzer.analyzeSource(source, 'lib/login.dart');
      expect(elements, hasLength(1));
      expect(elements.first.label, 'email_input');
      expect(elements.first.view, 'Login');
    });

    test('elements without annotation have null view', () {
      const source = '''
class HomeScreen extends StatelessWidget {
  Widget build(BuildContext context) {
    return Flutternaut.button(label: 'home_button', child: Container());
  }
}
''';
      final elements = analyzer.analyzeSource(source, 'lib/home.dart');
      expect(elements.first.view, isNull);
    });

    test('two classes with different views in same file', () {
      const source = '''
@FlutternautView('Login')
class LoginScreen extends StatelessWidget {
  Widget build(BuildContext context) {
    return Flutternaut.input(label: 'email_input', child: TextField());
  }
}

@FlutternautView('Profile')
class ProfileScreen extends StatelessWidget {
  Widget build(BuildContext context) {
    return Flutternaut.text(label: 'username', child: Text(''));
  }
}
''';
      final elements = analyzer.analyzeSource(source, 'lib/screens.dart');
      expect(elements, hasLength(2));
      expect(elements[0].view, 'Login');
      expect(elements[1].view, 'Profile');
    });

    test('view field included in JSON only when non-null', () {
      const withView = FlutternautElement(
          label: 'btn', type: 'button', view: 'Login', file: 'lib/a.dart');
      expect(withView.toJson()['view'], 'Login');

      const withoutView = FlutternautElement(
          label: 'btn', type: 'button', file: 'lib/a.dart');
      expect(withoutView.toJson().containsKey('view'), false);
    });
  });

  group('models', () {
    test('FlutternautElement.toJson includes dynamic field only when true',
        () {
      const staticEl = FlutternautElement(
          label: 'btn', type: 'button', file: 'lib/a.dart');
      expect(staticEl.toJson().containsKey('dynamic'), false);

      const dynamicEl = FlutternautElement(
          label: 'item_{index}',
          type: 'item',
          isDynamic: true,
          file: 'lib/a.dart');
      expect(dynamicEl.toJson()['dynamic'], true);
    });

    test('FlutternautElement.toJson includes file path', () {
      const el = FlutternautElement(
          label: 'btn', type: 'button', file: 'lib/login.dart');
      expect(el.toJson()['file'], 'lib/login.dart');
    });

    test('KeysOutput.toJsonString produces valid JSON', () {
      final output = KeysOutput(
        generatedAt: DateTime.utc(2026, 3, 10, 12),
        package: 'my_app',
        elements: [
          const FlutternautElement(
              label: 'email_input', type: 'input', file: 'lib/login.dart'),
        ],
      );

      final json = output.toJsonString();
      final parsed = Map<String, dynamic>.from(
        jsonDecode(json) as Map,
      );
      expect(parsed['package'], 'my_app');
      expect(parsed['generated_at'], '2026-03-10T12:00:00.000Z');
      expect((parsed['elements'] as List).first['label'], 'email_input');
      expect((parsed['elements'] as List).first['file'], 'lib/login.dart');
    });
  });
}
