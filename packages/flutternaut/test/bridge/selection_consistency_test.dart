import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/query_handler.dart';
import 'package:flutternaut/src/bridge/router.dart';

import 'handlers/route_harness.dart';

// The dump's `selected` / `mixed` and `/is_selected` share one rule, but
// they can start from different layers of one control (the dump owns a row
// through its InkWell, a text locator through the GestureDetector inside
// it). This pins that every marked node answers the same through the route
// on its text — and that an unmarked node with a text answers "no state".

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

Widget _row(String title, {required bool selected}) => Semantics(
      identifier: 'btn:$title',
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
  testWidgets('every marked node agrees with /is_selected on its text',
      (tester) async {
    final walker = TreeWalker();
    final router = BridgeRouter(log: (_) {});
    QueryHandler(walker: walker, runner: MainThreadRunner()).register(router);
    final tabs = TabController(length: 2, vsync: tester);
    addTearDown(tabs.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          bottom: TabBar(controller: tabs, tabs: const [
            Tab(text: 'Coffee'),
            Tab(text: 'Tea'),
          ]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: 0,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.person), label: 'Me'),
          ],
        ),
        body: ListView(children: [
          _row('Wallet', selected: false),
          _row('Apple', selected: true),
          ChoiceChip(
              label: const Text('Large'), selected: true, onSelected: (_) {}),
          CheckboxListTile(
              value: true, onChanged: (_) {}, title: const Text('Agree')),
          ListTile(title: const Text('Orders'), onTap: () {}),
          FilledButton(onPressed: () {}, child: const Text('Log in')),
          InkWell(
            onTap: () {},
            child: const Row(children: [
              Expanded(child: Text('Remember me')),
              Checkbox(value: false, onChanged: null),
            ]),
          ),
        ]),
      ),
    ));

    final nodes = _flatten(walker.dumpVisibleTree()['elements'] as List)
        .where((n) => n['text'] is String && (n['text'] as String).isNotEmpty)
        .where((n) => n.containsKey('enabled'))
        .toList();
    expect(nodes.length, greaterThanOrEqualTo(10));
    var marked = 0;
    for (final node in nodes) {
      final text = node['text'] as String;
      final (status, envelope) =
          await postRoute(tester, router, '/is_selected', {'text': text});
      expect(status, 200, reason: '$text: $envelope');
      final data = envelope['data'] as Map<String, dynamic>;
      if (node.containsKey('selected') || node.containsKey('mixed')) {
        marked++;
        expect(data['found'], isTrue, reason: '$text: $data');
        expect(data['selected'], node['selected'], reason: text);
        expect(data['mixed'], node['mixed'], reason: text);
      } else {
        expect(data['found'], isFalse, reason: '$text: $data');
        expect(data['final'], isTrue, reason: text);
      }
    }
    expect(marked, 9, reason: 'two rows, two tabs, two destinations, chip, '
        'tile, custom row');
  });
}
