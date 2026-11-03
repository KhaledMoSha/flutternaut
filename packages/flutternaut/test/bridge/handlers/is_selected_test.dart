import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/query_handler.dart';
import 'package:flutternaut/src/bridge/router.dart';

import 'route_harness.dart';

// `POST /is_selected` (protocol 1.9.0): the selection state of the control
// a locator names, by the rule the `/screen` dump uses.

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

Widget _row(String title, {required bool selected}) => Semantics(
      identifier: 'btn:payment_method:${title.toLowerCase()}',
      button: true,
      checked: selected,
      selected: selected,
      excludeSemantics: true,
      child: InkWell(
        onTap: () {},
        child: Row(children: [Expanded(child: Text(title))]),
      ),
    );

void main() {
  late BridgeRouter router;

  setUp(() {
    final walker = TreeWalker();
    router = BridgeRouter(log: (_) {});
    QueryHandler(walker: walker, runner: MainThreadRunner()).register(router);
  });

  Future<Map<String, dynamic>> ask(
    WidgetTester tester,
    Map<String, dynamic> body,
  ) async {
    final (status, envelope) =
        await postRoute(tester, router, '/is_selected', body);
    expect(status, 200, reason: '$envelope');
    return envelope['data'] as Map<String, dynamic>;
  }

  testWidgets('a row answers by text, by semantics id, by prefix and by nth',
      (tester) async {
    await tester.pumpWidget(_app(Column(children: [
      _row('Wallet', selected: false),
      _row('Apple', selected: true),
    ])));

    final byText = await ask(tester, {'text': 'Apple'});
    expect(byText['found'], isTrue);
    expect(byText['selected'], isTrue);
    expect(byText['control'], endsWith('"Apple"'),
        reason:
            'the control that owns the label, as the enabled routes name it');
    final byId = await ask(tester, {'semantics': 'btn:payment_method:wallet'});
    expect(byId['found'], isTrue);
    expect(byId['selected'], isFalse);
    final byPrefix = await ask(tester, {'text': 'app', 'match': 'starts_with'});
    expect(byPrefix['selected'], isTrue);
    // Both rows match "l" somewhere: ambiguous without nth, resolved with it.
    final ambiguous = await ask(tester, {'text': 'l', 'match': 'contains'});
    expect(ambiguous['found'], isFalse);
    expect(ambiguous['final'], isNull, reason: 'the screen may change');
    expect(ambiguous['reason'], contains('ambiguous'));
    final second =
        await ask(tester, {'text': 'l', 'match': 'contains', 'nth': 1});
    expect(second['selected'], isTrue);
  });

  testWidgets('a mixed tristate answers mixed without selected',
      (tester) async {
    await tester.pumpWidget(_app(Checkbox(
      key: const ValueKey('all'),
      tristate: true,
      value: null,
      onChanged: (_) {},
    )));
    final data = await ask(tester, {'key': 'all'});
    expect(data, {
      'found': true,
      'mixed': true,
      'control': 'Checkbox key "all"',
    });
  });

  testWidgets('nothing matching is a retryable miss', (tester) async {
    await tester.pumpWidget(_app(const Text('Total')));
    final data = await ask(tester, {'text': 'Apple'});
    expect(data['found'], isFalse);
    expect(data['final'], isNull);
    expect(data['reason'], 'no widget matches text "Apple"');
  });

  testWidgets('a caption is finally not a control', (tester) async {
    await tester.pumpWidget(_app(const Text('Total')));
    final data = await ask(tester, {'text': 'Total'});
    expect(data['found'], isFalse);
    expect(data['final'], isTrue);
    expect(data['reason'], contains('is not part of any control'));
  });

  testWidgets(
      'a control without a selection state is finally none, and '
      'a tile names its highlight', (tester) async {
    await tester.pumpWidget(_app(Column(children: [
      FilledButton(onPressed: () {}, child: const Text('Log in')),
      ListTile(title: const Text('Orders'), selected: true, onTap: () {}),
    ])));
    final button = await ask(tester, {'text': 'Log in'});
    expect(button['found'], isFalse);
    expect(button['final'], isTrue);
    expect(button['control'], 'FilledButton "Log in"');
    expect(
      button['reason'],
      'FilledButton "Log in" has no selected state: it is not a checkbox, '
      'radio, switch, chip, tab, segment or navigation destination, and no '
      'Semantics(checked:, selected:, toggled:) around it or inside it '
      'declares one for it alone — address the selection control itself '
      '(a row\'s state may sit on the checkbox or radio inside it)',
    );
    final tile = await ask(tester, {'text': 'Orders'});
    expect(tile['final'], isTrue);
    expect(tile['reason'],
        endsWith("(a ListTile's selected highlight is not a selection state)"));
  });

  testWidgets('a request without a locator is a 400', (tester) async {
    await tester.pumpWidget(_app(const SizedBox()));
    final (status, _) = await postRoute(tester, router, '/is_selected', {});
    expect(status, 400);
  });
}
