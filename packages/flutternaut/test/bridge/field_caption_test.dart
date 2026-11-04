import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/assert_handler.dart';
import 'package:flutternaut/src/bridge/handlers/gesture_handler.dart';
import 'package:flutternaut/src/bridge/handlers/query_handler.dart';
import 'package:flutternaut/src/bridge/handlers/wait_handler.dart';
import 'package:flutternaut/src/bridge/router.dart';

import 'handlers/route_harness.dart';

// Bridge protocol 1.11.1: a field is named by what its decoration declares,
// and a caption beside it names it on the field routes — the Beanz "Edit
// account details" form: a caption above each field, a dial-code prefix
// inside the phone field, values the app filled in.

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

/// A Beanz-shaped phone row: caption above, a read-only field whose hint is
/// empty, a "+971" prefix drawn inside the decoration.
Widget _phoneRow(String value, {String hint = ''}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Phone number'),
        TextFormField(
          controller: TextEditingController(text: value),
          readOnly: true,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('+971'),
            ),
          ),
        ),
      ],
    );

void main() {
  late TreeWalker walker;
  late BridgeRouter router;
  late TextEditingController phone;

  setUp(() {
    walker = TreeWalker();
    final runner = MainThreadRunner();
    router = BridgeRouter(log: (_) {});
    QueryHandler(walker: walker, runner: runner).register(router);
    AssertHandler(walker: walker, runner: runner).register(router);
    WaitHandler(walker: walker, runner: runner).register(router);
    GestureHandler(gesture: GestureDispatcher(walker), runner: runner)
        .register(router);
    phone = TextEditingController(text: '55 111 5152');
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

  Widget form() => _app(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Display name'),
          TextFormField(
            controller: TextEditingController(text: 'Khaled E2E'),
            decoration: const InputDecoration(hintText: ''),
          ),
          const Text('Phone number'),
          TextFormField(
            controller: phone,
            readOnly: true,
            decoration: const InputDecoration(
              hintText: '',
              prefixIcon: Padding(
                padding: EdgeInsets.all(12),
                child: Text('+971'),
              ),
            ),
          ),
          const Text('Date of birth'),
          const TextField(
            decoration: InputDecoration(hintText: 'Select day and month'),
          ),
        ],
      ));

  group('a field is named by what its decoration declares', () {
    testWidgets(
        'a prefix drawn inside never names the field; an empty hint '
        'leaves it unnamed', (tester) async {
      await tester.pumpWidget(form());
      final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
      for (final n in all) {
        expect(n['field_name'], isNot('+971'), reason: '$n');
      }
      final phoneNode = all.singleWhere((n) => n['text'] == '55 111 5152');
      expect(phoneNode.containsKey('field_name'), isFalse,
          reason: 'an empty hint declares no name: $phoneNode');
      final dob = all.singleWhere((n) =>
          n['type'] == 'TextField' &&
          n['field_name'] == 'Select day and month');
      expect(dob, isNotNull);
    });

    testWidgets('labelText names the field, before hintText', (tester) async {
      await tester.pumpWidget(_app(TextField(
        controller: TextEditingController(text: 'Jane'),
        decoration:
            const InputDecoration(labelText: 'Full name', hintText: 'Name'),
      )));
      await tester.pumpAndSettle();
      final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
      final node = all.singleWhere((n) => n['text'] == 'Jane');
      expect(node['field_name'], 'Full name');
    });

    testWidgets('a Cupertino placeholder names the field', (tester) async {
      await tester.pumpWidget(_app(CupertinoTextField(
        controller: TextEditingController(text: '5551234'),
        placeholder: 'Phone',
      )));
      final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
      expect(all.singleWhere((n) => n['text'] == '5551234')['field_name'],
          'Phone');
    });
  });

  group('a caption beside a field names it on the field routes', () {
    testWidgets('get_text and wait_for_text by the caption read the value',
        (tester) async {
      await tester.pumpWidget(form());
      final read = await post(tester, '/get_text', {'text': 'Phone number'});
      expect(read['found'], isTrue, reason: '$read');
      expect(read['text'], '55 111 5152');
      final name = await post(tester, '/get_text', {'text': 'Display name'});
      expect(name['text'], 'Khaled E2E');
      final waited = await post(tester, '/wait_for_text', {
        'text': 'Phone number',
        'expected': '55 111 5152',
        'timeout_ms': 500,
      });
      expect(waited['success'] ?? waited['found'] ?? true, isTrue,
          reason: '$waited');
      // A wrong expectation fails: the check is not vacuous.
      final (status, wrong) =
          await postRoute(tester, router, '/wait_for_text', {
        'text': 'Phone number',
        'expected': '55 111 5151',
        'timeout_ms': 1,
      });
      expect(
          status == 200 && (wrong['data'] as Map)['success'] == true, isFalse,
          reason: '$wrong');
    });

    testWidgets('the value itself is still no locator, and absent as text',
        (tester) async {
      await tester.pumpWidget(form());
      final byValue = await post(tester, '/get_text', {'text': '55 111 5152'});
      expect(byValue['found'], isFalse);
      final gone =
          await post(tester, '/assert_not_visible', {'text': '55 111 5152'});
      expect(gone['passed'], isTrue);
      final seen =
          await post(tester, '/assert_visible', {'text': '55 111 5152'});
      expect(seen['passed'], isFalse);
    });

    testWidgets(
        'a caption with no field within a row reads itself; a '
        'heading right above a field reads the field (the documented limit)',
        (tester) async {
      await tester.pumpWidget(_app(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your details'),
          TextField(controller: TextEditingController(text: 'Jane')),
          const SizedBox(height: 200),
          const Text('Nothing below me'),
        ],
      )));
      final heading = await post(tester, '/get_text', {'text': 'Your details'});
      expect(heading['text'], 'Jane');
      final lonely =
          await post(tester, '/get_text', {'text': 'Nothing below me'});
      expect(lonely['text'], 'Nothing below me');
    });

    testWidgets('a caption is not mapped for visibility or taps',
        (tester) async {
      await tester.pumpWidget(form());
      final vis = await post(tester, '/is_visible', {'text': 'Phone number'});
      expect(vis['visible'], isTrue);
      final tapped = await post(tester, '/tap', {'text': 'Phone number'});
      expect(tapped['success'] ?? true, isTrue, reason: '$tapped');
      expect(phone.text, '55 111 5152');
    });
  });

  group('a declared name reaches the field everywhere', () {
    testWidgets('is_visible and assert_visible by a filled field\'s hint',
        (tester) async {
      final controller = TextEditingController(text: 'latte');
      await tester.pumpWidget(_app(TextField(
        controller: controller,
        decoration: const InputDecoration(hintText: 'Search'),
      )));
      final vis = await post(tester, '/is_visible', {'text': 'Search'});
      expect(vis['visible'], isTrue, reason: 'the hint is faded: $vis');
      final seen = await post(tester, '/assert_visible', {'text': 'Search'});
      expect(seen['passed'], isTrue, reason: '$seen');
      final gone =
          await post(tester, '/assert_not_visible', {'text': 'Search'});
      expect(gone['passed'], isFalse, reason: '$gone');
    });

    testWidgets(
        'a row showing the hint text is counted beside the field, '
        'nth in reading order', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        TextField(
          controller: TextEditingController(text: 'x'),
          decoration: const InputDecoration(hintText: 'Search'),
        ),
        ListTile(title: const Text('Search'), onTap: () {}),
      ])));
      // Not every match names a field, so nothing is mapped: nth indexes
      // the visible drawn matches, and the faded hint is not one of them.
      final first =
          await post(tester, '/assert_visible', {'text': 'Search', 'nth': 0});
      expect(first['passed'], isTrue, reason: '$first');
      final second =
          await post(tester, '/assert_visible', {'text': 'Search', 'nth': 1});
      expect(second['passed'], isFalse, reason: '$second');
    });
  });

  testWidgets('the phone row alone: the readout shape the catalog builds on',
      (tester) async {
    await tester.pumpWidget(_app(_phoneRow('55 111 5152')));
    final all = _flatten(walker.dumpVisibleTree()['elements'] as List);
    final caption = all.where((n) => n['text'] == 'Phone number').toList();
    expect(caption, hasLength(1));
    expect(caption.single.containsKey('field_name'), isFalse);
    final value = all.singleWhere((n) => n['text'] == '55 111 5152');
    expect(value['type'], 'EditableText');
    expect(value.containsKey('field_name'), isFalse);
  });
}
