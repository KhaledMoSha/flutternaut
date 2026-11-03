import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/tree_walker.dart';

// The `/screen` dump's `selected` / `mixed` (protocol 1.9.0): one rule reads
// the accessibility flags a control declares, so a checkbox, a radio, a chip,
// a tab, a navigation destination and an app-drawn row that wraps its tap
// surface in `Semantics(selected:)` all show their state on the node that
// carries `enabled`, and nothing else does.

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

/// The one dump node showing [text] (its own or as a control's label).
Map<String, dynamic> _node(List<Map<String, dynamic>> nodes, String text) {
  final matches = nodes.where((n) => n['text'] == text).toList();
  expect(matches, hasLength(1), reason: 'nodes with text "$text": $matches');
  return matches.single;
}

/// The Beanz `SafeOnTap` shape: a `Semantics` carrying the identifier and
/// the binary state around the row's tap surface, which shows the title and
/// a painted (flag-less) indicator. With [padded], a `Padding` sits between
/// the wrapper and the surface, so their bounds differ.
Widget _beanzRow(
  String title, {
  required bool selected,
  bool padded = false,
  Widget? trailing,
}) {
  Widget surface = InkWell(
    onTap: () {},
    child: Row(children: [
      Expanded(child: Text(title)),
      if (trailing != null) trailing,
      Container(width: 20, height: 20, color: Colors.green),
    ]),
  );
  if (padded) surface = Padding(padding: const EdgeInsets.all(8), child: surface);
  return Semantics(
    identifier: 'btn:payment_method:${title.toLowerCase()}',
    button: true,
    value: selected ? '1' : '0',
    checked: selected,
    selected: selected,
    excludeSemantics: true,
    child: surface,
  );
}

