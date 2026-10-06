import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/models/action_failure.dart';

/// Runs a dispatcher call to completion under fake time (see the same
/// helper in gesture_dispatcher_test.dart). A failure reaches the caller
/// after the pumps; it is marked handled at once so the test zone does not
/// report it as uncaught before the caller's matcher sees it.
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

/// A page that is one full-screen list, keyed `<name>_list`.
Widget _listPage(
  String name,
  ScrollController controller, {
  Axis axis = Axis.vertical,
}) {
  final list = ListView(
    key: ValueKey('${name}_list'),
    controller: controller,
    scrollDirection: axis,
    children: [
      for (var i = 0; i < 40; i++)
        axis == Axis.vertical
            ? SizedBox(height: 60, child: Text('$name $i'))
            : SizedBox(width: 80, child: Text('$name $i')),
    ],
  );
  return Scaffold(
    body: axis == Axis.vertical
        ? list
        : Center(child: SizedBox(height: 100, child: list)),
  );
}

/// A controller disposed when the test ends.
ScrollController _controller() {
  final c = ScrollController();
  addTearDown(c.dispose);
  return c;
}

/// A page pushed over another fades the one underneath out on Android
/// (opacity 0 hides it) but only slides it a third aside on iOS, where it
/// stays painted at full opacity until the overlay stops laying it out —
/// so the covered-page rule is checked on both.
final _platforms =
    TargetPlatformVariant(const {TargetPlatform.android, TargetPlatform.iOS});

