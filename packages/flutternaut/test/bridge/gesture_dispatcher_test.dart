import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/models/action_failure.dart';

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

/// Starts [work] without awaiting it, pumps frames at a fixed cadence
/// until it completes, then returns the result.
///
/// `dispatcher.*` methods internally await
/// `WidgetsBinding.instance.endOfFrame` AND `Future.delayed(...)`. The
/// former only resolves when the test pumps; the latter uses fake time.
/// A simple `pumpAndSettle` returns as soon as frames are idle, which
/// leaves pending fake-time delays unresolved. Pumping at a fixed
/// cadence advances fake time in steps that drain both.
Future<T> _pumpAndAwait<T>(
  WidgetTester tester,
  Future<T> Function() work,
) async {
  final completer = Completer<T>();
  work().then(completer.complete, onError: completer.completeError);
  const step = Duration(milliseconds: 50);
  const maxSteps = 200; // 10s of fake time — generous cap
  for (var i = 0; i < maxSteps && !completer.isCompleted; i++) {
    await tester.pump(step);
  }
  return completer.future;
}

void main() {
  late GestureDispatcher dispatcher;

  setUp(() {
    dispatcher = GestureDispatcher(TreeWalker());
  });

  group('tap', () {
    testWidgets('triggers onPressed via ValueKey', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(
        ElevatedButton(
          key: const ValueKey('btn'),
          onPressed: () => tapped = true,
          child: const Text('Tap'),
        ),
      ));

      final ok = await _pumpAndAwait(tester, () => dispatcher.tap(key: 'btn'));

      expect(ok, isTrue);
      expect(tapped, isTrue);
    });

    testWidgets('triggers onPressed via text content', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(
        ElevatedButton(
          onPressed: () => tapped = true,
          child: const Text('Sign In'),
        ),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.tap(text: 'Sign In'),
      );

      expect(ok, isTrue);
      expect(tapped, isTrue);
    });

    testWidgets('taps a Text.rich label by its full text', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(
        GestureDetector(
          onTap: () => tapped = true,
          child: const Text.rich(TextSpan(children: [
            TextSpan(text: 'Sign in '),
            TextSpan(text: 'to continue'),
          ])),
        ),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.tap(text: 'Sign in to continue'),
      );

      expect(ok, isTrue);
      expect(tapped, isTrue);
    });

    testWidgets('taps a rich label by a substring (contains)',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(
        GestureDetector(
          onTap: () => tapped = true,
          child: const Text.rich(TextSpan(children: [
            TextSpan(text: 'Already? '),
            TextSpan(text: 'Log in'),
          ])),
        ),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.tapByTextContains('Log in'),
      );

      expect(ok, isTrue);
      expect(tapped, isTrue);
    });

    testWidgets('throws ActionFailure for missing element', (tester) async {
      await tester.pumpWidget(_app(const Text('Hello')));

      await expectLater(
        dispatcher.tap(key: 'nonexistent'),
        throwsA(isA<ActionFailure>()),
      );
    });
  });

  group('typeText', () {
    testWidgets('enters text into keyed TextField', (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(_app(
        TextField(key: const ValueKey('field'), controller: controller),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(key: 'field', input: 'hello'),
      );

      expect(ok, isTrue);
      expect(controller.text, 'hello');
    });

    testWidgets('clear: true replaces existing content', (tester) async {
      final controller = TextEditingController(text: 'old');
      await tester.pumpWidget(_app(
        TextField(key: const ValueKey('field'), controller: controller),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(key: 'field', input: 'new', clear: true),
      );

      expect(controller.text, 'new');
    });

    testWidgets('clear: false appends to existing content', (tester) async {
      final controller = TextEditingController(text: 'abc');
      await tester.pumpWidget(_app(
        TextField(key: const ValueKey('field'), controller: controller),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(key: 'field', input: 'xyz'),
      );

      expect(controller.text, 'abcxyz');
    });
  });

  group('clearText', () {
    testWidgets('empties the keyed TextField', (tester) async {
      final controller = TextEditingController(text: 'filled');
      await tester.pumpWidget(_app(
        TextField(key: const ValueKey('field'), controller: controller),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.clearText(key: 'field'),
      );

      expect(ok, isTrue);
      expect(controller.text, isEmpty);
    });
  });

  group('typeText by sibling label', () {
    testWidgets('writes into the field below the label, not the '
        'currently-focused field', (tester) async {
      final firstName = TextEditingController();
      final phone = TextEditingController();
      final phoneFocus = FocusNode();

      await tester.pumpWidget(_app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('First name'),
            TextField(controller: firstName),
            const SizedBox(height: 24),
            const Text('Phone number'),
            TextField(controller: phone, focusNode: phoneFocus),
          ],
        ),
      ));

      // Focus First name first (simulates a prior step).
      await tester.tap(find.byType(TextField).first);
      await tester.pump();

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(text: 'Phone number', input: '123'),
      );

      expect(ok, isTrue);
      expect(phone.text, '123');
      expect(firstName.text, isEmpty,
          reason: 'must not type into the stale-focused field');
    });

    testWidgets('two-column row resolves each label to its own field',
        (tester) async {
      final first = TextEditingController();
      final last = TextEditingController();

      await tester.pumpWidget(_app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Expanded(child: Text('First name')),
                Expanded(child: Text('Last name')),
              ],
            ),
            Row(
              children: [
                Expanded(child: TextField(controller: first)),
                Expanded(child: TextField(controller: last)),
              ],
            ),
          ],
        ),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(text: 'First name', input: 'khaled'),
      );
      await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(text: 'Last name', input: 'shafeey'),
      );

      expect(first.text, 'khaled');
      expect(last.text, 'shafeey');
    });

    testWidgets('InputDecoration.labelText still resolves (no regression)',
        (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(_app(
        TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(text: 'Email', input: 'a@b.c'),
      );

      expect(ok, isTrue);
      expect(controller.text, 'a@b.c');
    });

    testWidgets('throws ActionFailure when no field can be associated',
        (tester) async {
      await tester.pumpWidget(_app(
        const Column(children: [Text('Lonely label')]),
      ));

      await expectLater(
        dispatcher.typeText(text: 'Lonely label', input: 'x'),
        throwsA(isA<ActionFailure>()),
      );
    });
  });

  group('typeText input pipeline', () {
    testWidgets('fires TextField.onChanged (key path)', (tester) async {
      final controller = TextEditingController();
      final changes = <String>[];
      await tester.pumpWidget(_app(
        TextField(
          key: const ValueKey('field'),
          controller: controller,
          onChanged: changes.add,
        ),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(key: 'field', input: 'hi', clear: true),
      );

      expect(ok, isTrue);
      expect(controller.text, 'hi');
      expect(changes.last, 'hi',
          reason: 'onChanged must fire, not just controller listeners');
    });

    testWidgets('fires onChanged when targeting by sibling label',
        (tester) async {
      final phone = TextEditingController();
      final changes = <String>[];
      await tester.pumpWidget(_app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Phone number'),
            TextField(controller: phone, onChanged: changes.add),
          ],
        ),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(text: 'Phone number', input: '0791'),
      );

      expect(phone.text, '0791');
      expect(changes.last, '0791');
    });

    testWidgets('clearText fires onChanged with empty string',
        (tester) async {
      final controller = TextEditingController(text: 'preset');
      final changes = <String>[];
      await tester.pumpWidget(_app(
        TextField(
          key: const ValueKey('field'),
          controller: controller,
          onChanged: changes.add,
        ),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.clearText(key: 'field'),
      );

      expect(controller.text, isEmpty);
      expect(changes.last, isEmpty);
    });

    testWidgets('applies inputFormatters (digitsOnly)', (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(_app(
        TextField(
          key: const ValueKey('field'),
          controller: controller,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(key: 'field', input: 'a1b2c3', clear: true),
      );

      expect(controller.text, '123',
          reason: 'formatters must run, proving the input pipeline is used');
    });
  });

  group('longPress', () {
    testWidgets('triggers onLongPress', (tester) async {
      var longPressed = false;
      await tester.pumpWidget(_app(
        GestureDetector(
          key: const ValueKey('target'),
          onLongPress: () => longPressed = true,
          child: Container(
            width: 100,
            height: 100,
            color: Colors.red,
          ),
        ),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.longPress(
          key: 'target',
          duration: const Duration(milliseconds: 700),
        ),
      );

      expect(longPressed, isTrue);
    });
  });

  group('multiTap', () {
    testWidgets('dispatches N taps', (tester) async {
      var tapCount = 0;
      await tester.pumpWidget(_app(
        GestureDetector(
          key: const ValueKey('target'),
          onTap: () => tapCount++,
          child: Container(width: 100, height: 100, color: Colors.red),
        ),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.multiTap(key: 'target', count: 3, intervalMs: 10),
      );

      expect(tapCount, 3);
    });
  });

  group('missing element', () {
    testWidgets('scroll returns false', (tester) async {
      await tester.pumpWidget(_app(const Text('Hi')));
      final ok = await dispatcher.scroll(key: 'missing', dx: 0, dy: 100);
      expect(ok, isFalse);
    });

    testWidgets('typeText throws ActionFailure', (tester) async {
      await tester.pumpWidget(_app(const Text('Hi')));
      await expectLater(
        dispatcher.typeText(key: 'missing', input: 'x'),
        throwsA(isA<ActionFailure>()),
      );
    });

    testWidgets('longPress returns false', (tester) async {
      await tester.pumpWidget(_app(const Text('Hi')));
      final ok = await dispatcher.longPress(key: 'missing');
      expect(ok, isFalse);
    });
  });

  group('hit-test gate (fail loudly, never falsely)', () {
    testWidgets('throws when the target is occluded by an opaque overlay',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(
        Stack(
          children: [
            ElevatedButton(
              key: const ValueKey('buried'),
              onPressed: () => tapped = true,
              child: const Text('Buried'),
            ),
            // A full-screen opaque layer painted on top that absorbs the
            // pointer before it can reach the button below.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ));

      await expectLater(
        dispatcher.tap(key: 'buried'),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('occluded'))),
      );
      expect(tapped, isFalse, reason: 'occluded button must not fire');
    });

    testWidgets('throws on an ambiguous locator with multiple visible matches',
        (tester) async {
      await tester.pumpWidget(_app(
        Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(onTap: () {}, child: const Text('Dup')),
            GestureDetector(onTap: () {}, child: const Text('Dup')),
          ],
        ),
      ));

      await expectLater(
        dispatcher.tap(text: 'Dup'),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('Ambiguous'))),
      );
    });

    testWidgets('scrolls a built-but-off-screen target into view, then taps',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(
        SingleChildScrollView(
          child: Column(
            children: [
              for (var i = 0; i < 20; i++) const SizedBox(height: 100),
              ElevatedButton(
                key: const ValueKey('deep'),
                onPressed: () => tapped = true,
                child: const Text('Deep'),
              ),
            ],
          ),
        ),
      ));

      // The button is laid out far below the fold (≈2000px) — off-screen
      // but built, so ensureVisible can bring it into view.
      final ok = await _pumpAndAwait(tester, () => dispatcher.tap(key: 'deep'));

      expect(ok, isTrue);
      expect(tapped, isTrue);
    });

    testWidgets('taps a field by its hint text and focuses the field',
        (tester) async {
      // Regression: tapping a non-interactive label (the hint) that sits on
      // a TextField must reach the field (RenderEditable) and focus it —
      // not fail as "occluded". The hint is only a locator.
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(_app(
        TextField(
          focusNode: focusNode,
          decoration: const InputDecoration(hintText: 'dd/mm/yyyy'),
        ),
      ));

      final ok =
          await _pumpAndAwait(tester, () => dispatcher.tap(text: 'dd/mm/yyyy'));

      expect(ok, isTrue);
      expect(focusNode.hasFocus, isTrue,
          reason: 'tapping the hint should focus the field');
    });

    testWidgets('confirms a target reached via a descendant hit',
        (tester) async {
      // The key is on the outer GestureDetector; the pointer actually
      // lands on its inner Text descendant. The two-direction membership
      // test must still accept this as hitting the target.
      var tapped = false;
      await tester.pumpWidget(_app(
        GestureDetector(
          key: const ValueKey('outer'),
          behavior: HitTestBehavior.opaque,
          onTap: () => tapped = true,
          child: const Center(child: Text('inner')),
        ),
      ));

      final ok = await _pumpAndAwait(tester, () => dispatcher.tap(key: 'outer'));

      expect(ok, isTrue);
      expect(tapped, isTrue);
    });
  });

  group('auto-resolve scroll (no scroll target)', () {
    testWidgets('resolves the single on-screen vertical scrollable',
        (tester) async {
      await tester.pumpWidget(_app(
        ListView(
          children: [for (var i = 0; i < 30; i++) SizedBox(height: 80, child: Text('row $i'))],
        ),
      ));

      final ok =
          await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));

      expect(ok, isTrue);
    });

    testWidgets('axis filter picks the vertical list over a horizontal one',
        (tester) async {
      await tester.pumpWidget(_app(
        ListView(
          children: [
            SizedBox(
              height: 80,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < 30; i++)
                    SizedBox(width: 80, child: Text('col $i')),
                ],
              ),
            ),
            for (var i = 0; i < 30; i++) SizedBox(height: 80, child: Text('row $i')),
          ],
        ),
      ));

      // Only the outer (vertical) scrollable matches an up/down swipe.
      final ok =
          await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));

      expect(ok, isTrue);
    });

    testWidgets('throws when no scrollable is on screen', (tester) async {
      await tester.pumpWidget(_app(const Center(child: Text('static'))));

      await expectLater(
        dispatcher.swipeAuto('up', 300),
        throwsA(isA<ActionFailure>()),
      );
    });

    testWidgets('throws on ambiguous same-axis scrollables', (tester) async {
      await tester.pumpWidget(_app(
        Row(
          children: [
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(height: 60, child: Text('a$i')),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(height: 60, child: Text('b$i')),
                ],
              ),
            ),
          ],
        ),
      ));

      await expectLater(
        dispatcher.swipeAuto('up', 300),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('scroll target'))),
      );
    });

    testWidgets('real scroll builds and finds a lazy ListView.builder item',
        (tester) async {
      await tester.pumpWidget(_app(
        ListView.builder(
          itemCount: 60,
          itemBuilder: (_, i) => SizedBox(
            height: 60,
            child: Text('Item $i', key: ValueKey('item_$i')),
          ),
        ),
      ));

      // A far-down item is not built yet — ensureVisible could not reach it,
      // but real incremental scrolling builds it on demand.
      expect(dispatcher.walker.findByKey('item_40'), isNull);

      var found = false;
      for (var i = 0; i < 25 && !found; i++) {
        await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 400));
        found = dispatcher.walker.findByKey('item_40') != null;
      }

      expect(found, isTrue,
          reason: 'scrolling should build the lazy item into the tree');
    });
  });

  group('swipeAtIndex (indexed scrollable)', () {
    Widget twoRails(ScrollController first, ScrollController second) {
      return _app(
        Column(
          children: [
            SizedBox(
              height: 100,
              child: ListView(
                controller: first,
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(width: 80, child: Text('first $i')),
                ],
              ),
            ),
            SizedBox(
              height: 100,
              child: ListView(
                controller: second,
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(width: 80, child: Text('second $i')),
                ],
              ),
            ),
          ],
        ),
      );
    }

    testWidgets('scrolls exactly the indexed rail, not its same-axis sibling',
        (tester) async {
      final first = ScrollController();
      final second = ScrollController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(twoRails(first, second));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.swipeAtIndex(1, 'left', 300),
      );

      expect(ok, isTrue);
      expect(second.offset, greaterThan(0),
          reason: 'the indexed rail must scroll');
      expect(first.offset, 0,
          reason: 'the sibling rail must stay put');
    });

    testWidgets('index matches the dump\'s scrollIndex ordering',
        (tester) async {
      final first = ScrollController();
      final second = ScrollController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(twoRails(first, second));

      // The dump reports tree-order indexes; index 0 must be the first rail.
      await _pumpAndAwait(
        tester,
        () => dispatcher.swipeAtIndex(0, 'left', 300),
      );

      expect(first.offset, greaterThan(0));
      expect(second.offset, 0);
    });

    testWidgets('throws a loud out-of-range error with the visible count',
        (tester) async {
      final first = ScrollController();
      final second = ScrollController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(twoRails(first, second));

      await expectLater(
        dispatcher.swipeAtIndex(5, 'left', 300),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('out of range'))
            .having((e) => e.message, 'message', contains('2'))),
      );
    });

    testWidgets('throws on a negative index', (tester) async {
      final first = ScrollController();
      final second = ScrollController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(twoRails(first, second));

      await expectLater(
        dispatcher.swipeAtIndex(-1, 'left', 300),
        throwsA(isA<ActionFailure>()),
      );
    });
  });

  group('tapNear (row-anchored icon controls)', () {
    /// A wishlist-style row: title text + an icon-only delete button
    /// (GestureDetector wrapping an Icon — no key, no text).
    Widget itemRow(String title, VoidCallback onDelete) {
      return SizedBox(
        height: 56,
        child: Row(
          children: [
            Expanded(child: Text(title)),
            GestureDetector(
              onTap: onDelete,
              child: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      );
    }

    testWidgets('taps the delete button of the right row', (tester) async {
      final deleted = <String>[];
      await tester.pumpWidget(_app(
        Column(
          children: [
            for (final t in ['Item Title 9', 'Item Title 10', 'Item Title 11'])
              itemRow(t, () => deleted.add(t)),
          ],
        ),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.tapNear('Item Title 10', 0),
      );

      expect(ok, isTrue);
      expect(deleted, ['Item Title 10']);
    });

    testWidgets('nth picks among same-row icons left-to-right',
        (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(_app(
        SizedBox(
          height: 56,
          child: Row(
            children: [
              GestureDetector(
                onTap: () => taps.add('menu'),
                child: const Icon(Icons.menu),
              ),
              const Expanded(child: Center(child: Text('Wishlist'))),
              GestureDetector(
                onTap: () => taps.add('cart'),
                child: const Icon(Icons.shopping_bag_outlined),
              ),
            ],
          ),
        ),
      ));

      await _pumpAndAwait(tester, () => dispatcher.tapNear('Wishlist', 1));
      expect(taps, ['cart']);

      await _pumpAndAwait(tester, () => dispatcher.tapNear('Wishlist', 0));
      expect(taps, ['cart', 'menu']);
    });

    testWidgets('a nested enabled wrapper counts as one candidate',
        (tester) async {
      // Outer button-like wrapper whose tap affordance lives on an inner
      // GestureDetector — both are "interactive", but only the outermost
      // may count or nth drifts from the catalog's.
      var taps = 0;
      await tester.pumpWidget(_app(
        SizedBox(
          height: 56,
          child: Row(
            children: [
              const Expanded(child: Text('Item Title 12')),
              MouseRegion(
                child: GestureDetector(
                  onTap: () => taps++,
                  child: GestureDetector(
                    onTap: () => taps++,
                    child: const Icon(Icons.delete_outline),
                  ),
                ),
              ),
            ],
          ),
        ),
      ));

      // nth 1 must be out of range — there is exactly one candidate.
      await expectLater(
        dispatcher.tapNear('Item Title 12', 1),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('out of range'))
            .having((e) => e.message, 'message', contains('1 unlabeled'))),
      );

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.tapNear('Item Title 12', 0),
      );
      expect(ok, isTrue);
      expect(taps, greaterThan(0));
    });

    testWidgets('throws when the anchor text is ambiguous on screen',
        (tester) async {
      await tester.pumpWidget(_app(
        Column(
          children: [
            itemRow('Item Name', () {}),
            itemRow('Item Name', () {}),
          ],
        ),
      ));

      await expectLater(
        dispatcher.tapNear('Item Name', 0),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('ambiguous'))),
      );
    });

    testWidgets('throws when the anchor text is missing', (tester) async {
      await tester.pumpWidget(_app(itemRow('Item Title 9', () {})));

      await expectLater(
        dispatcher.tapNear('No Such Item', 0),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('No on-screen'))),
      );
    });

    testWidgets('an icon with its own visible text is not a candidate',
        (tester) async {
      // The labeled "Edit" control is addressable by text already; only the
      // truly unlabeled trash icon qualifies for `near`.
      final taps = <String>[];
      await tester.pumpWidget(_app(
        SizedBox(
          height: 56,
          child: Row(
            children: [
              const Expanded(child: Text('Item Title 9')),
              GestureDetector(
                onTap: () => taps.add('edit'),
                child: const Text('Edit'),
              ),
              GestureDetector(
                onTap: () => taps.add('delete'),
                child: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.tapNear('Item Title 9', 0),
      );

      expect(ok, isTrue);
      expect(taps, ['delete']);
    });

    testWidgets('longPressNear long-presses the row control', (tester) async {
      var longPressed = false;
      await tester.pumpWidget(_app(
        SizedBox(
          height: 56,
          child: Row(
            children: [
              const Expanded(child: Text('Item Title 9')),
              GestureDetector(
                onLongPress: () => longPressed = true,
                child: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ));

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.longPressNear('Item Title 9', 0),
      );

      expect(ok, isTrue);
      expect(longPressed, isTrue);
    });

    // A keyless icon button of fixed size at an absolute position.
    Widget cornerButton(double left, double top, VoidCallback onTap) {
      return Positioned(
        left: left,
        top: top,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: const SizedBox(
            width: 40,
            height: 40,
            child: Icon(Icons.circle),
          ),
        ),
      );
    }

    // A genuinely tall anchor: a single large glyph whose tight text rect
    // spans both grid rows (a normal-height label would only overlap its own
    // row — that's why `near` is fundamentally a row model). Kept narrow
    // (single char) so the buttons to its right don't x-overlap it.
    Widget tallAnchor() => const Positioned(
          left: 0,
          top: 100,
          child: Text('M', style: TextStyle(fontSize: 300)),
        );

    testWidgets('nth follows reading order over a 2x2 grid (TL,TR,BL,BR)',
        (tester) async {
      final taps = <String>[];
      Widget grid() => _app(Stack(
            children: [
              tallAnchor(),
              cornerButton(300, 110, () => taps.add('TL')),
              cornerButton(360, 110, () => taps.add('TR')),
              cornerButton(300, 320, () => taps.add('BL')),
              cornerButton(360, 320, () => taps.add('BR')),
            ],
          ));

      for (final (nth, want) in [(0, 'TL'), (1, 'TR'), (2, 'BL'), (3, 'BR')]) {
        await tester.pumpWidget(grid());
        await _pumpAndAwait(tester, () => dispatcher.tapNear('M', nth));
        expect(taps, [want], reason: 'nth=$nth should tap $want');
        taps.clear();
      }
    });

    testWidgets('nth distinguishes a vertical column of same-x icons',
        (tester) async {
      // The same-x regression: x-only/strict-< ordering collapsed these to
      // one index; reading order gives top=0, bottom=1.
      final taps = <String>[];
      Widget column() => _app(Stack(
            children: [
              tallAnchor(),
              cornerButton(300, 110, () => taps.add('top')),
              cornerButton(300, 320, () => taps.add('bottom')),
            ],
          ));

      await tester.pumpWidget(column());
      await _pumpAndAwait(tester, () => dispatcher.tapNear('M', 1));
      expect(taps, ['bottom']);

      taps.clear();
      await tester.pumpWidget(column());
      await _pumpAndAwait(tester, () => dispatcher.tapNear('M', 0));
      expect(taps, ['top']);
    });
  });
}