void main() {
  final walker = TreeWalker();

  List<Map<String, dynamic>> nodes() =>
      _flatten(walker.dumpVisibleTree()['elements'] as List);

  group('an app-drawn row that declares its state on a Semantics wrapper', () {
    testWidgets('shows it on the row node, and only there', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        _beanzRow('Wallet', selected: false),
        _beanzRow('Apple', selected: true),
        const Text('Total to pay'),
      ])));

      final all = nodes();
      final wallet = _node(all, 'Wallet');
      expect(wallet['enabled'], isTrue);
      expect(wallet['selected'], isFalse);
      expect(wallet['semantics_id'], 'btn:payment_method:wallet');
      final apple = _node(all, 'Apple');
      expect(apple['selected'], isTrue);
      expect(apple.containsKey('mixed'), isFalse);
      expect(_node(all, 'Total to pay').containsKey('selected'), isFalse);
    });

    testWidgets('also through a Padding between wrapper and surface',
        (tester) async {
      await tester.pumpWidget(_app(_beanzRow('Card', selected: true, padded: true)));
      expect(_node(nodes(), 'Card')['selected'], isTrue);
    });

    testWidgets('a button inside the row does not break the row\'s state',
        (tester) async {
      await tester.pumpWidget(_app(_beanzRow(
        'Visa',
        selected: true,
        trailing: TextButton(onPressed: () {}, child: const Text('Edit')),
      )));
      final all = nodes();
      expect(_node(all, 'Visa')['selected'], isTrue);
      expect(_node(all, 'Edit').containsKey('selected'), isFalse,
          reason: 'the edit button has no state of its own');
    });

    testWidgets('follows the app\'s state across a rebuild', (tester) async {
      var on = false;
      late StateSetter set;
      await tester.pumpWidget(_app(StatefulBuilder(builder: (context, s) {
        set = s;
        return _beanzRow('Pay', selected: on);
      })));
      expect(_node(nodes(), 'Pay')['selected'], isFalse);
      set(() => on = true);
      await tester.pump();
      expect(_node(nodes(), 'Pay')['selected'], isTrue);
    });
  });

  group('Material and Cupertino controls', () {
    testWidgets('checkboxes: value, tristate null is mixed, checked kept',
        (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        Checkbox(key: const ValueKey('on'), value: true, onChanged: (_) {}),
        Checkbox(key: const ValueKey('off'), value: false, onChanged: (_) {}),
        Checkbox(
            key: const ValueKey('some'),
            tristate: true,
            value: null,
            onChanged: (_) {}),
        CupertinoCheckbox(
            key: const ValueKey('cup'), value: true, onChanged: (_) {}),
      ])));
      final all = nodes();
      Map<String, dynamic> byKey(String k) =>
          all.singleWhere((n) => n['key'] == k);
      expect(byKey('on')['selected'], isTrue);
      expect(byKey('on')['checked'], isTrue, reason: 'the old field stays');
      expect(byKey('off')['selected'], isFalse);
      final some = byKey('some');
      expect(some['mixed'], isTrue);
      expect(some.containsKey('selected'), isFalse,
          reason: 'mixed is never "not selected"');
      expect(byKey('cup')['selected'], isTrue);
    });

    testWidgets('switches and radios', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        Switch(key: const ValueKey('m'), value: true, onChanged: (_) {}),
        CupertinoSwitch(
            key: const ValueKey('c'), value: false, onChanged: (_) {}),
        RadioGroup<int>(
          groupValue: 1,
          onChanged: (_) {},
          child: const Row(children: [
            Radio<int>(key: ValueKey('r0'), value: 0),
            Radio<int>(key: ValueKey('r1'), value: 1),
          ]),
        ),
      ])));
      final all = nodes();
      Map<String, dynamic> byKey(String k) =>
          all.singleWhere((n) => n['key'] == k);
      expect(byKey('m')['selected'], isTrue);
      expect(byKey('c')['selected'], isFalse);
      expect(byKey('r0')['selected'], isFalse);
      expect(byKey('r1')['selected'], isTrue);
    });

    testWidgets('chips: a selectable chip reports, an action chip does not',
        (tester) async {
      await tester.pumpWidget(_app(ListView(children: [
        ChoiceChip(
            label: const Text('Large'), selected: true, onSelected: (_) {}),
        FilterChip(
            label: const Text('Vegan'), selected: false, onSelected: (_) {}),
        ActionChip(label: const Text('Share'), onPressed: () {}),
      ])));
      final all = nodes();
      expect(_node(all, 'Large')['selected'], isTrue,
          reason: 'the chip\'s Semantics is wider than its tap surface in a list');
      expect(_node(all, 'Vegan')['selected'], isFalse);
      expect(_node(all, 'Share').containsKey('selected'), isFalse);
    });

    testWidgets('tabs, navigation destinations, segments, toggle icon buttons',
        (tester) async {
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
            selectedIndex: 1,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.person), label: 'Me'),
            ],
          ),
          body: Column(children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Pickup')),
                ButtonSegment(value: 1, label: Text('Delivery')),
              ],
              selected: const {1},
              onSelectionChanged: (_) {},
            ),
            IconButton(
              key: const ValueKey('fav'),
              isSelected: true,
              icon: const Icon(Icons.favorite),
              onPressed: () {},
            ),
          ]),
        ),
      ));
      var all = nodes();
      expect(_node(all, 'Coffee')['selected'], isTrue);
      expect(_node(all, 'Tea')['selected'], isFalse);
      expect(_node(all, 'Home')['selected'], isFalse);
      expect(_node(all, 'Me')['selected'], isTrue);
      expect(_node(all, 'Pickup')['selected'], isFalse);
      expect(_node(all, 'Delivery')['selected'], isTrue);
      expect(all.singleWhere((n) => n['key'] == 'fav')['selected'], isTrue);

      tabs.animateTo(1);
      await tester.pumpAndSettle();
      all = nodes();
      expect(_node(all, 'Coffee')['selected'], isFalse);
      expect(_node(all, 'Tea')['selected'], isTrue);
    });
  });

  group('list tiles', () {
    testWidgets('the *ListTile wrappers report their control on the tile',
        (tester) async {
      await tester.pumpWidget(_app(RadioGroup<int>(
        groupValue: 0,
        onChanged: (_) {},
        child: Column(children: [
          CheckboxListTile(
              value: true, onChanged: (_) {}, title: const Text('Agree')),
          SwitchListTile(
              value: false, onChanged: (_) {}, title: const Text('Dark')),
          const RadioListTile<int>(value: 0, title: Text('Small')),
          const RadioListTile<int>(value: 1, title: Text('Big')),
        ]),
      )));
      final all = nodes();
      expect(_node(all, 'Agree')['selected'], isTrue);
      expect(_node(all, 'Dark')['selected'], isFalse);
      expect(_node(all, 'Small')['selected'], isTrue);
      expect(_node(all, 'Big')['selected'], isFalse);
    });

    testWidgets('a plain tile\'s highlight is not a state; a live switch '
        'inside a tile keeps its own', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        ListTile(title: const Text('Orders'), onTap: () {}),
        ListTile(title: const Text('Profile'), selected: true, onTap: () {}),
        ListTile(
          title: const Text('Sounds'),
          onTap: () {},
          trailing: Switch(
              key: const ValueKey('snd'), value: true, onChanged: (_) {}),
        ),
      ])));
      final all = nodes();
      expect(_node(all, 'Orders')['enabled'], isTrue);
      expect(_node(all, 'Orders').containsKey('selected'), isFalse);
      expect(_node(all, 'Profile').containsKey('selected'), isFalse);
      expect(_node(all, 'Sounds').containsKey('selected'), isFalse,
          reason: 'the tile\'s tap does not flip the switch');
      expect(all.singleWhere((n) => n['key'] == 'snd')['selected'], isTrue);
    });
  });

  group('custom surfaces', () {
    testWidgets('a row shows the state of a display-only checkbox inside it, '
        'a card with a live checkbox does not', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        InkWell(
          onTap: () {},
          child: const Row(children: [
            Expanded(child: Text('Remember me')),
            Checkbox(value: true, onChanged: null),
          ]),
        ),
        InkWell(
          onTap: () {},
          child: Column(children: [
            const Text('Promo card'),
            Checkbox(
                key: const ValueKey('live'), value: true, onChanged: (_) {}),
          ]),
        ),
      ])));
      final all = nodes();
      expect(_node(all, 'Remember me')['selected'], isTrue);
      expect(_node(all, 'Promo card').containsKey('selected'), isFalse);
      expect(all.singleWhere((n) => n['key'] == 'live')['selected'], isTrue);
    });

    testWidgets('a section-wide Semantics(selected:) describes none of the '
        'controls inside it', (tester) async {
      await tester.pumpWidget(_app(Semantics(
        selected: true,
        child: Column(children: [
          FilledButton(onPressed: () {}, child: const Text('One')),
          FilledButton(onPressed: () {}, child: const Text('Two')),
        ]),
      )));
      final all = nodes();
      expect(_node(all, 'One').containsKey('selected'), isFalse);
      expect(_node(all, 'Two').containsKey('selected'), isFalse);
    });

    testWidgets('a page-wide detector takes no state from the tabs under it',
        (tester) async {
      final tabs = TabController(length: 2, vsync: tester);
      addTearDown(tabs.dispose);
      await tester.pumpWidget(GestureDetector(
        key: const ValueKey('page'),
        onTap: () {},
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              bottom: TabBar(controller: tabs, tabs: const [
                Tab(text: 'A'),
                Tab(text: 'B'),
              ]),
            ),
            body: const SizedBox.expand(),
          ),
        ),
      ));
      final all = nodes();
      expect(all.singleWhere((n) => n['key'] == 'page').containsKey('selected'),
          isFalse);
      expect(_node(all, 'A')['selected'], isTrue);
    });

    testWidgets('a plain button has neither field', (tester) async {
      await tester.pumpWidget(_app(FilledButton(
        onPressed: () {},
        child: const Text('Log in'),
      )));
      final node = _node(nodes(), 'Log in');
      expect(node['enabled'], isTrue);
      expect(node.containsKey('selected'), isFalse);
      expect(node.containsKey('mixed'), isFalse);
    });
  });
}