void main() {
  final walker = TreeWalker();
  late GestureDispatcher dispatcher;
  setUp(() => dispatcher = GestureDispatcher(walker));

  /// The dump's scrollable nodes on [axis] (`vertical`/`horizontal`).
  List<Map<String, dynamic>> scrollNodes(String axis) =>
      _flatten(walker.dumpVisibleTree()['elements'] as List)
          .where((n) => n['scrollable'] == true && n['axis'] == axis)
          .toList();

  /// The dump numbers exactly what `/swipe` resolves: indexes 0..n-1, in
  /// order, with no gap, for the n scrollables the shared filter counts.
  void expectOneNumbering(Axis axis) {
    final name = axis == Axis.vertical ? 'vertical' : 'horizontal';
    final counted = walker.findVisibleScrollables(axis);
    expect(
      scrollNodes(name).map((n) => n['scrollIndex']).toList(),
      [for (var i = 0; i < counted.length; i++) i],
      reason: 'the dump and /swipe must number the same $name scrollables',
    );
  }

  /// The message of the [ActionFailure] [work] ends with, run under
  /// pumped frames: a swipe the bridge wrongly accepts finishes and fails
  /// the test instead of waiting on a frame forever.
  Future<String> failureOf(
    WidgetTester tester,
    Future<Object?> Function() work,
  ) async {
    try {
      await _pumpAndAwait(tester, work);
    } on ActionFailure catch (e) {
      return e.message;
    }
    fail('expected an ActionFailure, but the call succeeded');
  }

  group('a list on a page hidden behind another route takes no number', () {
    testWidgets('an opaque page pushed over a list page: only its list counts',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final top = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('top', top),
      ));
      await tester.pumpAndSettle();

      final dumped = scrollNodes('vertical');
      expect(dumped, hasLength(1));
      expect(dumped.single['key'], 'top_list');
      expect(dumped.single['scrollIndex'], 0);
      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(1),
          reason: 'the page kept alive underneath (maintainState) is not '
              'a candidate');
      expectOneNumbering(Axis.vertical);
    }, variant: _platforms);

    testWidgets(
        'an opaque page pushed over a list page: a direction-only swipe '
        'scrolls the top list, not ambiguous', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final top = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('top', top),
      ));
      await tester.pumpAndSettle();

      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));
      expect(top.offset, greaterThan(0));
      expect(under.offset, 0);
    }, variant: _platforms);

    testWidgets(
        'an opaque page pushed over a list page: scrollIndex 0 is the top '
        'list and scrollIndex 1 is out of range', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final top = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('top', top),
      ));
      await tester.pumpAndSettle();

      expect(
        await failureOf(tester, () => dispatcher.swipeAtIndex(1, 'up', 300)),
        contains('scrollIndex 1 is out of range: 1 vertical scrollable(s) '
            'are visible.'),
      );
      await _pumpAndAwait(tester, () => dispatcher.swipeAtIndex(0, 'up', 300));
      expect(top.offset, greaterThan(0));
      expect(under.offset, 0);
    }, variant: _platforms);

    testWidgets(
        'three stacked list pages: the top list is scrollIndex 0 and the '
        'auto-pick takes it', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final first = _controller();
      final second = _controller();
      final third = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('first', first),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('second', second),
      ));
      await tester.pumpAndSettle();
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('third', third),
      ));
      await tester.pumpAndSettle();

      final dumped = scrollNodes('vertical');
      expect(dumped, hasLength(1));
      expect(dumped.single['key'], 'third_list');
      expect(dumped.single['scrollIndex'], 0);
      expectOneNumbering(Axis.vertical);

      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));
      expect(third.offset, greaterThan(0));
      expect(first.offset, 0);
      expect(second.offset, 0);
    }, variant: _platforms);

    testWidgets(
        'a modal bottom sheet with a list: only the sheet\'s list counts',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final sheet = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      showModalBottomSheet<void>(
        context: nav.currentContext!,
        builder: (_) => SizedBox(
          height: 300,
          child: ListView(
            key: const ValueKey('sheet_list'),
            controller: sheet,
            children: [
              for (var i = 0; i < 30; i++)
                SizedBox(height: 60, child: Text('sheet $i')),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dumped = scrollNodes('vertical');
      expect(dumped, hasLength(1));
      expect(dumped.single['key'], 'sheet_list');
      expect(dumped.single['scrollIndex'], 0);
      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(1));
      expectOneNumbering(Axis.vertical);

      // The page's list is twice the sheet's area: counted, it would win
      // the auto-pick and the swipe would land on the barrier.
      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 200));
      expect(sheet.offset, greaterThan(0));
      expect(under.offset, 0);
    });

    testWidgets(
        'a dialog without a list: no vertical scrollable, and a '
        'direction-only swipe fails loudly', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      showDialog<void>(
        context: nav.currentContext!,
        builder: (_) => const Dialog(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Saved'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(scrollNodes('vertical'), isEmpty);
      expect(walker.findVisibleScrollables(Axis.vertical), isEmpty);

      // The advice names what may be in the way; it does not send the
      // reader to a keyed swipe, which would land on the dialog's barrier.
      expect(
        await failureOf(tester, () => dispatcher.swipeAuto('up', 300)),
        allOf(
          contains('No vertical scrollable is visible to scroll "up"'),
          contains('a dialog, bottom sheet, menu or page over the list'),
          contains('wait_idle'),
          isNot(contains('key')),
        ),
      );
      expect(under.offset, 0);
      expect(find.text('Saved'), findsOneWidget,
          reason: 'nothing was swiped: the dialog is still open');
    });

    testWidgets('a dropdown menu (a PopupRoute): only the menu\'s list counts',
        (tester) async {
      final under = _controller();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              DropdownButton<int>(
                value: 0,
                onChanged: (_) {},
                items: [
                  for (var i = 0; i < 30; i++)
                    DropdownMenuItem(value: i, child: Text('option $i')),
                ],
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('under_list'),
                  controller: under,
                  children: [
                    for (var i = 0; i < 40; i++)
                      SizedBox(height: 60, child: Text('under $i')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ));
      await tester.tap(find.text('option 0'));
      await tester.pumpAndSettle();

      final counted = walker.findVisibleScrollables(Axis.vertical);
      expect(counted, hasLength(1));
      expect(
        find.ancestor(
          of: find.byWidget(counted.single.widget),
          matching: find.byKey(const ValueKey('under_list')),
        ),
        findsNothing,
        reason: 'the counted list is the menu\'s, not the page\'s',
      );
      expectOneNumbering(Axis.vertical);
    });

    testWidgets(
        'while a page is pushed, the page it is covering is no longer '
        'counted', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final top = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('top', top),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(walker.isTransitioning, isTrue,
          reason: 'the push must still be running for this check');

      final underScrollable = tester.element(find.descendant(
        of: find.byKey(const ValueKey('under_list')),
        matching: find.byType(Scrollable),
      ));
      expect(walker.findVisibleScrollables(Axis.vertical),
          isNot(contains(underScrollable)));
      expectOneNumbering(Axis.vertical);
    }, variant: _platforms);

    testWidgets(
        'popping back: the closing page\'s list leaves at once and the first '
        'page\'s list is scrollIndex 0 again', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final top = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('top', top),
      ));
      await tester.pumpAndSettle();

      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(walker.isTransitioning, isTrue,
          reason: 'the pop must still be running for this check');
      final topScrollable = tester.element(find.descendant(
        of: find.byKey(const ValueKey('top_list')),
        matching: find.byType(Scrollable),
      ));
      expect(walker.findVisibleScrollables(Axis.vertical),
          isNot(contains(topScrollable)),
          reason: 'a closing route is hidden');
      expectOneNumbering(Axis.vertical);

      await tester.pumpAndSettle();
      final dumped = scrollNodes('vertical');
      expect(dumped, hasLength(1));
      expect(dumped.single['key'], 'under_list');
      expect(dumped.single['scrollIndex'], 0);
      await _pumpAndAwait(tester, () => dispatcher.swipeAtIndex(0, 'up', 300));
      expect(under.offset, greaterThan(0));
    }, variant: _platforms);

    testWidgets(
        'horizontal: a rail on a covered page is not counted, the top '
        'page\'s rail is scrollIndex 0', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final top = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under, axis: Axis.horizontal),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('top', top, axis: Axis.horizontal),
      ));
      await tester.pumpAndSettle();

      final dumped = scrollNodes('horizontal');
      expect(dumped, hasLength(1));
      expect(dumped.single['key'], 'top_list');
      expect(dumped.single['scrollIndex'], 0);
      expect(walker.findVisibleScrollables(Axis.horizontal), hasLength(1));
      expectOneNumbering(Axis.horizontal);

      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('left', 300));
      expect(top.offset, greaterThan(0));
      expect(under.offset, 0);
    }, variant: _platforms);

    testWidgets(
        'two lists on the same visible page keep their order and indexes',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final left = _controller();
      final right = _controller();
      Widget list(String name, ScrollController c) => Expanded(
            child: ListView(
              key: ValueKey('${name}_list'),
              controller: c,
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(height: 60, child: Text('$name $i')),
              ],
            ),
          );
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Row(children: [list('left', left), list('right', right)]),
        ),
      ));
      await tester.pumpAndSettle();

      final dumped = scrollNodes('vertical');
      expect(dumped.map((n) => n['key']).toList(), ['left_list', 'right_list']);
      expect(dumped.map((n) => n['scrollIndex']).toList(), [0, 1]);
      expectOneNumbering(Axis.vertical);

      await _pumpAndAwait(tester, () => dispatcher.swipeAtIndex(1, 'up', 300));
      expect(right.offset, greaterThan(0));
      expect(left.offset, 0);
      expect(under.offset, 0);
      expect(
        await failureOf(tester, () => dispatcher.swipeAuto('up', 300)),
        allOf(
          contains('Ambiguous scroll: 2 vertical scrollables'),
          contains('scrollIndex 0'),
          contains('scrollIndex 1'),
        ),
      );
    }, variant: _platforms);
  });

  group('a list covered at every point takes no number', () {
    // The dump drops a node covered at every sample point; the shared
    // filter does too, so the index has no gap and the auto-pick never
    // swipes a list whose centre is under something else.
    testWidgets('a painted loading layer over the only list', (tester) async {
      final list = _controller();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ListView(
                controller: list,
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 60, child: Text('row $i')),
                ],
              ),
              const Positioned.fill(
                child: AbsorbPointer(child: ColoredBox(color: Colors.white)),
              ),
            ],
          ),
        ),
      ));

      expect(scrollNodes('vertical'), isEmpty);
      expect(walker.findVisibleScrollables(Axis.vertical), isEmpty);
      expect(
        await failureOf(tester, () => dispatcher.swipeAuto('up', 300)),
        contains('No vertical scrollable is visible to scroll "up"'),
      );
      expect(list.offset, 0);
    });

    testWidgets('a partly covered list keeps its number', (tester) async {
      final list = _controller();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ListView(
                key: const ValueKey('rows_list'),
                controller: list,
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 60, child: Text('row $i')),
                ],
              ),
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 200,
                child: AbsorbPointer(child: ColoredBox(color: Colors.white)),
              ),
            ],
          ),
        ),
      ));

      final dumped = scrollNodes('vertical');
      expect(dumped, hasLength(1));
      expect(dumped.single['key'], 'rows_list');
      expect(dumped.single['partial'], isTrue);
      expect(dumped.single['scrollIndex'], 0);
      expectOneNumbering(Axis.vertical);
    });
  });

  group('a route that hides its page is pruned, not merely covered', () {
    // A page that does not hit-test everywhere covers nothing between its
    // widgets: only the route rule keeps the page underneath out.
    testWidgets('an opaque route with a bare page over a list page',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        onGenerateRoute: (_) => PageRouteBuilder<void>(
          pageBuilder: (context, animation, secondary) =>
              _listPage('under', under),
        ),
      ));
      nav.currentState!.push(PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondary) =>
            const Center(child: Text('bare')),
      ));
      await tester.pumpAndSettle();

      expect(walker.findVisibleScrollables(Axis.vertical), isEmpty);
      expect(scrollNodes('vertical'), isEmpty);
      expect(
        await failureOf(tester, () => dispatcher.swipeAuto('up', 300)),
        contains('No vertical scrollable is visible to scroll "up"'),
      );
      expect(under.offset, 0);
    });

    testWidgets(
        'nested navigators: a push inside a tab hides only that tab\'s page; '
        'a root dialog hides everything', (tester) async {
      final root = GlobalKey<NavigatorState>();
      final tab = GlobalKey<NavigatorState>();
      final side = _controller();
      final tab1 = _controller();
      final tab2 = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: root,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: ListView(
                  key: const ValueKey('side_list'),
                  controller: side,
                  children: [
                    for (var i = 0; i < 40; i++)
                      SizedBox(height: 60, child: Text('side $i')),
                  ],
                ),
              ),
              Expanded(
                child: ClipRect(
                  child: Navigator(
                    key: tab,
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => _listPage('tab1', tab1),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ));
      expect(scrollNodes('vertical').map((n) => n['key']).toList(),
          ['side_list', 'tab1_list']);

      tab.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('tab2', tab2),
      ));
      await tester.pumpAndSettle();
      final dumped = scrollNodes('vertical');
      expect(dumped.map((n) => n['key']).toList(), ['side_list', 'tab2_list']);
      expect(dumped.map((n) => n['scrollIndex']).toList(), [0, 1]);
      expectOneNumbering(Axis.vertical);
      await _pumpAndAwait(tester, () => dispatcher.swipeAtIndex(1, 'up', 300));
      expect(tab2.offset, greaterThan(0));
      expect(tab1.offset, 0);
      expect(side.offset, 0);

      showDialog<void>(
        context: root.currentContext!,
        builder: (_) => const Dialog(child: Text('Root dialog')),
      );
      await tester.pumpAndSettle();
      expect(walker.findVisibleScrollables(Axis.vertical), isEmpty);
      expect(scrollNodes('vertical'), isEmpty);
    }, variant: _platforms);

    testWidgets('an open drawer: only the drawer\'s list counts',
        (tester) async {
      final scaffold = GlobalKey<ScaffoldState>();
      final body = _controller();
      final drawer = _controller();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          key: scaffold,
          drawer: Drawer(
            child: ListView(
              key: const ValueKey('drawer_list'),
              controller: drawer,
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(height: 60, child: Text('menu $i')),
              ],
            ),
          ),
          body: ListView(
            key: const ValueKey('body_list'),
            controller: body,
            children: [
              for (var i = 0; i < 40; i++)
                SizedBox(height: 60, child: Text('body $i')),
            ],
          ),
        ),
      ));
      scaffold.currentState!.openDrawer();
      await tester.pumpAndSettle();

      final dumped = scrollNodes('vertical');
      expect(dumped.map((n) => n['key']).toList(), ['drawer_list']);
      expect(dumped.single['scrollIndex'], 0);
      expectOneNumbering(Axis.vertical);
      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));
      expect(drawer.offset, greaterThan(0));
      expect(body.offset, 0);
    });

    testWidgets('the incoming list is counted while it slides in',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final top = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('top', top),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(walker.isTransitioning, isTrue,
          reason: 'the push must still be running for this check');

      final topScrollable = tester.element(find.descendant(
        of: find.byKey(const ValueKey('top_list')),
        matching: find.byType(Scrollable),
      ));
      expect(walker.findVisibleScrollables(Axis.vertical), [topScrollable]);
      expect(scrollNodes('vertical').single['key'], 'top_list');
    }, variant: _platforms);
  });

  group('a translucent layer covers only where it paints', () {
    Widget overList(ScrollController list, Widget layer) => MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ListView(
                  key: const ValueKey('rows_list'),
                  controller: list,
                  children: [
                    for (var i = 0; i < 40; i++)
                      SizedBox(height: 60, child: Text('row $i')),
                  ],
                ),
                Positioned.fill(child: layer),
              ],
            ),
          ),
        );

    testWidgets('a tap-catching layer with a banner at the top',
        (tester) async {
      final list = _controller();
      await tester.pumpWidget(overList(
        list,
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {},
          child: const Align(
            alignment: Alignment.topCenter,
            child: Text('Offline banner'),
          ),
        ),
      ));

      final dumped = scrollNodes('vertical');
      expect(dumped.map((n) => n['key']).toList(), ['rows_list']);
      expect(dumped.single['scrollIndex'], 0);
      expect(dumped.single['partial'], isNull);
      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(1));
      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));
      expect(list.offset, greaterThan(0));
    });

    testWidgets('a pointer layer with a mini player at the bottom',
        (tester) async {
      final list = _controller();
      await tester.pumpWidget(overList(
        list,
        Listener(
          behavior: HitTestBehavior.translucent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Container(
                height: 60,
                color: Colors.black,
                child: const Text('Mini player'),
              ),
            ],
          ),
        ),
      ));

      final dumped = scrollNodes('vertical');
      expect(dumped.map((n) => n['key']).toList(), ['rows_list']);
      expect(dumped.single['scrollIndex'], 0);
      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(1));
      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));
      expect(list.offset, greaterThan(0));
    });

    testWidgets('a player painted over the lower part makes the list partial',
        (tester) async {
      final list = _controller();
      await tester.pumpWidget(overList(
        list,
        Listener(
          behavior: HitTestBehavior.translucent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Container(
                height: 200,
                color: Colors.black,
                child: const Text('Mini player'),
              ),
            ],
          ),
        ),
      ));

      final dumped = scrollNodes('vertical');
      expect(dumped.map((n) => n['key']).toList(), ['rows_list']);
      expect(dumped.single['partial'], isTrue);
      expect(dumped.single['scrollIndex'], 0);
      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(1));
      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));
      expect(list.offset, greaterThan(0));
    });

    testWidgets(
        'a scrim painted under a pointer layer still covers what it paints '
        'over, though the pointer passes through', (tester) async {
      final list = _controller();
      await tester.pumpWidget(overList(
        list,
        Listener(
          behavior: HitTestBehavior.translucent,
          child: const IgnorePointer(
            child: ColoredBox(color: Colors.black54),
          ),
        ),
      ));

      expect(scrollNodes('vertical'), isEmpty);
      expect(walker.findVisibleScrollables(Axis.vertical), isEmpty);
    });

    testWidgets(
        'a layer too deep to prove clear at a point counts as painting '
        'there', (tester) async {
      final list = _controller();
      Widget layer = const SizedBox.expand();
      for (var i = 0; i < 80; i++) {
        layer = Padding(padding: EdgeInsets.zero, child: layer);
      }
      await tester.pumpWidget(overList(
        list,
        Listener(behavior: HitTestBehavior.translucent, child: layer),
      ));

      expect(walker.findVisibleScrollables(Axis.vertical), isEmpty,
          reason: 'a clear view that was not proven is never claimed');
    });

    testWidgets(
        'a button under a banner tap layer is visible, and the tap gate '
        'still refuses it', (tester) async {
      var payTaps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Center(
                child: ElevatedButton(
                  onPressed: () => payTaps++,
                  child: const Text('Pay'),
                ),
              ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: const Align(
                    alignment: Alignment.topCenter,
                    child: Text('Offline banner'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ));

      expect(walker.checkTextVisible('Pay').visible, isTrue);
      expect(
        _flatten(walker.dumpVisibleTree()['elements'] as List)
            .map((n) => n['text']),
        contains('Pay'),
      );
      expect(
        await failureOf(tester, () => dispatcher.tap(text: 'Pay')),
        contains('GestureDetector "Offline banner"'),
      );
      expect(payTaps, 0);
    });
  });

  group('a scroll gesture starts where it lands', () {
    testWidgets('a list whose centre is under a card is swiped where it shows',
        (tester) async {
      final list = _controller();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ListView(
                controller: list,
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 60, child: Text('row $i')),
                ],
              ),
              Center(
                child: Container(width: 300, height: 200, color: Colors.white),
              ),
            ],
          ),
        ),
      ));

      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(1));
      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));
      expect(list.offset, greaterThan(0));
      await _pumpAndAwait(tester, () => dispatcher.swipeAtIndex(0, 'up', 300));
      expect(list.offset, greaterThan(300));
    });

    testWidgets(
        'a list no pointer reaches is refused, not swiped blind '
        '(a tap layer over all of it)', (tester) async {
      final list = _controller();
      var layerTaps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ListView(
                controller: list,
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 60, child: Text('row $i')),
                ],
              ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => layerTaps++,
                ),
              ),
            ],
          ),
        ),
      ));

      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(1),
          reason: 'the layer paints nothing: the list is in view');
      expect(
        await failureOf(tester, () => dispatcher.swipeAuto('up', 300)),
        allOf(
          contains('Cannot swipe the vertical scrollable at scrollIndex 0'),
          contains('GestureDetector'),
        ),
      );
      expect(list.offset, 0);
    });

    // On iOS the page sliding in shows only its left edge 16 ms in (x
    // 768..800 of 800), and 48 ms into a pop the returning page's centre is
    // still under the page sliding away: a swipe at the unclipped centre
    // reported success and moved nothing. Pointers are not ignored at
    // these frames, so the swipe can land, and must.
    testWidgets('16 ms into a push, the incoming list is swiped where it shows',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final top = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('top', top),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(walker.isTransitioning, isTrue);
      final counted = walker.findVisibleScrollables(Axis.vertical);
      expect(counted, hasLength(1));
      expect(walker.centerOfElement(counted.single)?.dx, greaterThan(800),
          reason: 'the unclipped centre is off screen at this frame');

      await _pumpAndAwait(tester, () => dispatcher.swipeAuto('up', 300));
      expect(top.offset, greaterThan(0));
      expect(under.offset, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('48 ms into a pop, the returning list is swiped where it shows',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final under = _controller();
      final top = _controller();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: _listPage('under', under),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => _listPage('top', top),
      ));
      await tester.pumpAndSettle();
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      expect(walker.isTransitioning, isTrue);
      expect(walker.findVisibleScrollables(Axis.vertical), hasLength(1));
      expect(scrollNodes('vertical').single['partial'], isTrue,
          reason: 'the page sliding away still covers the centre');

      await _pumpAndAwait(tester, () => dispatcher.swipeAtIndex(0, 'up', 300));
      expect(under.offset, greaterThan(0));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
