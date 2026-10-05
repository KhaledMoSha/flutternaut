import 'dart:async';

import 'package:flutter/gestures.dart';
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

/// Clears `debugCreator` on every render object of the pumped tree — the
/// state of a profile or release build, where Flutter only sets it inside an
/// assert. The bridge runs in every build mode, so the gate and its messages
/// must not depend on it. Call it after the last pump before the action
/// (a rebuild sets it again in a debug test run).
void _dropDebugCreators(WidgetTester tester) {
  final root = tester.binding.rootElement;
  if (root == null) fail('no root element: pump a widget first');
  var cleared = 0;
  void visit(Element element) {
    if (element is RenderObjectElement) {
      element.renderObject.debugCreator = null;
      cleared++;
    }
    element.visitChildren(visit);
  }

  visit(root);
  expect(cleared, greaterThan(0));
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

      expect(ok, isNotEmpty);
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

      expect(ok, isNotEmpty);
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

      expect(ok, isNotEmpty);
      expect(tapped, isTrue);
    });

    testWidgets('taps a rich label by a substring (contains)', (tester) async {
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
        () => dispatcher.tapByTextMatch('Log in', TextMatch.contains),
      );

      expect(ok, isNotEmpty);
      expect(tapped, isTrue);
    });

    testWidgets(
        'taps the label that starts with the text (starts_with), not one '
        'that only contains it', (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(_app(Column(children: [
        GestureDetector(
          onTap: () => taps.add('infix'),
          child: const Text('Start Free Trial'),
        ),
        GestureDetector(
          onTap: () => taps.add('prefix'),
          child: const Text('Free Trial'),
        ),
      ])));

      final reached = await _pumpAndAwait(
        tester,
        () => dispatcher.tapByTextMatch('FREE', TextMatch.startsWith),
      );

      expect(reached, contains('"Free Trial"'));
      expect(taps, ['prefix']);
    });

    testWidgets('a starts_with miss names the comparison', (tester) async {
      await tester.pumpWidget(_app(const Text('Start Free Trial')));

      await expectLater(
        dispatcher.tapByTextMatch('Free', TextMatch.startsWith),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          'No element found matching text starting with "Free".',
        )),
      );
    });

    Widget bags(List<String> taps) => _app(Column(children: [
          GestureDetector(
            onTap: () => taps.add('first'),
            child: const Text('Bag · 1'),
          ),
          GestureDetector(
            onTap: () => taps.add('second'),
            child: const Text('Bag · 2'),
          ),
        ]));

    testWidgets(
        'two labels starting with the text are ambiguous, and the error '
        'offers nth', (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(bags(taps));

      await expectLater(
        dispatcher.tapByTextMatch('bag', TextMatch.startsWith),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Ambiguous locator text starting with "bag"'),
            contains('nth 0'),
            contains('nth 1'),
            contains('Pass nth'),
          ),
        )),
      );
      expect(taps, isEmpty);
    });

    testWidgets('nth picks among labels starting with the text',
        (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(bags(taps));

      final reached = await _pumpAndAwait(
        tester,
        () => dispatcher.tapByTextMatch('Bag', TextMatch.startsWith, nth: 1),
      );

      expect(reached, contains('"Bag · 2"'));
      expect(taps, ['second']);
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
    testWidgets(
        'writes into the field below the label, not the '
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

    // The partner app: an edit-menu page with a "Name in English" field
    // stays mounted under the new-category page, whose form has the same
    // label and field at the same place. The page underneath comes first in
    // tree order and keeps its last geometry; resolving its label typed into
    // — or, gated, refused as occluded — a field the user cannot see.
    testWidgets(
        'a page kept underneath with the same form does not take the label',
        (tester) async {
      final under = TextEditingController();
      final top = TextEditingController();
      addTearDown(under.dispose);
      addTearDown(top.dispose);
      final nav = GlobalKey<NavigatorState>();
      Widget form(TextEditingController controller) => Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Name in English'),
                TextField(controller: controller),
              ],
            ),
          );

      await tester.pumpWidget(
          MaterialApp(navigatorKey: nav, home: form(under)));
      // An opaque page with no transition (as the partner app's router
      // pushes it): the page underneath keeps its place and full opacity.
      nav.currentState!.push(PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => form(top),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ));
      await tester.pumpAndSettle();

      final ok = await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(text: 'Name in English', input: 'Cat'),
      );

      expect(ok, isTrue);
      expect(top.text, 'Cat');
      expect(under.text, isEmpty,
          reason: 'the page underneath is not on screen for the user');
    });

    testWidgets('a label in an inactive tab (Offstage) does not take the label',
        (tester) async {
      final hiddenTab = TextEditingController();
      final shown = TextEditingController();
      addTearDown(hiddenTab.dispose);
      addTearDown(shown.dispose);
      await tester.pumpWidget(_app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Offstage(
              child: Column(children: [
                const Text('Name'),
                TextField(controller: hiddenTab),
              ]),
            ),
            const Text('Name'),
            TextField(controller: shown),
          ],
        ),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(text: 'Name', input: 'x'),
      );

      expect(shown.text, 'x');
      expect(hiddenTab.text, isEmpty);
    });

    testWidgets('a filled field is still found by its faded-out hint',
        (tester) async {
      final email = TextEditingController(text: 'old@b.c');
      addTearDown(email.dispose);
      await tester.pumpWidget(_app(
        TextField(
          controller: email,
          decoration: const InputDecoration(hintText: 'Email'),
        ),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.clearText(text: 'Email'),
      );

      expect(email.text, isEmpty);
    });

    // Decided 2026-10-05: two fields on the visible page under the same
    // label keep resolving to the first in tree order (no new refusal).
    testWidgets('two visible fields under the same label: the first is used',
        (tester) async {
      final first = TextEditingController();
      final second = TextEditingController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(_app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Name'),
            TextField(controller: first),
            const SizedBox(height: 24),
            const Text('Name'),
            TextField(controller: second),
          ],
        ),
      ));

      await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(text: 'Name', input: 'x'),
      );

      expect(first.text, 'x');
      expect(second.text, isEmpty);
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

    testWidgets('clearText fires onChanged with empty string', (tester) async {
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

    // `/long_press` used to drop `match`, so a contains locator was matched
    // exactly and missed. The mode now reaches the confirm pipeline.
    Widget pressables(List<String> pressed) => _app(Column(children: [
          GestureDetector(
            onLongPress: () => pressed.add('order'),
            child: const Text('Order #1042 · pending'),
          ),
          GestureDetector(
            onLongPress: () => pressed.add('reorder'),
            child: const Text('Reorder last basket'),
          ),
        ]));

    testWidgets('honours contains', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(pressables(pressed));

      final reached = await _pumpAndAwait(
        tester,
        () => dispatcher.longPress(text: '#1042', match: TextMatch.contains),
      );

      expect(reached, contains('"Order #1042 · pending"'));
      expect(pressed, ['order']);
    });

    testWidgets('honours starts_with', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(pressables(pressed));

      // "order" is inside both labels, but only one starts with it.
      final reached = await _pumpAndAwait(
        tester,
        () => dispatcher.longPress(text: 'order', match: TextMatch.startsWith),
      );

      expect(reached, contains('"Order #1042 · pending"'));
      expect(pressed, ['order']);
    });

    testWidgets('stays exact by default', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(pressables(pressed));

      await expectLater(
        dispatcher.longPress(text: '#1042'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          'No element found matching text "#1042".',
        )),
      );
      expect(pressed, isEmpty);
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

    testWidgets('longPress throws ActionFailure', (tester) async {
      await tester.pumpWidget(_app(const Text('Hi')));
      await expectLater(
        dispatcher.longPress(key: 'missing'),
        throwsA(isA<ActionFailure>()),
      );
    });
  });

  group('a movement gesture is never a press-and-hold', () {
    // requests_inspector wraps the whole app in GestureDetector(onLongPress:).
    // Its long-press deadline is a real timer started at pointer down; a
    // swipe that awaited a frame before moving, on an app whose next frame
    // took longer than kLongPressTimeout, opened the overlay instead of
    // scrolling.
    testWidgets(
        'a swipe whose first frame stalls past the long-press timeout '
        'scrolls the list and never long-presses', (tester) async {
      var longPressed = false;
      final list = ScrollController();
      addTearDown(list.dispose);
      await tester.pumpWidget(MaterialApp(
        home: GestureDetector(
          onLongPress: () => longPressed = true,
          child: Scaffold(
            body: ListView(
              controller: list,
              children: [
                for (var i = 0; i < 60; i++)
                  SizedBox(height: 60, child: Text('Row $i')),
              ],
            ),
          ),
        ),
      ));

      final center = tester.getCenter(find.byType(ListView));
      final done = Completer<void>();
      dispatcher.swipeAt(center, 'up', 300).then(done.complete);
      // The app's next frame takes longer than a long press: fake time runs
      // past kLongPressTimeout before the first frame is produced.
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      for (var i = 0; i < 100 && !done.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(done.isCompleted, isTrue);

      expect(longPressed, isFalse,
          reason: 'the pointer left the touch slop before any frame was '
              'awaited');
      expect(list.offset, greaterThan(0), reason: 'the list must scroll');
    });
  });

  group('a tap target on a page that is not showing', () {
    // A debug overlay's hidden page (requests_inspector: the second page of
    // a NeverScrollable PageView) can stay laid out beside the screen. A
    // tap whose only match lives there must say it is off screen — not
    // blame a route transition that is not running and send the reader to
    // wait_idle.
    testWidgets('is refused as off screen, not as a route transition',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: PageView(
          physics: const NeverScrollableScrollPhysics(),
          // Keeps the neighbouring page built, beside the screen.
          allowImplicitScrolling: true,
          children: [
            const Scaffold(body: Center(child: Text('app'))),
            Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => tapped = true,
                  child: const Text('Close'),
                ),
              ),
            ),
          ],
        ),
      ));
      expect(find.text('Close', skipOffstage: false), findsOneWidget,
          reason: 'the hidden page must be built for this check');

      await expectLater(
        dispatcher.tap(text: 'Close'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('not on screen'),
            contains('800x600 screen'),
            isNot(contains('route transition')),
          ),
        )),
      );
      expect(tapped, isFalse);
    });
  });

  group('route transitions', () {
    testWidgets(
        'a tap during a route pop fails loudly instead of landing '
        'on nothing', (tester) async {
      var tapped = false;
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: Scaffold(
          body: TextButton(
            onPressed: () => tapped = true,
            child: const Text('Sort'),
          ),
        ),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('second')),
      ));
      await tester.pumpAndSettle();

      // Pop and act while the outgoing route is still sliding away: every
      // route scope ignores pointers, so the framework would drop the tap.
      nav.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 30));

      await expectLater(
        dispatcher.tap(text: 'Sort'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('route transition'), contains('wait_idle')),
        )),
      );
      expect(tapped, isFalse);

      await tester.pumpAndSettle();
      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Sort'));
      expect(tapped, isTrue, reason: 'after the transition the tap lands');
    });
  });

  group('nth for duplicate text/key/semantics locators', () {
    Widget dups(List<String> taps) => _app(Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: () => taps.add('top'),
              child: const Text('Sign Up'),
            ),
            GestureDetector(
              onTap: () => taps.add('bottom'),
              child: const Text('Sign Up'),
            ),
          ],
        ));

    testWidgets('nth picks the duplicate in reading order', (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(dups(taps));
      await _pumpAndAwait(
        tester,
        () => dispatcher.tap(text: 'Sign Up', nth: 1),
      );
      expect(taps, ['bottom']);

      taps.clear();
      await tester.pumpWidget(dups(taps));
      await _pumpAndAwait(
        tester,
        () => dispatcher.tap(text: 'Sign Up', nth: 0),
      );
      expect(taps, ['top']);
    });

    testWidgets('the ambiguity error tells the author about nth',
        (tester) async {
      await tester.pumpWidget(dups([]));
      await expectLater(
        dispatcher.tap(text: 'Sign Up'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('Ambiguous'), contains('nth 0'), contains('nth 1'),
              contains('Pass nth')),
        )),
      );
    });

    testWidgets('nth out of range fails with the visible count',
        (tester) async {
      await tester.pumpWidget(dups([]));
      await expectLater(
        dispatcher.tap(text: 'Sign Up', nth: 2),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('nth 2 is out of range'), contains('2 matching')),
        )),
      );
    });

    testWidgets('nth 0 on a unique match behaves like no nth', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(GestureDetector(
        onTap: () => tapped = true,
        child: const Text('Only'),
      )));
      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Only', nth: 0));
      expect(tapped, isTrue);
    });

    testWidgets('longPress honours nth', (tester) async {
      final presses = <String>[];
      await tester.pumpWidget(_app(Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onLongPress: () => presses.add('top'),
            child: const Text('Hold'),
          ),
          GestureDetector(
            onLongPress: () => presses.add('bottom'),
            child: const Text('Hold'),
          ),
        ],
      )));
      await _pumpAndAwait(
        tester,
        () => dispatcher.longPress(text: 'Hold', nth: 1),
      );
      expect(presses, ['bottom']);
    });
  });

  group('semantics locator', () {
    testWidgets('taps an IconButton by its tooltip', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(IconButton(
        tooltip: 'Close',
        icon: const Icon(Icons.close),
        onPressed: () => tapped = true,
      )));
      await _pumpAndAwait(tester, () => dispatcher.tap(semantics: 'Close'));
      expect(tapped, isTrue);
    });

    testWidgets('falls back to a case-insensitive label match', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(Tooltip(
        message: 'Open menu',
        child: GestureDetector(
          onTap: () => tapped = true,
          child: const Icon(Icons.menu),
        ),
      )));
      await _pumpAndAwait(
        tester,
        () => dispatcher.tap(semantics: 'open menu'),
      );
      expect(tapped, isTrue);
    });

    testWidgets('throws when no widget carries the label', (tester) async {
      await tester.pumpWidget(_app(const Icon(Icons.close)));
      await expectLater(
        dispatcher.tap(semantics: 'Close'),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('semantics'))),
      );
    });
  });

  group('typing into a focused / hidden field (OTP pattern)', () {
    // A PinCodeTextField-style widget: the real input is invisible under
    // a row of digit boxes; tapping a box focuses the hidden field.
    Widget otp(TextEditingController controller, FocusNode node) => _app(Stack(
          children: [
            Opacity(
              opacity: 0,
              child: TextField(
                key: const ValueKey('otp'),
                controller: controller,
                focusNode: node,
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => node.requestFocus(),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 4; i++)
                      Container(
                        key: ValueKey('box$i'),
                        width: 40,
                        height: 48,
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(border: Border.all()),
                        child: Center(
                          child: Text(
                            i < controller.text.length
                                ? controller.text[i]
                                : '',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ));

    testWidgets('typeFocused writes into the field the app focused',
        (tester) async {
      final controller = TextEditingController();
      final node = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(node.dispose);
      await tester.pumpWidget(otp(controller, node));

      await _pumpAndAwait(tester, () => dispatcher.tap(key: 'box0'));
      expect(node.hasFocus, isTrue);

      await _pumpAndAwait(tester, () => dispatcher.typeFocused('1234'));
      expect(controller.text, '1234');
    });

    testWidgets('typeFocused fails loudly when nothing is focused',
        (tester) async {
      await tester.pumpWidget(_app(const Text('static')));
      await expectLater(
        dispatcher.typeFocused('1'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          contains('No text field has keyboard focus'),
        )),
      );
    });

    testWidgets('typeText into an already-focused hidden field skips the gate',
        (tester) async {
      final controller = TextEditingController();
      final node = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(node.dispose);
      await tester.pumpWidget(otp(controller, node));
      node.requestFocus();
      await tester.pump();

      await _pumpAndAwait(
        tester,
        () => dispatcher.typeText(key: 'otp', input: '99'),
      );
      expect(controller.text, '99');
    });

    testWidgets(
        'typeText into an unfocused hidden field still fails as '
        'occluded (the gate is intact)', (tester) async {
      final controller = TextEditingController();
      final node = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(node.dispose);
      await tester.pumpWidget(otp(controller, node));

      await expectLater(
        dispatcher.typeText(key: 'otp', input: '1'),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('occluded'))),
      );
      expect(controller.text, isEmpty);
    });
  });

  group('reports the widget a gesture reached', () {
    testWidgets('a tap by key names the control and its label', (tester) async {
      await tester.pumpWidget(_app(
        ElevatedButton(
          key: const ValueKey('go'),
          onPressed: () {},
          child: const Text('Continue'),
        ),
      ));

      final reached =
          await _pumpAndAwait(tester, () => dispatcher.tap(key: 'go'));

      expect(reached, contains('"Continue"'));
    });

    testWidgets('tap by text, contains, near and long press report it too',
        (tester) async {
      await tester.pumpWidget(_app(
        Column(children: [
          ElevatedButton(onPressed: () {}, child: const Text('Add to bag')),
          Row(children: [
            const Text('Item Title 1'),
            IconButton(onPressed: () {}, icon: const Icon(Icons.delete)),
          ]),
        ]),
      ));

      expect(
        await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Add to bag')),
        contains('"Add to bag"'),
      );
      expect(
        await _pumpAndAwait(tester,
            () => dispatcher.tapByTextMatch('to bag', TextMatch.contains)),
        contains('"Add to bag"'),
      );
      expect(
        await _pumpAndAwait(
            tester, () => dispatcher.longPress(text: 'Add to bag')),
        contains('"Add to bag"'),
      );
      expect(
        await _pumpAndAwait(
            tester, () => dispatcher.tapNear('Item Title 1', 0)),
        isNotEmpty,
      );
      expect(
        await _pumpAndAwait(
            tester, () => dispatcher.longPressNear('Item Title 1', 0)),
        isNotEmpty,
      );
    });

    testWidgets(
        'a label reached through another widget names that widget, not the '
        'label', (tester) async {
      // A plain Text is only a locator: when a transparent input layer owns
      // its pixels (a tap-catcher stretched over a tile, painting nothing),
      // the tap goes to that layer, as a person's would — and the report
      // must say what it really hit. A cover that PAINTS is refused instead
      // (see 'pointer swallowed or covered before the target').
      var coverTapped = false;
      await tester.pumpWidget(_app(
        Stack(
          children: [
            const Center(child: Text('Continue')),
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('cover'),
                behavior: HitTestBehavior.opaque,
                onTap: () => coverTapped = true,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ));

      final reached =
          await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Continue'));

      expect(coverTapped, isTrue);
      expect(reached, isNot(contains('Continue')));
      expect(reached, contains('GestureDetector'));
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

      expect(ok, isNotEmpty);
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

      expect(ok, isNotEmpty);
      expect(focusNode.hasFocus, isTrue,
          reason: 'tapping the hint should focus the field');
    });

    testWidgets(
        'does not scroll a non-user-scrollable ancestor (overlay PageView)',
        (tester) async {
      // Regression: debug overlays (e.g. requests_inspector) wrap the whole
      // app in a PageView with NeverScrollableScrollPhysics. ensureVisible
      // used to scroll EVERY ancestor so the target sat at its leading edge,
      // dragging the hidden overlay page into view on every tap.
      final pages = PageController();
      addTearDown(pages.dispose);
      var tapped = false;
      await tester.pumpWidget(_app(
        PageView(
          controller: pages,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            Align(
              alignment: Alignment.bottomRight,
              child: ElevatedButton(
                key: const ValueKey('more_tab'),
                onPressed: () => tapped = true,
                child: const Text('More'),
              ),
            ),
            const Center(child: Text('hidden overlay page')),
          ],
        ),
      ));

      final ok =
          await _pumpAndAwait(tester, () => dispatcher.tap(key: 'more_tab'));

      expect(ok, isNotEmpty);
      expect(tapped, isTrue);
      expect(pages.offset, 0.0,
          reason: 'a tap must not move a PageView the user cannot scroll');
    });

    testWidgets('does not scroll when the target is already reachable',
        (tester) async {
      // A visible target must be tapped where it is: re-aligning it to the
      // top of its list moves the screen under the test for no reason.
      final scroll = ScrollController(initialScrollOffset: 300);
      addTearDown(scroll.dispose);
      var tapped = false;
      await tester.pumpWidget(_app(
        SingleChildScrollView(
          controller: scroll,
          child: Column(
            children: [
              for (var i = 0; i < 5; i++) const SizedBox(height: 100),
              ElevatedButton(
                key: const ValueKey('visible'),
                onPressed: () => tapped = true,
                child: const Text('Visible'),
              ),
              for (var i = 0; i < 20; i++) const SizedBox(height: 100),
            ],
          ),
        ),
      ));

      final ok =
          await _pumpAndAwait(tester, () => dispatcher.tap(key: 'visible'));

      expect(ok, isNotEmpty);
      expect(tapped, isTrue);
      expect(scroll.offset, 300.0,
          reason: 'an already-visible target needs no scrolling');
    });

    testWidgets(
        'scrolls only the user-scrollable ancestor to reach an off-screen '
        'target', (tester) async {
      final pages = PageController();
      final scroll = ScrollController();
      addTearDown(pages.dispose);
      addTearDown(scroll.dispose);
      var tapped = false;
      await tester.pumpWidget(_app(
        PageView(
          controller: pages,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  for (var i = 0; i < 20; i++) const SizedBox(height: 100),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      key: const ValueKey('deep_right'),
                      onPressed: () => tapped = true,
                      child: const Text('Deep'),
                    ),
                  ),
                ],
              ),
            ),
            const Center(child: Text('hidden overlay page')),
          ],
        ),
      ));

      final ok =
          await _pumpAndAwait(tester, () => dispatcher.tap(key: 'deep_right'));

      expect(ok, isNotEmpty);
      expect(tapped, isTrue);
      expect(scroll.offset, greaterThan(0),
          reason: 'the vertical list must scroll to reveal the target');
      expect(pages.offset, 0.0, reason: 'the locked PageView must stay put');
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

      final ok =
          await _pumpAndAwait(tester, () => dispatcher.tap(key: 'outer'));

      expect(ok, isNotEmpty);
      expect(tapped, isTrue);
    });
  });

  group('pointer swallowed or covered before the target', () {
    testWidgets(
        'a splash held in an AbsorbPointer over the page refuses the tap, '
        'then the tap lands once it is gone', (tester) async {
      // The Beanz onboarding: the page (and its Continue button) is built
      // under `Positioned.fill(AbsorbPointer(splash))`. The frontmost
      // recorded hit is the Stack — an ancestor of the label — which used to
      // pass the lenient label gate while the tap did nothing.
      final held = ValueNotifier(true);
      addTearDown(held.dispose);
      var pressed = false;
      await tester.pumpWidget(_app(ValueListenableBuilder<bool>(
        valueListenable: held,
        builder: (_, isHeld, __) => Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: InkWell(
                onTap: () => pressed = true,
                child: const Text('Continue'),
              ),
            ),
            if (isHeld)
              const Positioned.fill(
                child: AbsorbPointer(
                  child: ColoredBox(color: Color(0xFF6FA8DC)),
                ),
              ),
          ],
        ),
      )));

      await expectLater(
        dispatcher.tap(text: 'Continue'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('AbsorbPointer(ColoredBox)'), contains('occluded')),
        )),
      );
      expect(pressed, isFalse, reason: 'the splash must not swallow a "pass"');

      held.value = false;
      await tester.pump();
      final reached =
          await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Continue'));
      expect(pressed, isTrue);
      expect(reached, contains('"Continue"'));
    });

    testWidgets('a transparent absorber over a label refuses the tap',
        (tester) async {
      var pressed = false;
      await tester.pumpWidget(_app(Stack(children: [
        Center(
          child: InkWell(
            onTap: () => pressed = true,
            child: const Text('Save'),
          ),
        ),
        const Positioned.fill(child: AbsorbPointer(child: SizedBox.expand())),
      ])));

      await expectLater(
        dispatcher.tap(text: 'Save'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('takes no taps'), contains('AbsorbPointer(SizedBox)')),
        )),
      );
      expect(pressed, isFalse);
    });

    testWidgets(
        'an absorbing AbsorbPointer around the control refuses, and taps once '
        'it stops absorbing', (tester) async {
      final absorbing = ValueNotifier(true);
      addTearDown(absorbing.dispose);
      var pressed = false;
      await tester.pumpWidget(_app(Center(
        child: ValueListenableBuilder<bool>(
          valueListenable: absorbing,
          builder: (_, value, __) => AbsorbPointer(
            absorbing: value,
            child: InkWell(
              onTap: () => pressed = true,
              child: const Text('Save'),
            ),
          ),
        ),
      )));

      await expectLater(
        dispatcher.tap(text: 'Save'),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('takes no taps'))),
      );
      expect(pressed, isFalse);

      absorbing.value = false;
      await tester.pump();
      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Save'));
      expect(pressed, isTrue);
    });

    testWidgets(
        'a list that is still scrolling refuses a row tap without moving it, '
        'and the row is tapped once the scroll settles', (tester) async {
      // A Scrollable ignores pointers on its content while a scroll animates
      // or flings: a real tap then only stops the scroll.
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      String? opened;
      await tester.pumpWidget(_app(ListView(
        controller: scroll,
        children: [
          for (var i = 0; i < 40; i++)
            SizedBox(
              height: 60,
              child: InkWell(
                onTap: () => opened = 'Row $i',
                child: Text('Row $i'),
              ),
            ),
        ],
      )));

      unawaited(scroll.animateTo(
        30,
        duration: const Duration(seconds: 2),
        curve: Curves.linear,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final offsetMidScroll = scroll.offset;

      await expectLater(
        dispatcher.tap(text: 'Row 2'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          contains('still scrolling'),
        )),
      );
      expect(opened, isNull);
      expect(scroll.offset, offsetMidScroll,
          reason: 'a refused tap must not jump the list mid-scroll');

      await tester.pumpAndSettle();
      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Row 2'));
      expect(opened, 'Row 2');
    });

    testWidgets(
        'right after a navigation the Navigator absorbs the tap; once input '
        'is accepted again the tap lands', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      var pressed = false;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: Scaffold(
          body: Center(
            child: InkWell(
              onTap: () => pressed = true,
              child: const Text('Order'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // A navigation between frames: Navigator._cancelActivePointers sets
      // its AbsorbPointer until the next build.
      unawaited(nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('details')),
      )));

      await expectLater(
        dispatcher.tap(text: 'Order'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          contains('Navigator'),
        )),
      );
      expect(pressed, isFalse);

      await tester.pumpAndSettle();
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Order'));
      expect(pressed, isTrue);
    });

    testWidgets(
        'a field its tap handler wraps in an AbsorbPointer is tapped by its '
        'label and by its hint (date picker idiom)', (tester) async {
      var opened = 0;
      await tester.pumpWidget(_app(Center(
        child: SizedBox(
          width: 300,
          child: InkWell(
            onTap: () => opened++,
            child: const AbsorbPointer(
              child: TextField(
                decoration: InputDecoration(
                  labelText: 'Birthday',
                  hintText: 'dd/mm/yyyy',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
              ),
            ),
          ),
        ),
      )));

      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Birthday'));
      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'dd/mm/yyyy'));
      expect(opened, 2);
    });

    testWidgets(
        'an opaque GestureDetector wrapping an AbsorbPointer field is tapped '
        '(dropdown idiom)', (tester) async {
      var opened = false;
      await tester.pumpWidget(_app(Center(
        child: SizedBox(
          width: 300,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => opened = true,
            child: const AbsorbPointer(
              child: TextField(
                decoration: InputDecoration(hintText: 'Pick a city'),
              ),
            ),
          ),
        ),
      )));

      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Pick a city'));
      expect(opened, isTrue);
    });

    testWidgets(
        'an opaque handler over a label that ignores pointers is tapped',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => tapped = true,
          child: const IgnorePointer(child: Text('Go')),
        ),
      )));

      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Go'));
      expect(tapped, isTrue);
    });

    testWidgets(
        'a deferring handler over a label that ignores pointers is refused '
        '(the tap would reach nothing)', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(Center(
        child: GestureDetector(
          onTap: () => tapped = true,
          child: const IgnorePointer(child: Text('Go')),
        ),
      )));

      await expectLater(
        dispatcher.tap(text: 'Go'),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('takes no taps'))),
      );
      expect(tapped, isFalse);
    });

    testWidgets(
        'a page-wide handler around a painted loading layer does not make '
        'a blocked control tappable', (tester) async {
      var dismissed = false;
      var paid = false;
      await tester.pumpWidget(_app(GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => dismissed = true,
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: IgnorePointer(
            child: Center(
              child: InkWell(
                onTap: () => paid = true,
                child: const Text('Pay'),
              ),
            ),
          ),
        ),
      )));

      await expectLater(
        dispatcher.tap(text: 'Pay'),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('takes no taps'))),
      );
      expect(dismissed, isFalse);
      expect(paid, isFalse);
    });

    testWidgets('a long press under an absorbing layer is refused',
        (tester) async {
      var held = false;
      await tester.pumpWidget(_app(Center(
        child: AbsorbPointer(
          child: GestureDetector(
            onLongPress: () => held = true,
            child: const Text('Hold'),
          ),
        ),
      )));

      await expectLater(
        dispatcher.longPress(text: 'Hold'),
        throwsA(isA<ActionFailure>()),
      );
      expect(held, isFalse);
    });

    testWidgets('a painted tap-catching cover over a label refuses the tap',
        (tester) async {
      var coverTapped = false;
      await tester.pumpWidget(_app(Stack(children: [
        const Center(child: Text('Continue')),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => coverTapped = true,
            child: const ColoredBox(color: Color(0xFF6FA8DC)),
          ),
        ),
      ])));

      await expectLater(
        dispatcher.tap(text: 'Continue'),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('occluded'))),
      );
      expect(coverTapped, isFalse);
    });
  });

  group('profile/release builds (no debugCreator)', () {
    testWidgets('a field its tap handler wraps is still tapped by its label',
        (tester) async {
      var opened = false;
      await tester.pumpWidget(_app(Center(
        child: SizedBox(
          width: 300,
          child: InkWell(
            onTap: () => opened = true,
            child: const AbsorbPointer(
              child: TextField(
                decoration: InputDecoration(
                  labelText: 'Birthday',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
              ),
            ),
          ),
        ),
      )));
      _dropDebugCreators(tester);

      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Birthday'));
      expect(opened, isTrue);
    });

    testWidgets('a splash refusal still names the layer', (tester) async {
      await tester.pumpWidget(_app(Stack(fit: StackFit.expand, children: [
        Center(child: InkWell(onTap: () {}, child: const Text('Continue'))),
        const Positioned.fill(
          child: AbsorbPointer(child: ColoredBox(color: Color(0xFF6FA8DC))),
        ),
      ])));
      _dropDebugCreators(tester);

      await expectLater(
        dispatcher.tap(text: 'Continue'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          contains('AbsorbPointer(ColoredBox)'),
        )),
      );
    });

    testWidgets('a scrolling-list refusal still says the list is scrolling',
        (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(_app(ListView(
        controller: scroll,
        children: [
          for (var i = 0; i < 40; i++)
            SizedBox(
              height: 60,
              child: InkWell(onTap: () {}, child: Text('Row $i')),
            ),
        ],
      )));
      unawaited(scroll.animateTo(
        30,
        duration: const Duration(seconds: 2),
        curve: Curves.linear,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      _dropDebugCreators(tester);

      await expectLater(
        dispatcher.tap(text: 'Row 2'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          contains('still scrolling'),
        )),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a tap reports the same control as in a debug build',
        (tester) async {
      await tester.pumpWidget(_app(Center(
        child: ElevatedButton(onPressed: () {}, child: const Text('Continue')),
      )));
      final inDebug =
          await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Continue'));

      await tester.pumpAndSettle();
      _dropDebugCreators(tester);
      final inRelease =
          await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Continue'));

      expect(inRelease, contains('"Continue"'));
      expect(inRelease, inDebug);
    });
  });

  group('auto-resolve scroll (no scroll target)', () {
    testWidgets('resolves the single on-screen vertical scrollable',
        (tester) async {
      await tester.pumpWidget(_app(
        ListView(
          children: [
            for (var i = 0; i < 30; i++)
              SizedBox(height: 80, child: Text('row $i'))
          ],
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
            for (var i = 0; i < 30; i++)
              SizedBox(height: 80, child: Text('row $i')),
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

    testWidgets(
        'a same-axis scrollable that cannot move (a nav bar) does '
        'not make the choice ambiguous', (tester) async {
      await tester.pumpWidget(_app(Column(
        children: [
          Expanded(
            child: ListView(
              key: const ValueKey('main'),
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(height: 60, child: Text('row $i')),
              ],
            ),
          ),
          SizedBox(
            height: 56,
            child: ListView(
              key: const ValueKey('nav'),
              children: const [SizedBox(height: 40, child: Text('Home'))],
            ),
          ),
        ],
      )));

      final chosen = dispatcher.resolveScrollable('up');
      expect(TreeWalker.keyOf(chosen.widget) ?? '', isNot('nav'));
      expect(
        dispatcher.walker.findVisibleScrollables(Axis.vertical),
        hasLength(2),
        reason: 'both are visible; only the movable one is a candidate',
      );
    });

    testWidgets('fails loudly when no visible scrollable can move that way',
        (tester) async {
      await tester.pumpWidget(_app(
        ListView(
          children: [
            for (var i = 0; i < 30; i++)
              SizedBox(height: 80, child: Text('row $i'))
          ],
        ),
      ));

      // A fresh list sits at offset 0: swiping "down" would retreat it,
      // which is impossible.
      await expectLater(
        dispatcher.swipeAuto('down', 300),
        throwsA(isA<ActionFailure>()
            .having((e) => e.message, 'message', contains('can scroll'))),
      );
    });

    testWidgets('the dominant (largest) list wins over a small movable one',
        (tester) async {
      await tester.pumpWidget(_app(Column(
        children: [
          Expanded(
            child: ListView(
              key: const ValueKey('main'),
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(height: 60, child: Text('row $i')),
              ],
            ),
          ),
          SizedBox(
            height: 80,
            child: ListView(
              key: const ValueKey('small'),
              children: [
                for (var i = 0; i < 10; i++)
                  SizedBox(height: 40, child: Text('s $i')),
              ],
            ),
          ),
        ],
      )));

      final chosen = dispatcher.resolveScrollable('up');
      expect(TreeWalker.keyOf(chosen.widget), isNull,
          reason: 'the chosen element is the inner Scrollable, not the '
              'keyed ListView wrapper');
      final center = dispatcher.walker.centerOfElement(chosen)!;
      expect(center.dy, lessThan(400), reason: 'the main list, not the strip');
    });

    testWidgets('the ambiguity error names each candidate\'s scrollIndex',
        (tester) async {
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
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('scrollIndex 0'), contains('scrollIndex 1')),
        )),
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
      expect(first.offset, 0, reason: 'the sibling rail must stay put');
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

      expect(ok, isNotEmpty);
      expect(deleted, ['Item Title 10']);
    });

    testWidgets('nth picks among same-row icons left-to-right', (tester) async {
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
      expect(ok, isNotEmpty);
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

      expect(ok, isNotEmpty);
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

      expect(ok, isNotEmpty);
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
