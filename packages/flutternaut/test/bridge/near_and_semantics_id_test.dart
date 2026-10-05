import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/models/action_failure.dart';

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

/// Runs a dispatcher call to completion under fake time (see the same
/// helper in gesture_dispatcher_test.dart).
Future<T> _pumpAndAwait<T>(
  WidgetTester tester,
  Future<T> Function() work,
) async {
  final completer = Completer<T>();
  work().then(completer.complete, onError: completer.completeError);
  for (var i = 0; i < 200 && !completer.isCompleted; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return completer.future;
}

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

/// An SVG-like icon button: a tap surface over a painted box, with no
/// text, no `Icon` and no key — the BEANZ nav button's shape.
Widget _svgButton(VoidCallback onTap, {double size = 62, Key? key}) =>
    GestureDetector(
      key: key,
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: const ColoredBox(color: Colors.blue),
      ),
    );

void main() {
  final walker = TreeWalker();
  late GestureDispatcher dispatcher;
  setUp(() => dispatcher = GestureDispatcher(walker));

  List<Map<String, dynamic>> nodes() =>
      _flatten(walker.dumpVisibleTree()['elements'] as List);

  Element anchor(String text) => walker.findOnScreenElementsByText(text).single;

  group('near searches through containers', () {
    /// A page whose bottom bar holds the anchor text and an unlabeled
    /// SVG-like button, under a root-level detector built by [wrap].
    Widget navPage(Widget Function(Widget app) wrap, VoidCallback onSearch) =>
        wrap(MaterialApp(
          home: Scaffold(
            body: const Center(child: Text('Home page')),
            bottomNavigationBar: SizedBox(
              height: 62,
              child: Row(children: [
                const Expanded(child: Text('Profile')),
                _svgButton(onSearch),
              ]),
            ),
          ),
        ));

    testWidgets(
        'a full-screen tap wrapper over the app is not a candidate and '
        'does not hide the controls inside it', (tester) async {
      var searched = 0;
      await tester.pumpWidget(navPage(
        (app) => GestureDetector(onTap: () {}, child: app),
        () => searched++,
      ));

      final near = walker.unlabeledInteractiveNear(anchor('Profile'));
      expect(near, hasLength(1));
      expect(near.single.widget, isA<GestureDetector>());
      expect(
        (near.single.widget as GestureDetector).child,
        isA<SizedBox>(),
        reason: 'the candidate is the nav button, not the page wrapper',
      );

      await _pumpAndAwait(tester, () => dispatcher.tapNear('Profile', 0));
      expect(searched, 1);
    });

    testWidgets(
        'a root long-press-only layer (requests_inspector) does not hide '
        'the controls inside it', (tester) async {
      var searched = 0;
      await tester.pumpWidget(navPage(
        (app) => GestureDetector(onLongPress: () {}, child: app),
        () => searched++,
      ));

      final near = walker.unlabeledInteractiveNear(anchor('Profile'));
      expect(near, hasLength(1));
      expect((near.single.widget as GestureDetector).child, isA<SizedBox>());

      await _pumpAndAwait(tester, () => dispatcher.tapNear('Profile', 0));
      expect(searched, 1);
    });

    testWidgets('both layers stacked still leave exactly the nav button',
        (tester) async {
      await tester.pumpWidget(navPage(
        (app) => GestureDetector(
          onLongPress: () {},
          child: GestureDetector(onTap: () {}, child: app),
        ),
        () {},
      ));

      final near = walker.unlabeledInteractiveNear(anchor('Profile'));
      expect(near, hasLength(1));
      expect((near.single.widget as GestureDetector).child, isA<SizedBox>());
    });

    testWidgets('an IconButton and its inner InkWell count once',
        (tester) async {
      await tester.pumpWidget(_app(SizedBox(
        height: 56,
        child: Row(children: [
          const Expanded(child: Text('Basket')),
          IconButton(icon: const Icon(Icons.delete), onPressed: () {}),
        ]),
      )));

      final near = walker.unlabeledInteractiveNear(anchor('Basket'));
      expect(near, hasLength(1));
      expect(near.single.widget, isA<IconButton>());
    });

    testWidgets(
        'a tile labelled by its text is searched through: its trailing '
        'control is the candidate, the tile is not', (tester) async {
      var trailing = 0;
      var tile = 0;
      await tester.pumpWidget(_app(InkWell(
        onTap: () => tile++,
        child: SizedBox(
          height: 64,
          child: Row(children: [
            const Expanded(child: Text('Latte')),
            _svgButton(() => trailing++, size: 40),
          ]),
        ),
      )));

      final near = walker.unlabeledInteractiveNear(anchor('Latte'));
      expect(near, hasLength(1));
      expect(near.single.widget, isA<GestureDetector>());
      expect((near.single.widget as GestureDetector).child, isA<SizedBox>());

      await _pumpAndAwait(tester, () => dispatcher.tapNear('Latte', 0));
      expect(trailing, 1);
      expect(tile, 0);
    });

    testWidgets('a short unlabeled wrapper is still one candidate',
        (tester) async {
      // Below half the screen tall and with no text inside, a wrapper is a
      // control: its inner detector is not counted again.
      await tester.pumpWidget(_app(SizedBox(
        height: 56,
        child: Row(children: [
          const Expanded(child: Text('Row title')),
          GestureDetector(onTap: () {}, child: _svgButton(() {}, size: 40)),
        ]),
      )));

      final near = walker.unlabeledInteractiveNear(anchor('Row title'));
      expect(near, hasLength(1));
      expect((near.single.widget as GestureDetector).child,
          isA<GestureDetector>());
    });
  });

  group('Semantics identifier', () {
    test('ownSemanticsIdOf reads a trimmed, non-empty identifier', () {
      expect(
        TreeWalker.ownSemanticsIdOf(
            Semantics(identifier: ' btn:nav:search ', child: const SizedBox())),
        'btn:nav:search',
      );
      expect(
        TreeWalker.ownSemanticsIdOf(
            Semantics(identifier: '   ', child: const SizedBox())),
        isNull,
      );
      expect(
        TreeWalker.ownSemanticsIdOf(
            Semantics(label: 'Search', child: const SizedBox())),
        isNull,
      );
      expect(TreeWalker.ownSemanticsIdOf(const SizedBox()), isNull);
    });

    /// A bottom bar: a MergeSemantics-wrapped search button, a plain
    /// identified cart button, and a section identifier around two
    /// controls of other sizes.
    Widget bar(List<String> taps) => _app(Column(children: [
          MergeSemantics(
            child: Semantics(
              identifier: 'btn:nav:search',
              button: true,
              child: _svgButton(() => taps.add('search')),
            ),
          ),
          Semantics(
            identifier: 'btn:nav:cart',
            child: GestureDetector(
              onTap: () => taps.add('cart'),
              child: const Icon(Icons.shopping_bag),
            ),
          ),
          Semantics(
            identifier: 'section:nav:bar',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _svgButton(() => taps.add('a'),
                  size: 40, key: const ValueKey('a')),
              _svgButton(() => taps.add('b'),
                  size: 50, key: const ValueKey('b')),
            ]),
          ),
          Semantics(
            label: 'Close',
            child: _svgButton(() => taps.add('close'), size: 30),
          ),
        ]));

    testWidgets(
        'a control a Semantics wraps exactly carries semantics_id; '
        'controls inside a section do not', (tester) async {
      await tester.pumpWidget(bar([]));
      final all = nodes();

      final search =
          all.where((n) => n['semantics_id'] == 'btn:nav:search').toList();
      expect(search.map((n) => n['type']), ['GestureDetector']);

      final cart = all.where((n) => n['semantics_id'] == 'btn:nav:cart');
      expect(cart.map((n) => n['type']), ['GestureDetector'],
          reason: 'the Icon inside the control does not take the id');

      for (final key in ['a', 'b']) {
        final node = all.firstWhere((n) => n['key'] == key);
        expect(node.containsKey('semantics_id'), isFalse, reason: key);
      }
      expect(all.any((n) => n['semantics_id'] == 'section:nav:bar'), isFalse);
      expect(all.any((n) => n.containsKey('semantics_id_nth')), isFalse,
          reason: 'a unique identifier carries no nth');
    });

    testWidgets('a semantics locator taps the control an identifier wraps',
        (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(bar(taps));

      await _pumpAndAwait(
        tester,
        () => dispatcher.tap(semantics: 'btn:nav:search'),
      );
      expect(taps, ['search']);

      await _pumpAndAwait(
        tester,
        () => dispatcher.tap(semantics: 'BTN:NAV:CART'),
      );
      expect(taps, ['search', 'cart']);

      await _pumpAndAwait(tester, () => dispatcher.tap(semantics: 'Close'));
      expect(taps, ['search', 'cart', 'close']);
    });

    testWidgets('an identifier is visible and found like a label',
        (tester) async {
      await tester.pumpWidget(bar([]));
      expect(walker.checkVisibleBySemantics('btn:nav:search').visible, isTrue);
      expect(walker.findBySemantics('btn:nav:search')?.type, 'Semantics');
      expect(walker.findBySemantics('Btn:Nav:Search')?.type, 'Semantics');
      expect(walker.findBySemantics('btn:nav:missing'), isNull);
    });

    testWidgets('an unknown target fails with the not-found error',
        (tester) async {
      await tester.pumpWidget(bar([]));
      await expectLater(
        dispatcher.tap(semantics: 'btn:nav:missing'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          contains('No element found matching semantics "btn:nav:missing"'),
        )),
      );
    });

    testWidgets(
        'a repeated identifier carries semantics_id_nth, and that nth taps '
        'the control the dump named', (tester) async {
      final taps = <int>[];
      await tester.pumpWidget(_app(Column(children: [
        for (var i = 0; i < 2; i++)
          Semantics(
            identifier: 'btn:add',
            child: _svgButton(() => taps.add(i), size: 48),
          ),
      ])));

      final added =
          nodes().where((n) => n['semantics_id'] == 'btn:add').toList();
      expect(added.map((n) => n['semantics_id_nth']), [0, 1]);
      expect(added.map((n) => n['semantics_id_matches']), [2, 2]);

      await _pumpAndAwait(
        tester,
        () => dispatcher.tap(
          semantics: 'btn:add',
          nth: added[1]['semantics_id_nth'] as int,
        ),
      );
      expect(taps, [1]);

      await expectLater(
        dispatcher.tap(semantics: 'btn:add'),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('Ambiguous'))),
      );
    });

    testWidgets('a state assertion by identifier answers for the control',
        (tester) async {
      await tester.pumpWidget(_app(Semantics(
        identifier: 'btn:save',
        child: const ElevatedButton(onPressed: null, child: Text('Save')),
      )));

      final target = walker.resolveStateTarget(semantics: 'btn:save');
      expect(
        target,
        isA<StateFound>()
            .having((t) => t.enabled, 'enabled', isFalse)
            .having((t) => t.control.widget, 'control', isA<ElevatedButton>()),
      );
    });
  });
}
