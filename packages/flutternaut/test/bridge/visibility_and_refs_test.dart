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

void main() {
  final walker = TreeWalker();
  late GestureDispatcher dispatcher;
  setUp(() => dispatcher = GestureDispatcher(walker));

  List<Map<String, dynamic>> nodes() =>
      _flatten(walker.dumpVisibleTree()['elements'] as List);

  group('visibility checks use the dump\'s rules', () {
    testWidgets('a widget at opacity 0 is not visible, and says why',
        (tester) async {
      await tester.pumpWidget(_app(const Center(
        child: Opacity(opacity: 0, child: Text('up for it')),
      )));

      final result = walker.checkTextVisible('up for it');
      expect(result.exists, isTrue);
      expect(result.visible, isFalse);
      expect(result.reason, contains('opacity 0.00'));
    });

    testWidgets('a hidden first match does not mask a visible duplicate',
        (tester) async {
      await tester.pumpWidget(_app(const Column(children: [
        Offstage(child: Text('Check in')),
        Text('Check in'),
      ])));

      expect(walker.checkTextVisible('Check in').visible, isTrue);
    });

    testWidgets('nth picks the nth visible match; out of range says so',
        (tester) async {
      await tester.pumpWidget(_app(const Column(children: [
        Text('Row'),
        Opacity(opacity: 0, child: Text('Row')),
        Text('Row'),
      ])));

      expect(walker.checkTextVisible('Row', nth: 0).visible, isTrue);
      expect(walker.checkTextVisible('Row', nth: 1).visible, isTrue);
      final out = walker.checkTextVisible('Row', nth: 2);
      expect(out.visible, isFalse);
      expect(out.reason, contains('2 visible match(es)'));
    });

    testWidgets('no match reports that nothing matches', (tester) async {
      await tester.pumpWidget(_app(const Text('here')));
      final result = walker.checkTextVisible('absent');
      expect(result.exists, isFalse);
      expect(result.reason, contains('no widget matches'));
    });
  });

  group('text normalisation (dump == finder)', () {
    testWidgets(
        'a label with surrounding whitespace is found by its '
        'trimmed text, which is what the dump reports', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(Center(
        child: ElevatedButton(
          onPressed: () => tapped = true,
          child: const Text(' Check In \n'),
        ),
      )));

      final button = nodes().firstWhere((n) => n['type'] == 'ElevatedButton');
      expect(button['text'], 'Check In');
      expect(walker.findByText('Check In'), isNotNull);

      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Check In'));
      expect(tapped, isTrue);
    });

    testWidgets(
        'an inline WidgetSpan (typing cursor) is left out of the '
        'text instead of showing as U+FFFC', (tester) async {
      await tester.pumpWidget(_app(const Center(
        child: Text.rich(TextSpan(children: [
          TextSpan(text: 'pspsps… '),
          WidgetSpan(child: SizedBox(width: 2, height: 14)),
          TextSpan(text: ' Test need'),
        ])),
      )));

      final texts = nodes().map((n) => n['text']).whereType<String>();
      expect(texts, contains('pspsps… Test need'));
      expect(texts.any((t) => t.contains('￼')), isFalse);
      expect(walker.checkTextVisible('pspsps… Test need').visible, isTrue);
    });

    test('normalizeText strips placeholders and trims', () {
      expect(TreeWalker.normalizeText('  a ￼ b  '), 'a b');
      expect(TreeWalker.normalizeText('￼cursor'), 'cursor');
      expect(TreeWalker.normalizeText(' plain '), 'plain');
    });
  });

  group('refs never become ambiguous', () {
    testWidgets(
        'two stacked glyph layers inside one nav item are one '
        'control: a text tap needs no nth', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(Align(
        alignment: Alignment.bottomCenter,
        child: InkWell(
          onTap: () => taps++,
          child: const SizedBox(
            width: 80,
            height: 56,
            child: Stack(alignment: Alignment.center, children: [
              Text('Home'),
              Text('Home'), // the selected-state layer on top
            ]),
          ),
        ),
      )));

      expect(
        walker.actableMatches(walker.findAllElementsByText('Home')),
        hasLength(1),
      );
      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Home'));
      expect(taps, 1);
    });

    testWidgets(
        'two separate labels under one page-wide GestureDetector '
        'stay two matches', (tester) async {
      await tester.pumpWidget(_app(GestureDetector(
        onTap: () {},
        child: const Column(children: [Text('Price'), Text('Price')]),
      )));

      expect(
        walker.actableMatches(walker.findAllElementsByText('Price')),
        hasLength(2),
      );
    });

    testWidgets(
        'duplicate rows carry text_nth, and that nth taps the row '
        'the dump named', (tester) async {
      final tapped = <int>[];
      await tester.pumpWidget(_app(Column(children: [
        for (var i = 0; i < 2; i++)
          TextButton(
            onPressed: () => tapped.add(i),
            child: const Text("Who's Around"),
          ),
      ])));

      final rows = nodes().where((n) => n['type'] == 'TextButton').toList();
      expect(rows.map((n) => n['text_nth']), [0, 1]);
      expect(rows.map((n) => n['text_matches']), [2, 2]);

      await _pumpAndAwait(
        tester,
        () => dispatcher.tap(
            text: "Who's Around", nth: rows[1]['text_nth'] as int),
      );
      expect(tapped, [1]);
    });

    testWidgets('a unique label carries no text_nth', (tester) async {
      await tester.pumpWidget(_app(TextButton(
        onPressed: () {},
        child: const Text('Only'),
      )));
      final button = nodes().firstWhere((n) => n['type'] == 'TextButton');
      expect(button.containsKey('text_nth'), isFalse);
    });
  });

  group('widgets behind a modal route', () {
    testWidgets(
        'a bottom sheet hides the page beneath from the dump and '
        'from visibility checks', (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Center(child: Text('status form'))),
      ));
      showModalBottomSheet<void>(
        context: navKey.currentContext!,
        builder: (_) => const SizedBox(
          height: 120,
          child: Center(child: Text('What is Marduk?')),
        ),
      );
      await tester.pumpAndSettle();

      final texts = nodes().map((n) => n['text']).toSet();
      expect(texts, contains('What is Marduk?'));
      expect(texts, isNot(contains('status form')));

      final under = walker.checkTextVisible('status form');
      expect(under.visible, isFalse);
      expect(under.reason, contains('hidden behind'));
    });

    testWidgets(
        'a closing sheet\'s rows leave the dump as soon as it starts '
        'to close', (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Center(child: Text('page'))),
      ));
      showModalBottomSheet<void>(
        context: navKey.currentContext!,
        builder: (_) => const SizedBox(
          height: 120,
          child: Center(child: Text('sheet row')),
        ),
      );
      await tester.pumpAndSettle();

      navKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final texts = nodes().map((n) => n['text']).toSet();
      expect(texts, isNot(contains('sheet row')));
      expect(texts, contains('page'));
    });
  });

  group('occlusion sampling', () {
    testWidgets(
        'an open drawer hides the page labels under it, even where '
        'its own text (a TextSpan hit target) is frontmost', (tester) async {
      final key = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          key: key,
          drawer: Drawer(
            child: ListView(children: [
              const DrawerHeader(child: Text('Menu')),
              ListTile(
                leading: const Icon(Icons.pin),
                title: const Text('Enter code'),
                onTap: () {},
              ),
            ]),
          ),
          body: Column(children: [
            const SizedBox(height: 180),
            TextButton(onPressed: () {}, child: const Text('Sort')),
          ]),
        ),
      ));
      key.currentState!.openDrawer();
      await tester.pumpAndSettle();

      final result = walker.checkTextVisible('Sort');
      expect(result.visible, isFalse);
      expect(result.reason, contains('covered by'));
      expect(nodes().map((n) => n['text']), isNot(contains('Sort')));
    });

    testWidgets('a transparent tap layer over a tile does not hide its text',
        (tester) async {
      await tester.pumpWidget(_app(Center(
        child: SizedBox(
          width: 200,
          height: 80,
          child: Stack(children: [
            const Center(child: Text('See who\'s around')),
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: () {}),
              ),
            ),
          ]),
        ),
      )));

      expect(nodes().map((n) => n['text']), contains('See who\'s around'));
      expect(walker.checkTextVisible('See who\'s around').visible, isTrue);
    });

    testWidgets(
        'a painted badge over part of a label keeps it, marked '
        'partial', (tester) async {
      await tester.pumpWidget(_app(Center(
        child: SizedBox(
          width: 200,
          height: 40,
          child: Stack(children: [
            const Positioned.fill(
              child: Text('Check in', key: ValueKey('label')),
            ),
            Positioned(
              left: 0,
              top: 0,
              width: 70,
              height: 20,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: const ColoredBox(color: Color(0xFFFF0000)),
              ),
            ),
          ]),
        ),
      )));

      final label = nodes().firstWhere((n) => n['key'] == 'label');
      expect(label['partial'], isTrue);
    });
  });

  group('tap_at', () {
    testWidgets('taps the control at a point and names it', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(Center(
        child: ElevatedButton(
          onPressed: () => tapped = true,
          child: const Text('Explore Nearby'),
        ),
      )));
      final center = tester.getCenter(find.byType(ElevatedButton));

      final hit = await _pumpAndAwait(tester, () => dispatcher.tapAt(center));
      expect(tapped, isTrue);
      expect(hit, contains('Explore Nearby'));
    });

    testWidgets('a point off the screen fails loudly', (tester) async {
      await tester.pumpWidget(_app(const Text('x')));
      await expectLater(
        dispatcher.tapAt(const Offset(-5, 10000)),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          contains('outside the screen'),
        )),
      );
    });

    testWidgets(
        'a point where no widget receives pointers fails and points '
        'at wait_idle', (tester) async {
      // Nothing hit-testable: the pointer would reach only the RenderView,
      // exactly as it does while every route ignores pointers.
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.expand(),
      ));

      await expectLater(
        dispatcher.tapAt(const Offset(200, 300)),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          contains('wait_idle'),
        )),
      );
    });
  });

  group('layers that swallow the pointer (AbsorbPointer)', () {
    // A splash held over a page that is already built underneath — the
    // Beanz onboarding pattern. AbsorbPointer takes the pointer without
    // joining the hit path, so the frontmost recorded hit is the Stack: an
    // ancestor of the label. That must not read as "nothing on top".
    Widget splashOver(Widget page, {required bool held}) => _app(Stack(
          fit: StackFit.expand,
          children: [
            page,
            if (held)
              const Positioned.fill(
                child: AbsorbPointer(
                  child: ColoredBox(color: Color(0xFF6FA8DC)),
                ),
              ),
          ],
        ));

    testWidgets('a painted splash in an AbsorbPointer hides the page under it',
        (tester) async {
      await tester.pumpWidget(
        splashOver(const Center(child: Text('Continue')), held: true),
      );

      final result = walker.checkTextVisible('Continue');
      expect(result.visible, isFalse);
      expect(result.reason, contains('covered by AbsorbPointer(ColoredBox)'));
      expect(nodes().map((n) => n['text']), isNot(contains('Continue')));

      await tester.pumpWidget(
        splashOver(const Center(child: Text('Continue')), held: false),
      );
      expect(walker.checkTextVisible('Continue').visible, isTrue);
      expect(nodes().map((n) => n['text']), contains('Continue'));
    });

    testWidgets('a transparent AbsorbPointer over a label hides nothing',
        (tester) async {
      await tester.pumpWidget(_app(const Stack(children: [
        Center(child: Text('Behind glass')),
        Positioned.fill(child: AbsorbPointer(child: SizedBox.expand())),
      ])));

      expect(walker.checkTextVisible('Behind glass').visible, isTrue);
    });

    testWidgets('an AbsorbPointer wrapping the label hides nothing',
        (tester) async {
      await tester.pumpWidget(_app(const Center(
        child: AbsorbPointer(child: Text('Busy form')),
      )));

      expect(walker.checkTextVisible('Busy form').visible, isTrue);
    });

    testWidgets('a faded-out absorbing cover hides nothing', (tester) async {
      await tester.pumpWidget(_app(const Stack(children: [
        Center(child: Text('Revealed')),
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: AbsorbPointer(child: ColoredBox(color: Color(0xFF000000))),
          ),
        ),
      ])));

      expect(walker.checkTextVisible('Revealed').visible, isTrue);
    });

    testWidgets('an absorbing cover painted elsewhere does not hide a label',
        (tester) async {
      // A full-screen absorber whose only paint is a small badge in a
      // corner: the label's pixels are not painted over.
      await tester.pumpWidget(_app(const Stack(children: [
        Center(child: Text('Mid screen')),
        Positioned.fill(
          child: AbsorbPointer(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 20,
                height: 20,
                child: ColoredBox(color: Color(0xFF000000)),
              ),
            ),
          ),
        ),
      ])));

      expect(walker.checkTextVisible('Mid screen').visible, isTrue);
    });
  });

  group('an empty field under its hint', () {
    testWidgets('the hint of an empty field is visible; typed text hides it',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(Center(
        child: SizedBox(
          width: 300,
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'Search'),
          ),
        ),
      )));

      expect(walker.checkTextVisible('Search').visible, isTrue);

      controller.text = 'latte';
      await tester.pump();
      expect(walker.checkTextVisible('Search').visible, isFalse);
    });
  });

  group('tap_at on a layer that swallows the pointer', () {
    testWidgets('a point on an AbsorbPointer splash fails loudly',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(Stack(fit: StackFit.expand, children: [
        Center(
          child: ElevatedButton(
            onPressed: () => tapped = true,
            child: const Text('Continue'),
          ),
        ),
        const Positioned.fill(
          child: AbsorbPointer(child: ColoredBox(color: Color(0xFF6FA8DC))),
        ),
      ])));
      final center = tester.getCenter(find.byType(ElevatedButton));

      await expectLater(
        dispatcher.tapAt(center),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('swallowed'), contains('AbsorbPointer(ColoredBox)')),
        )),
      );
      expect(tapped, isFalse);
    });

    testWidgets('a field wrapped by its tap handler is tapped', (tester) async {
      // The date-picker idiom: InkWell(child: AbsorbPointer(field)). The
      // absorber exists so the handler around it gets the tap.
      var opened = false;
      await tester.pumpWidget(_app(Center(
        child: SizedBox(
          width: 300,
          child: InkWell(
            onTap: () => opened = true,
            child: const AbsorbPointer(
              child: TextField(
                decoration: InputDecoration(hintText: 'dd/mm/yyyy'),
              ),
            ),
          ),
        ),
      )));
      final center = tester.getCenter(find.byType(TextField));

      final hit = await _pumpAndAwait(tester, () => dispatcher.tapAt(center));
      expect(opened, isTrue);
      // An InkWell is named by the GestureDetector it builds on.
      expect(hit, contains('GestureDetector'));
    });
  });
}
