import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/assert_handler.dart';
import 'package:flutternaut/src/bridge/handlers/gesture_handler.dart';
import 'package:flutternaut/src/bridge/handlers/query_handler.dart';
import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/router.dart';

import 'handlers/route_harness.dart';

// Bridge protocol 1.10.0: typed text is a field's value, not text on screen.
// The Beanz case: "Test Automation Chain" typed into the search field must
// not satisfy expect_visible nor block expect_not_visible on the results.

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

  const query = 'Test Automation Chain';

  Widget searchScreen({String? row, Widget? extra}) => _app(Column(children: [
        TextField(
          controller: TextEditingController(text: query),
          decoration: const InputDecoration(hintText: 'Search'),
        ),
        if (row != null) ListTile(title: Text(row), onTap: () {}),
        if (extra != null) extra,
        const Text('Nearest shops'),
      ]));

  group('a typed value is not text on screen', () {
    testWidgets('absence passes, presence fails, in every match mode',
        (tester) async {
      await tester.pumpWidget(searchScreen());
      final gone = await post(tester, '/assert_not_visible', {'text': query});
      expect(gone['passed'], isTrue, reason: '$gone');
      for (final body in [
        {'text': query},
        {'text': 'test automation', 'match': 'starts_with'},
        {'text': 'automation', 'match': 'contains'},
      ]) {
        final seen = await post(tester, '/assert_visible', body);
        expect(seen['passed'], isFalse, reason: '$body: $seen');
        expect(seen['message'], contains('no widget matches'));
        final vis = await post(tester, '/is_visible', body);
        expect(vis['exists'], isFalse, reason: '$body: $vis');
      }
      final eq = await post(tester, '/assert_text_equals', {'text': query});
      expect(eq['passed'], isFalse);
      final has =
          await post(tester, '/assert_text_contains', {'text': 'Automation'});
      expect(has['passed'], isFalse);
      // The hint is faded out once the field is filled: not visible either.
      final hint = await post(tester, '/is_visible', {'text': 'Search'});
      expect(hint['visible'], isFalse);
    });

    testWidgets('a row showing the typed text is the only match, nth 0',
        (tester) async {
      await tester.pumpWidget(searchScreen(row: query));
      expect(walker.findAllElementsByText(query), hasLength(1));
      final first =
          await post(tester, '/assert_visible', {'text': query, 'nth': 0});
      expect(first['passed'], isTrue, reason: '$first');
      final second =
          await post(tester, '/assert_visible', {'text': query, 'nth': 1});
      expect(second['passed'], isFalse);
      final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
      final rows = all.where((n) => n['text'] == query).toList();
      // The value rides on the EditableText node; the TextField wrapper
      // node has no text and, for a filled field, no field_name either.
      final field = rows.singleWhere((n) => n['type'] == 'EditableText');
      final row = rows.singleWhere((n) => n['type'] != 'EditableText');
      expect(field.containsKey('text_nth'), isFalse,
          reason: 'the field is no text match: $field');
      expect(row.containsKey('text_nth'), isFalse,
          reason: 'one match needs no nth: $row');
      expect(field['field_name'], 'Search');
      final wrappers = all.where((n) => n['type'] == 'TextField').toList();
      expect(wrappers, hasLength(1));
      expect(wrappers.single.containsKey('field_name'), isFalse,
          reason: 'one node per field carries the name: ${wrappers.single}');
    });

    testWidgets('a tap by the value fails; by the row text it reaches the row',
        (tester) async {
      await tester.pumpWidget(searchScreen());
      final (status, envelope) =
          await postRoute(tester, router, '/tap', {'text': query});
      expect(status, isNot(200), reason: '$envelope');
      expect('$envelope', contains('No element found matching text'));
      var taps = 0;
      await tester.pumpWidget(_app(Column(children: [
        TextField(controller: TextEditingController(text: query)),
        ListTile(title: const Text(query), onTap: () => taps++),
      ])));
      final tapped = await post(tester, '/tap', {'text': query});
      expect(tapped['success'] ?? true, isTrue, reason: '$tapped');
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('a field keeps its name', () {
    testWidgets('type and clear reach a filled field by its hint, not value',
        (tester) async {
      final controller = TextEditingController(text: query);
      await tester.pumpWidget(_app(TextField(
        controller: controller,
        decoration: const InputDecoration(hintText: 'Search'),
      )));
      await post(tester, '/clear_text', {'text': 'Search'});
      await tester.pump();
      expect(controller.text, '');
      await post(tester, '/type', {'target': 'Search', 'text': 'latte'});
      await tester.pump();
      expect(controller.text, 'latte');
      final (status, envelope) =
          await postRoute(tester, router, '/clear_text', {'text': 'latte'});
      expect(status, isNot(200), reason: '$envelope');
      expect(controller.text, 'latte');
    });

    testWidgets('a floating label names the field too', (tester) async {
      final controller = TextEditingController(text: 'Jane');
      await tester.pumpWidget(_app(TextField(
        controller: controller,
        decoration: const InputDecoration(labelText: 'Full name'),
      )));
      await tester.pumpAndSettle();
      final read = await post(tester, '/get_text', {'text': 'Full name'});
      expect(read['found'], isTrue, reason: '$read');
      expect(read['text'], 'Jane');
      await post(tester, '/clear_text', {'text': 'Full name'});
      await tester.pump();
      expect(controller.text, '');
      final empty = await post(tester, '/get_text', {'text': 'Full name'});
      expect(empty['found'], isTrue);
      expect(empty['text'], '');
    });

    testWidgets('get_text by the hint reads the value; a heading reads itself',
        (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        const Text('Search'),
        TextField(
          controller: TextEditingController(text: query),
          decoration: const InputDecoration(hintText: 'Search shops'),
        ),
      ])));
      final heading = await post(tester, '/get_text', {'text': 'Search'});
      expect(heading['text'], 'Search');
      final value = await post(tester, '/get_text', {'text': 'Search shops'});
      expect(value['text'], query);
      final found = await post(tester, '/get_text', {'text': query});
      expect(found['found'], isFalse, reason: 'a value is not a locator');
    });

    testWidgets('field_name round-trips and is dropped when shared',
        (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        TextField(
          key: const ValueKey('a'),
          controller: TextEditingController(text: 'x'),
          decoration: const InputDecoration(hintText: 'Amount'),
        ),
        TextField(
          key: const ValueKey('b'),
          controller: TextEditingController(text: 'y'),
          decoration: const InputDecoration(hintText: 'Amount'),
        ),
        TextField(
          key: const ValueKey('c'),
          controller: TextEditingController(text: 'z'),
          decoration: const InputDecoration(
              hintText: 'Code', helperText: 'Six digits', errorText: 'Bad'),
        ),
      ])));
      final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
      // A filled field's name rides on its EditableText node (the one
      // carrying the value), found here by that value.
      Map<String, dynamic> byValue(String v) => all
          .singleWhere((n) => n['type'] == 'EditableText' && n['text'] == v);
      // Two fields share the hint: the name resolves to the first in tree
      // order (as /type and /clear_text resolve it), so only that field
      // carries it; the second has no name of its own.
      expect(byValue('x')['field_name'], 'Amount');
      expect(byValue('y').containsKey('field_name'), isFalse,
          reason: '"Amount" resolves to the first field: ${byValue('y')}');
      expect(byValue('z')['field_name'], 'Code',
          reason: 'helper and error text sit under the input');
    });

    testWidgets('an empty field carries its name on the TextField node',
        (tester) async {
      await tester.pumpWidget(_app(const TextField(
        decoration: InputDecoration(hintText: 'Search'),
      )));
      final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
      final wrapper = all.singleWhere((n) => n['type'] == 'TextField');
      expect(wrapper['field_name'], 'Search');
      expect(all.where((n) => n['type'] == 'EditableText'), isEmpty,
          reason: 'an empty EditableText is no node of its own');
    });

    testWidgets('a tap surface around a filled field is not named by the value',
        (tester) async {
      await tester.pumpWidget(_app(GestureDetector(
        onTap: () {},
        child: TextField(controller: TextEditingController(text: query)),
      )));
      final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
      final detector =
          all.where((n) => n['type'] == 'GestureDetector').toList();
      for (final d in detector) {
        expect(d['text'], isNot(query), reason: '$d');
      }
    });
  });
}
