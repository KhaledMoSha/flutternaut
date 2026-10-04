import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/assert_handler.dart';
import 'package:flutternaut/src/bridge/handlers/gesture_handler.dart';
import 'package:flutternaut/src/bridge/handlers/query_handler.dart';
import 'package:flutternaut/src/bridge/router.dart';

import 'route_harness.dart';

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

void main() {
  late BridgeRouter router;
  late TreeWalker walker;

  setUp(() {
    walker = TreeWalker();
    final runner = MainThreadRunner();
    router = BridgeRouter(log: (_) {});
    GestureHandler(gesture: GestureDispatcher(walker), runner: runner)
        .register(router);
    QueryHandler(walker: walker, runner: runner).register(router);
    AssertHandler(walker: walker, runner: runner).register(router);
  });

  /// The `data` of an assertion route's answer.
  Future<Map<String, dynamic>> check(
    WidgetTester tester,
    String path,
    Map<String, dynamic> body,
  ) async {
    final (status, envelope) = await postRoute(tester, router, path, body);
    expect(status, 200, reason: '$envelope');
    return envelope['data'] as Map<String, dynamic>;
  }

  group('a label answers with the state of its control', () {
    testWidgets('a disabled FilledButton by its label text is disabled',
        (tester) async {
      await tester.pumpWidget(_app(const FilledButton(
        onPressed: null,
        child: Text('Save'),
      )));

      final disabled =
          await check(tester, '/assert_disabled', {'text': 'Save'});
      expect(disabled['passed'], isTrue, reason: '$disabled');
      expect(disabled['control'], 'FilledButton "Save"');

      final enabled = await check(tester, '/assert_enabled', {'text': 'Save'});
      expect(enabled['passed'], isFalse);
      expect(enabled['message'], 'FilledButton "Save" is disabled');
      expect(enabled['final'], isNull, reason: 'the button may enable');
    });

    testWidgets('an enabled one answers enabled, also by contains / prefix',
        (tester) async {
      await tester.pumpWidget(_app(FilledButton(
        onPressed: () {},
        child: const Text('Log in'),
      )));

      for (final body in [
        {'text': 'Log in'},
        {'text': 'log', 'match': 'starts_with'},
        {'text': 'g i', 'match': 'contains'},
      ]) {
        final data = await check(tester, '/assert_enabled', body);
        expect(data['passed'], isTrue, reason: '$body: $data');
      }
    });

    testWidgets('a switch tile and a radio tile answer through their ListTile',
        (tester) async {
      await tester.pumpWidget(_app(RadioGroup<int>(
        groupValue: 0,
        onChanged: (_) {},
        child: Column(children: [
          const SwitchListTile(
            value: false,
            onChanged: null,
            title: Text('Dark mode'),
          ),
          SwitchListTile(
            value: true,
            onChanged: (_) {},
            title: const Text('Notifications'),
          ),
          // A RadioListTile under a RadioGroup has no onChanged of its own.
          const RadioListTile<int>(value: 1, title: Text('Express delivery')),
        ]),
      )));

      expect(
        (await check(
            tester, '/assert_disabled', {'text': 'Dark mode'}))['passed'],
        isTrue,
      );
      expect(
        (await check(
            tester, '/assert_enabled', {'text': 'Notifications'}))['passed'],
        isTrue,
      );
      expect(
        (await check(
            tester, '/assert_enabled', {'text': 'Express delivery'}))['passed'],
        isTrue,
      );
    });

    testWidgets('a field answers by its label', (tester) async {
      await tester.pumpWidget(_app(const TextField(
        enabled: false,
        decoration: InputDecoration(labelText: 'Email'),
      )));

      final data = await check(tester, '/assert_disabled', {'text': 'Email'});
      expect(data['passed'], isTrue, reason: '$data');
      expect(data['control'], startsWith('TextField'));
    });

    testWidgets('a custom button on a bare GestureDetector (onTap: null)',
        (tester) async {
      await tester.pumpWidget(_app(GestureDetector(
        onTap: null,
        child: const Text('Create Account'),
      )));

      final data =
          await check(tester, '/assert_disabled', {'text': 'Create Account'});
      expect(data['passed'], isTrue, reason: '$data');
    });

    testWidgets('a button with only onLongPress is enabled, as Flutter says',
        (tester) async {
      await tester.pumpWidget(_app(FilledButton(
        onPressed: null,
        onLongPress: () {},
        child: const Text('Hold to confirm'),
      )));

      final data =
          await check(tester, '/assert_enabled', {'text': 'Hold to confirm'});
      expect(data['passed'], isTrue, reason: '$data');
    });
  });

  group('keys and labels on controls the old table did not know', () {
    testWidgets('a keyed FAB and CupertinoButton with onPressed: null',
        (tester) async {
      await tester.pumpWidget(_app(const Column(children: [
        FloatingActionButton(
          key: ValueKey('fab'),
          onPressed: null,
          child: Icon(Icons.add),
        ),
        CupertinoButton(
          key: ValueKey('cupertino'),
          onPressed: null,
          child: Text('Continue'),
        ),
      ])));

      for (final key in ['fab', 'cupertino']) {
        final data = await check(tester, '/assert_disabled', {'key': key});
        expect(data['passed'], isTrue, reason: '$key: $data');
      }
    });

    testWidgets('a key on the Padding around a button reads the button',
        (tester) async {
      await tester.pumpWidget(_app(const Padding(
        key: ValueKey('save_slot'),
        padding: EdgeInsets.all(8),
        child: FilledButton(onPressed: null, child: Text('Save')),
      )));

      final data =
          await check(tester, '/assert_disabled', {'key': 'save_slot'});
      expect(data['passed'], isTrue, reason: '$data');
      expect(data['control'], 'FilledButton "Save"');
    });

    testWidgets('a disabled IconButton by its tooltip', (tester) async {
      await tester.pumpWidget(_app(const IconButton(
        tooltip: 'Delete',
        onPressed: null,
        icon: Icon(Icons.delete),
      )));

      final data =
          await check(tester, '/assert_disabled', {'semantics': 'Delete'});
      expect(data['passed'], isTrue, reason: '$data');
    });

    testWidgets('a Tooltip around a disabled button reads the button',
        (tester) async {
      await tester.pumpWidget(_app(const Tooltip(
        message: 'Save draft',
        child: FilledButton(onPressed: null, child: Text('Draft')),
      )));

      final data =
          await check(tester, '/assert_disabled', {'semantics': 'Save draft'});
      expect(data['passed'], isTrue, reason: '$data');
      expect(data['control'], 'FilledButton "Draft"');
    });
  });

  group('a widget that is no control is neither enabled nor disabled', () {
    Future<void> expectNotAControl(
      WidgetTester tester,
      Map<String, dynamic> locator,
    ) async {
      for (final path in ['/assert_enabled', '/assert_disabled']) {
        final data = await check(tester, path, locator);
        expect(data['passed'], isFalse, reason: '$path $locator: $data');
        expect(data['final'], isTrue, reason: '$path $locator: $data');
        expect(data['message'], contains('is not part of any control'));
      }
    }

    testWidgets('a static ListTile row', (tester) async {
      await tester.pumpWidget(_app(const ListTile(
        title: Text('Email'),
        subtitle: Text('qa@shop.test'),
      )));
      await expectNotAControl(tester, {'text': 'Email'});
    });

    testWidgets('a caption under a page-wide unfocus GestureDetector',
        (tester) async {
      await tester.pumpWidget(_app(GestureDetector(
        onTap: () {},
        child: const Column(children: [Text('Your order'), Text('Total')]),
      )));
      await expectNotAControl(tester, {'text': 'Total'});
    });

    testWidgets('a key on a row whose subtree branches (a Dismissible)',
        (tester) async {
      await tester.pumpWidget(_app(Dismissible(
        key: const ValueKey('cart_item_1'),
        onDismissed: (_) {},
        child: ListTile(
          title: const Text('Apple'),
          trailing: IconButton(
            tooltip: 'Remove Apple',
            onPressed: () {},
            icon: const Icon(Icons.delete),
          ),
        ),
      )));
      await expectNotAControl(tester, {'key': 'cart_item_1'});
    });
  });

  group('which match is checked', () {
    testWidgets('a page under a dialog does not count', (tester) async {
      await tester.pumpWidget(_app(
        FilledButton(onPressed: () {}, child: const Text('Save')),
      ));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(DialogRoute<void>(
        context: navigator.context,
        builder: (_) => const Dialog(
          child: FilledButton(onPressed: null, child: Text('Save')),
        ),
      )));
      await tester.pumpAndSettle();

      final data = await check(tester, '/assert_disabled', {'text': 'Save'});
      expect(data['passed'], isTrue,
          reason: 'only the dialog\'s button is in front: $data');
    });

    testWidgets('a unique button scrolled out of view is still checked',
        (tester) async {
      await tester.pumpWidget(_app(SingleChildScrollView(
        child: Column(children: [
          const SizedBox(height: 3000),
          const FilledButton(onPressed: null, child: Text('Place order')),
        ]),
      )));

      final data =
          await check(tester, '/assert_disabled', {'text': 'Place order'});
      expect(data['passed'], isTrue, reason: '$data');
    });

    testWidgets('two buttons with one label are ambiguous without nth',
        (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        FilledButton(onPressed: () {}, child: const Text('Add')),
        const FilledButton(onPressed: null, child: Text('Add')),
      ])));

      final data = await check(tester, '/assert_enabled', {'text': 'Add'});
      expect(data['passed'], isFalse);
      expect(data['message'], contains('ambiguous'));
      expect(data['final'], isNull, reason: 'a duplicate may go away');

      expect(
        (await check(
            tester, '/assert_enabled', {'text': 'Add', 'nth': 0}))['passed'],
        isTrue,
      );
      expect(
        (await check(
            tester, '/assert_disabled', {'text': 'Add', 'nth': 1}))['passed'],
        isTrue,
      );
    });

    testWidgets(
        'one nth list: the dump, the state route and a tap agree on a '
        'duplicate that takes no taps', (tester) async {
      await tester.pumpWidget(_app(Column(children: [
        FilledButton(onPressed: () {}, child: const Text('Add')),
        IgnorePointer(
          child: FilledButton(onPressed: () {}, child: const Text('Add')),
        ),
      ])));

      final nodes = _flatten(
        walker.dumpVisibleTree()['elements'] as List,
      ).where((n) => n['text'] == 'Add').toList();
      expect([for (final n in nodes) n['text_nth']], [0, 1]);

      final second =
          await check(tester, '/assert_enabled', {'text': 'Add', 'nth': 1});
      expect(second['passed'], isTrue, reason: '$second');

      final (status, tap) =
          await postRoute(tester, router, '/tap', {'text': 'Add', 'nth': 1});
      expect(status, isNot(200), reason: 'the second button takes no taps');
      expect('$tap', contains('takes no taps'));
    });
  });

  testWidgets(
      'every dump node with an enabled state agrees with /is_enabled '
      'through its locator', (tester) async {
    await tester.pumpWidget(_app(RadioGroup<int>(
      groupValue: 0,
      onChanged: (_) {},
      child: ListView(children: [
        FilledButton(onPressed: () {}, child: const Text('Log in')),
        const FilledButton(onPressed: null, child: Text('Checkout')),
        const OutlinedButton(onPressed: null, child: Text('Apply')),
        TextButton(onPressed: () {}, child: const Text('Cancel')),
        const SwitchListTile(
            value: false, onChanged: null, title: Text('Dark mode')),
        ListTile(title: const Text('Profile'), onTap: () {}),
        const ListTile(title: Text('Signed in')),
        const RadioListTile<int>(value: 0, title: Text('Standard delivery')),
        GestureDetector(onTap: null, child: const Text('Create Account')),
        const IconButton(
            tooltip: 'Delete', onPressed: null, icon: Icon(Icons.delete)),
      ]),
    )));

    final nodes = _flatten(walker.dumpVisibleTree()['elements'] as List);
    var compared = 0;
    for (final node in nodes) {
      final enabled = node['enabled'];
      if (enabled is! bool) continue;
      final Map<String, dynamic> locator;
      final text = node['text'] as String?;
      if (text != null && RegExp(r'[A-Za-z0-9]').hasMatch(text)) {
        locator = {
          'text': text,
          if (node['text_nth'] != null) 'nth': node['text_nth'],
        };
      } else if (node['semantics'] != null) {
        locator = {'semantics': node['semantics']};
      } else {
        continue;
      }
      final (status, envelope) =
          await postRoute(tester, router, '/is_enabled', locator);
      expect(status, 200);
      final data = envelope['data'] as Map<String, dynamic>;
      expect(data['found'], isTrue, reason: '$locator: $data');
      expect(data['enabled'], enabled,
          reason: 'dump node $node vs /is_enabled $data');
      compared++;
    }
    expect(compared, greaterThanOrEqualTo(8));
    expect(
      nodes.where((n) => n['text'] == 'Signed in').single['enabled'],
      isNull,
      reason: 'a static ListTile row is not a control in the dump either',
    );
  });

  group('screen-wide text assertions see only visible text', () {
    testWidgets('text on a page under a dialog does not satisfy them',
        (tester) async {
      await tester.pumpWidget(_app(const Text('Order total')));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(DialogRoute<void>(
        context: navigator.context,
        builder: (_) => const Dialog(child: Text('Confirm order')),
      )));
      await tester.pumpAndSettle();

      final hidden =
          await check(tester, '/assert_text_equals', {'text': 'Order total'});
      expect(hidden['passed'], isFalse, reason: '$hidden');
      expect(hidden['message'], contains('hidden behind a dialog'));
      final hiddenPart =
          await check(tester, '/assert_text_contains', {'text': 'total'});
      expect(hiddenPart['passed'], isFalse, reason: '$hiddenPart');

      final shown =
          await check(tester, '/assert_text_equals', {'text': 'Confirm order'});
      expect(shown['passed'], isTrue, reason: '$shown');
      final shownPart =
          await check(tester, '/assert_text_contains', {'text': 'confirm'});
      expect(shownPart['passed'], isTrue, reason: '$shownPart');
    });
  });
}

/// Every node of a `/screen` element list, depth first.
List<Map<String, dynamic>> _flatten(List<dynamic> nodes) => [
      for (final n in nodes.cast<Map<String, dynamic>>()) ...[
        n,
        ..._flatten((n['children'] as List?) ?? const []),
      ],
    ];
