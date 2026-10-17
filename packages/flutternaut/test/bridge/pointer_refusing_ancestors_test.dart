import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/gesture_dispatcher.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/models/action_failure.dart';

/// The hit-test gate when an ancestor of a label refuses the pointer with a
/// hit test of its own (not an `IgnorePointer`), or when the ancestor that
/// takes the pointer handles no taps.
///
/// The Beanz incident (2026-10-13): a Profile page drawn under
/// `Skeletonizer(ignorePointers: true)` showed placeholder rows reading
/// "Edit account details". `RenderSkeletonizer.hitTest` returns false, so the
/// frontmost hit was the page's `Material` ink layer. The gate took that
/// ancestor for one that takes the tap itself and reported
/// `reached _InkFeatures "+971 55 111 5152"` (the page's first text) while
/// the tap did nothing.

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

Future<T> _pumpAndAwait<T>(
  WidgetTester tester,
  Future<T> Function() work,
) async {
  final completer = Completer<T>();
  work().then(completer.complete, onError: completer.completeError);
  const step = Duration(milliseconds: 50);
  for (var i = 0; i < 200 && !completer.isCompleted; i++) {
    await tester.pump(step);
  }
  return completer.future;
}

/// A box that refuses every pointer while [refusing] — what
/// `Skeletonizer(ignorePointers: true)` does, without depending on it.
class _RefusingBox extends SingleChildRenderObjectWidget {
  const _RefusingBox({required this.refusing, super.child});

  final bool refusing;

  @override
  _RenderRefusingBox createRenderObject(BuildContext context) =>
      _RenderRefusingBox(refusing);

  @override
  void updateRenderObject(BuildContext context, _RenderRefusingBox ro) {
    ro.refusing = refusing;
  }
}

class _RenderRefusingBox extends RenderProxyBox {
  _RenderRefusingBox(this.refusing);

  bool refusing;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (refusing) return false;
    return super.hitTest(result, position: position);
  }
}

/// The sliver form of [_RefusingBox] (`RenderSliverSkeletonizer`).
class _RefusingSliver extends SingleChildRenderObjectWidget {
  const _RefusingSliver({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRefusingSliver();
}

class _RenderRefusingSliver extends RenderProxySliver {
  @override
  bool hitTest(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) =>
      false;
}

void main() {
  late GestureDispatcher dispatcher;

  setUp(() {
    dispatcher = GestureDispatcher(TreeWalker());
  });

  testWidgets(
      'a placeholder label under a pointer-refusing box is refused, then the '
      'real row is tapped once the page has loaded', (tester) async {
    final loading = ValueNotifier(true);
    addTearDown(loading.dispose);
    var opened = false;
    await tester.pumpWidget(_app(ValueListenableBuilder<bool>(
      valueListenable: loading,
      builder: (_, isLoading, __) => _RefusingBox(
        refusing: isLoading,
        child: ListView(children: [
          const Text('+971 55 111 5152'),
          if (isLoading)
            const Text('Edit account details')
          else
            ListTile(
              title: const Text('Edit account details'),
              onTap: () => opened = true,
            ),
        ]),
      ),
    )));

    await expectLater(
      dispatcher.tap(text: 'Edit account details'),
      throwsA(isA<ActionFailure>().having(
        (e) => e.message,
        'message',
        allOf(contains('takes no taps'), contains('_RefusingBox')),
      )),
    );
    expect(opened, isFalse);

    loading.value = false;
    await tester.pump();
    final reached = await _pumpAndAwait(
        tester, () => dispatcher.tap(text: 'Edit account details'));
    expect(opened, isTrue);
    expect(reached, contains('"Edit account details"'));
  });

  testWidgets('a label under a pointer-refusing sliver is refused',
      (tester) async {
    await tester.pumpWidget(_app(const CustomScrollView(slivers: [
      _RefusingSliver(
        child: SliverToBoxAdapter(child: Text('Edit account details')),
      ),
    ])));

    await expectLater(
      dispatcher.tap(text: 'Edit account details'),
      throwsA(isA<ActionFailure>().having(
        (e) => e.message,
        'message',
        allOf(contains('takes no taps'), contains('_RefusingSliver')),
      )),
    );
  });

  group('an ancestor that takes the pointer itself', () {
    testWidgets(
        'is refused when it handles no taps, and is not named after the '
        "page's first text", (tester) async {
      // A keyed box draws and claims nothing, so the page's Material — which
      // hit-tests itself to absorb pointers — is the frontmost hit.
      await tester.pumpWidget(_app(const Column(children: [
        Text('+971 55 111 5152'),
        SizedBox(key: ValueKey('spacer'), width: 120, height: 48),
      ])));

      await expectLater(
        dispatcher.tap(key: 'spacer'),
        throwsA(isA<ActionFailure>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('takes no taps'),
            contains('handles no taps'),
            isNot(contains('+971')),
          ),
        )),
      );
    });

    testWidgets('is tapped when it is a tap handler', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => tapped = true,
          child: const SizedBox(key: ValueKey('slot'), width: 120, height: 48),
        ),
      )));

      await _pumpAndAwait(tester, () => dispatcher.tap(key: 'slot'));
      expect(tapped, isTrue);
    });

    testWidgets('is tapped when a tile handler wraps its painted box',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(_app(Center(
        child: InkWell(
          onTap: () => tapped = true,
          child: const ColoredBox(
            color: Color(0xFFEEEEEE),
            child: SizedBox(key: ValueKey('slot'), width: 120, height: 48),
          ),
        ),
      )));

      await _pumpAndAwait(tester, () => dispatcher.tap(key: 'slot'));
      expect(tapped, isTrue);
    });
  });
}
