import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/models/action_failure.dart';

/// Runs a dispatcher call to completion under fake time (see the same
/// helper in gesture_dispatcher_test.dart).
Future<T> _pumpAndAwait<T>(
  WidgetTester tester,
  Future<T> Function() work,
) async {
  final completer = Completer<T>();
  work().then(completer.complete, onError: completer.completeError);
  completer.future.ignore();
  for (var i = 0; i < 200 && !completer.isCompleted; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return completer.future;
}

/// What every gesture on [_Page] has done so far.
class _Counts {
  int pay = 0;
  int payLongPress = 0;
  int wishlist = 0;
  final name = TextEditingController();

  void dispose() => name.dispose();
}

/// A page with one target for each tap-like gesture: a button (tap, long
/// press, double tap, tap_at), an icon-only button in the row of a label
/// (`near`) and a field (the focusing tap of `type`).
class _Page extends StatelessWidget {
  const _Page(this.counts);

  final _Counts counts;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(
          children: [
            ElevatedButton(
              onPressed: () => counts.pay++,
              onLongPress: () => counts.payLongPress++,
              child: const Text('Pay'),
            ),
            Row(children: [
              const Text('Wishlist'),
              IconButton(
                icon: const Icon(Icons.favorite),
                onPressed: () => counts.wishlist++,
              ),
            ]),
            TextField(
              controller: counts.name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
          ],
        ),
      );
}

Matcher _refusedFor(String transition) => throwsA(isA<ActionFailure>().having(
      (e) => e.message,
      'message',
      allOf(
        contains('a $transition is in progress'),
        contains('a tap waits for it to end'),
      ),
    ));

void main() {
  final walker = TreeWalker();
  late GestureDispatcher dispatcher;
  setUp(() => dispatcher = GestureDispatcher(walker));

  testWidgets(
      'while a page slides in, no tap-like gesture is dispatched; once it '
      'has opened, each one lands', (tester) async {
    final counts = _Counts();
    addTearDown(counts.dispose);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Text('home')),
    ));
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/details'),
      builder: (_) => _Page(counts),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Premise: the page takes pointers mid-push — Flutter ignores them only
    // on a closing route — so without the gate the tap would land.
    expect(walker.isTransitioning, isTrue);
    const opening = 'page transition (/details opening)';
    final pay = tester.getCenter(find.text('Pay'));
    await expectLater(dispatcher.tap(text: 'Pay'), _refusedFor(opening));
    await expectLater(dispatcher.tapAt(pay), _refusedFor(opening));
    await expectLater(dispatcher.longPress(text: 'Pay'), _refusedFor(opening));
    await expectLater(dispatcher.multiTap(text: 'Pay'), _refusedFor(opening));
    await expectLater(dispatcher.tapNear('Wishlist', 0), _refusedFor(opening));
    await expectLater(
      dispatcher.typeText(text: 'Name', input: 'Sam'),
      _refusedFor(opening),
    );
    expect(counts.pay, 0);
    expect(counts.payLongPress, 0);
    expect(counts.wishlist, 0);
    expect(counts.name.text, isEmpty);

    await tester.pumpAndSettle();
    expect(walker.isTransitioning, isFalse);
    await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Pay'));
    await tester.pumpAndSettle();
    await _pumpAndAwait(tester, () => dispatcher.longPress(text: 'Pay'));
    await tester.pumpAndSettle();
    await _pumpAndAwait(tester, () => dispatcher.tapNear('Wishlist', 0));
    await _pumpAndAwait(
      tester,
      () => dispatcher.typeText(text: 'Name', input: 'Sam'),
    );
    expect(counts.pay, 1);
    expect(counts.payLongPress, 1);
    expect(counts.wishlist, 1);
    expect(counts.name.text, 'Sam');
  });

  testWidgets('a dialog still opening is not tapped until it has opened',
      (tester) async {
    var ok = 0;
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Text('home')),
    ));
    unawaited(showDialog<void>(
      context: nav.currentContext!,
      routeSettings: const RouteSettings(name: '/confirm'),
      builder: (_) => AlertDialog(
        actions: [TextButton(onPressed: () => ok++, child: const Text('OK'))],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    await expectLater(
      dispatcher.tap(text: 'OK'),
      _refusedFor(
          'popup (dialog, sheet or menu) transition (/confirm opening)'),
    );
    expect(ok, 0);

    await tester.pumpAndSettle();
    await _pumpAndAwait(tester, () => dispatcher.tap(text: 'OK'));
    expect(ok, 1);
  });

  testWidgets('a push inside a nested Navigator (a tab shell) is waited out',
      (tester) async {
    final counts = _Counts();
    addTearDown(counts.dispose);
    final inner = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Navigator(
          key: inner,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const Text('tab root'),
          ),
        ),
      ),
    ));
    unawaited(inner.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => _Page(counts),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await expectLater(
      dispatcher.tap(text: 'Pay'),
      _refusedFor('page transition (opening)'),
    );
    expect(counts.pay, 0);

    await tester.pumpAndSettle();
    await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Pay'));
    expect(counts.pay, 1);
  });

  group('a route that moves where nobody sees it never blocks a tap', () {
    testWidgets(
        'an inactive CupertinoTabScaffold tab left mid-push (its ticker is '
        'muted, so its animation never ends)', (tester) async {
      final counts = _Counts();
      addTearDown(counts.dispose);
      final tabs = CupertinoTabController();
      addTearDown(tabs.dispose);
      final navs = [GlobalKey<NavigatorState>(), GlobalKey<NavigatorState>()];
      await tester.pumpWidget(MaterialApp(
        home: CupertinoTabScaffold(
          controller: tabs,
          tabBar: CupertinoTabBar(items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
            BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Me'),
          ]),
          tabBuilder: (_, i) => CupertinoTabView(
            navigatorKey: navs[i],
            builder: (_) => i == 0 ? _Page(counts) : const Text('me root'),
          ),
        ),
      ));
      tabs.index = 1; // build the second tab once
      await tester.pumpAndSettle();
      tabs.index = 0;
      await tester.pumpAndSettle();

      final route = CupertinoPageRoute<void>(
        builder: (_) => const Text('me details'),
      );
      unawaited(navs[1].currentState!.push(route));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Premise: the muted ticker keeps the hidden push "animating".
      expect(route.animation!.isAnimating, isTrue);
      expect(walker.isTransitioning, isFalse,
          reason: '/wait_for_idle and the dump read the same rule');
      await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Pay'));
      expect(counts.pay, 1);
    });

    testWidgets('a Navigator under an active Offstage', (tester) async {
      final counts = _Counts();
      addTearDown(counts.dispose);
      final hidden = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        home: Stack(children: [
          _Page(counts),
          Offstage(
            child: Navigator(
              key: hidden,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const Text('hidden root'),
              ),
            ),
          ),
        ]),
      ));
      unawaited(hidden.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Text('hidden details'),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(walker.isTransitioning, isFalse);
      expect(
        await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Pay')),
        contains('"Pay"'),
      );
      expect(counts.pay, 1);
    });
  });

  testWidgets('a spinner running beside a button never blocks its tap',
      (tester) async {
    var paid = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          const CircularProgressIndicator(),
          ElevatedButton(onPressed: () => paid++, child: const Text('Pay')),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(walker.isTransitioning, isFalse);
    await _pumpAndAwait(tester, () => dispatcher.tap(text: 'Pay'));
    expect(paid, 1);
  });

  testWidgets(
      'a double tap passes the full tap gate: an occluded target is refused, '
      'not tapped at its centre', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Stack(children: [
        GestureDetector(
          key: const ValueKey('target'),
          onTap: () => taps++,
          child: const SizedBox(width: 100, height: 100),
        ),
        const Positioned(
          left: 0,
          top: 0,
          width: 200,
          height: 200,
          child: ColoredBox(color: Color(0xFF000000)),
        ),
      ]),
    ));

    await expectLater(
      dispatcher.multiTap(key: 'target'),
      throwsA(isA<ActionFailure>()),
    );
    expect(taps, 0);
  });
}
