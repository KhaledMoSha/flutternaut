import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/assert_handler.dart';
import 'package:flutternaut/src/bridge/handlers/find_handler.dart';
import 'package:flutternaut/src/bridge/handlers/gesture_handler.dart';
import 'package:flutternaut/src/bridge/handlers/query_handler.dart';
import 'package:flutternaut/src/bridge/handlers/wait_handler.dart';
import 'package:flutternaut/src/bridge/router.dart';

import 'route_harness.dart';

// Bridge protocol 1.10.0: every route answers for a field when a `text`
// locator names it (its key, its hint/label/placeholder, a caption), and
// never finds it by the value typed into it.

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

List<Map<String, dynamic>> _flatten(List<dynamic> nodes) {
  final out = <Map<String, dynamic>>[];
  void visit(Map<String, dynamic> n) {
    out.add(n);
    for (final c in (n['children'] as List?) ?? const []) {
      visit(c as Map<String, dynamic>);
    }
  }

  for (final n in nodes) {
    visit(n as Map<String, dynamic>);
  }
  return out;
}

void main() {
  late TreeWalker walker;
  late BridgeRouter router;

  setUp(() {
    walker = TreeWalker();
    final runner = MainThreadRunner();
    router = BridgeRouter(log: (_) {});
    QueryHandler(walker: walker, runner: runner).register(router);
    AssertHandler(walker: walker, runner: runner).register(router);
    FindHandler(walker: walker, runner: runner).register(router);
    WaitHandler(walker: walker, runner: runner).register(router);
    GestureHandler(gesture: GestureDispatcher(walker), runner: runner)
        .register(router);
  });

  Future<Map<String, dynamic>> post(
    WidgetTester tester,
    String path,
    Map<String, dynamic> body,
  ) async {
    final (status, envelope) = await postRoute(tester, router, path, body);
    expect(status, 200, reason: '$path $body: $envelope');
    return envelope['data'] as Map<String, dynamic>;
  }

  const value = 'Test Automation Chain';

  Widget searchScreen([TextEditingController? controller]) => _app(Column(
        children: [
          TextField(
            controller: controller ?? TextEditingController(text: value),
            decoration: const InputDecoration(hintText: 'Search'),
          ),
          const Text('Nearest shops'),
        ],
      ));

  // The wait loops time on a real Stopwatch while their sleeps run on fake
  // time, so a short real budget (1 ms) is what lets a miss end in the test.
  group('wait routes', () {
    testWidgets('wait_for_text by the hint compares the value', (tester) async {
      await tester.pumpWidget(searchScreen());
      final ok = await post(
          tester, '/wait_for_text', {'text': 'Search', 'expected': value});
      expect(ok['success'], isTrue, reason: '$ok');
      final timedOut = await post(tester, '/wait_for_text',
          {'text': 'Search', 'expected': 'other', 'timeout_ms': 1});
      expect(timedOut['success'], isFalse, reason: '$timedOut');
    });

    testWidgets('wait_until_gone by the value returns at once', (tester) async {
      await tester.pumpWidget(searchScreen());
      final gone = await post(
          tester, '/wait_until_gone', {'text': value, 'timeout_ms': 1});
      expect(gone['success'], isTrue, reason: '$gone');
    });

    testWidgets('wait_until_visible by the value times out', (tester) async {
      await tester.pumpWidget(searchScreen());
      final seen = await post(
          tester, '/wait_until_visible', {'text': value, 'timeout_ms': 1});
      expect(seen['success'], isFalse, reason: '$seen');
    });
  });

  group('find, read and assert', () {
    testWidgets('read and find by the hint return the field', (tester) async {
      await tester.pumpWidget(searchScreen());
      final read = await post(tester, '/read', {'text': 'Search'});
      expect(read['found'], isTrue, reason: '$read');
      expect(
          read['type'], anyOf(contains('EditableText'), contains('TextField')));
      expect(read['text'], value);
      final find = await post(tester, '/find', {'text': 'Search'});
      expect(find['found'], isTrue, reason: '$find');
      expect('${find['type']}',
          anyOf(contains('EditableText'), contains('TextField')));
      expect(find['text'], value);
      final byValue = await post(tester, '/read', {'text': value});
      expect(byValue['found'], isFalse, reason: '$byValue');
    });

    testWidgets(
        'assert_exists by the hint passes; not_exists by the value passes',
        (tester) async {
      await tester.pumpWidget(searchScreen());
      final has = await post(tester, '/assert_exists', {'text': 'Search'});
      expect(has['passed'], isTrue, reason: '$has');
      final none = await post(tester, '/assert_not_exists', {'text': value});
      expect(none['passed'], isTrue, reason: '$none');
    });

    testWidgets('a state route by a filled field hint finds the TextField',
        (tester) async {
      await tester.pumpWidget(searchScreen());
      final state = await post(tester, '/is_enabled', {'text': 'Search'});
      expect(state['found'], isTrue, reason: '$state');
      expect(state['enabled'], isTrue);
      expect('${state['control']}', contains('TextField'));
    });

    testWidgets('the scroll resolver does not find a typed value',
        (tester) async {
      await tester.pumpWidget(searchScreen());
      expect(walker.findElementByText(value), isNull);
      expect(walker.findElementByText('Nearest shops'), isNotNull);
    });
  });

  group('field kinds', () {
    testWidgets('a Cupertino field is named by its placeholder',
        (tester) async {
      final controller = TextEditingController(text: '5551234');
      await tester.pumpWidget(CupertinoApp(
        home: CupertinoPageScaffold(
          child: Center(
            child: CupertinoTextField(
                controller: controller, placeholder: 'Phone'),
          ),
        ),
      ));
      final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
      final named = all.where((n) => n['field_name'] == 'Phone').toList();
      expect(named, hasLength(1), reason: 'one node per field: $named');
      final read = await post(tester, '/get_text', {'text': 'Phone'});
      expect(read['found'], isTrue, reason: '$read');
      expect(read['text'], '5551234');
      await post(tester, '/clear_text', {'text': 'Phone'});
      await tester.pump();
      expect(controller.text, '');
    });

    testWidgets('a bare EditableText has no field_name, but reads by key',
        (tester) async {
      final controller = TextEditingController(text: 'raw value');
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_app(EditableText(
        key: const ValueKey('raw'),
        controller: controller,
        focusNode: focus,
        style: const TextStyle(fontSize: 14),
        cursorColor: Colors.black,
        backgroundCursorColor: Colors.grey,
      )));
      final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
      final fields = all.where((n) => n['type'] == 'EditableText').toList();
      expect(fields, isNotEmpty);
      for (final f in fields) {
        expect(f.containsKey('field_name'), isFalse, reason: '$f');
      }
      final read = await post(tester, '/get_text', {'key': 'raw'});
      expect(read['found'], isTrue, reason: '$read');
      expect(read['text'], 'raw value');
    });
  });
}
