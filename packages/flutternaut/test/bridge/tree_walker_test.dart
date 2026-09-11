// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/src/bridge/engine/tree_walker.dart';

Widget _app(Widget body) {
  return MaterialApp(home: Scaffold(body: body));
}

void main() {
  final walker = TreeWalker();

  group('findByKey', () {
    testWidgets('returns element with correct type', (tester) async {
      await tester.pumpWidget(_app(
        ElevatedButton(
          key: const ValueKey('btn'),
          onPressed: () {},
          child: const Text('Tap Me'),
        ),
      ));

      final info = walker.findByKey('btn');
      expect(info, isNotNull);
      expect(info!.type, 'ElevatedButton');
    });

    testWidgets('returns correct text from child', (tester) async {
      await tester.pumpWidget(_app(
        ElevatedButton(
          key: const ValueKey('btn'),
          onPressed: () {},
          child: const Text('Tap Me'),
        ),
      ));

      final info = walker.findByKey('btn');
      expect(info!.text, 'Tap Me');
    });

    testWidgets('returns rect with position', (tester) async {
      await tester.pumpWidget(_app(
        ElevatedButton(
          key: const ValueKey('btn'),
          onPressed: () {},
          child: const Text('Tap Me'),
        ),
      ));

      final info = walker.findByKey('btn');
      expect(info!.rect, isNotNull);
      expect(info.rect!.width, greaterThan(0));
      expect(info.rect!.height, greaterThan(0));
    });

    testWidgets('returns null for missing key', (tester) async {
      await tester.pumpWidget(_app(const Text('Hello')));

      final info = walker.findByKey('nonexistent');
      expect(info, isNull);
    });
  });

  group('findByText', () {
    testWidgets('finds Text widget by exact match', (tester) async {
      await tester.pumpWidget(_app(const Text('Hello World')));

      final info = walker.findByText('Hello World');
      expect(info, isNotNull);
      expect(info!.type, 'Text');
      expect(info.text, 'Hello World');
    });

    testWidgets('returns null for non-matching text', (tester) async {
      await tester.pumpWidget(_app(const Text('Hello')));

      final info = walker.findByText('World');
      expect(info, isNull);
    });

    testWidgets('finds Text.rich by its concatenated text', (tester) async {
      await tester.pumpWidget(_app(
        const Text.rich(TextSpan(children: [
          TextSpan(text: 'Sign in '),
          TextSpan(text: 'to continue'),
        ])),
      ));

      final info = walker.findByText('Sign in to continue');
      expect(info, isNotNull);
      expect(info!.text, 'Sign in to continue');
    });

    testWidgets('finds a RichText by its visible text', (tester) async {
      await tester.pumpWidget(_app(
        RichText(
          text: const TextSpan(children: [
            TextSpan(text: 'Already? '),
            TextSpan(text: 'Log in'),
          ]),
        ),
      ));

      expect(walker.findByText('Already? Log in'), isNotNull);
    });
  });

  group('findByTextContains', () {
    testWidgets('finds by substring', (tester) async {
      await tester.pumpWidget(_app(const Text('Hello World')));

      final info = walker.findByTextContains('World');
      expect(info, isNotNull);
      expect(info!.text, 'Hello World');
    });

    testWidgets('returns null if no match', (tester) async {
      await tester.pumpWidget(_app(const Text('Hello')));

      final info = walker.findByTextContains('xyz');
      expect(info, isNull);
    });

    testWidgets('matches a substring of rich text', (tester) async {
      await tester.pumpWidget(_app(
        const Text.rich(TextSpan(children: [
          TextSpan(text: "Don't have an account? "),
          TextSpan(text: 'Sign up'),
        ])),
      ));

      expect(walker.findByTextContains('Sign up'), isNotNull);
    });

    testWidgets('is case-insensitive', (tester) async {
      await tester.pumpWidget(_app(const Text('Log in')));

      expect(walker.findByTextContains('LOG IN'), isNotNull);
      expect(walker.findByTextContains('log'), isNotNull);
      // exact match stays case-sensitive
      expect(walker.findByText('log in'), isNull);
    });
  });

  group('findAllKeyed', () {
    testWidgets('returns all ValueKey elements', (tester) async {
      await tester.pumpWidget(_app(Column(
        children: [
          const Text('no key'),
          const Text('a', key: ValueKey('key_a')),
          const Text('b', key: ValueKey('key_b')),
        ],
      )));

      final results = walker.findAllKeyed();
      final userKeys =
          results.where((e) => e.key?.startsWith('key_') ?? false).toList();
      expect(userKeys.length, 2);
    });
  });

  group('checkTextVisible', () {
    testWidgets('returns visible for on-screen text', (tester) async {
      await tester.pumpWidget(_app(const Text('Visible')));

      final result = walker.checkTextVisible('Visible');
      expect(result.exists, isTrue);
      expect(result.visible, isTrue);
    });

    testWidgets('returns not-found for missing text', (tester) async {
      await tester.pumpWidget(_app(const Text('Hello')));

      final result = walker.checkTextVisible('Missing');
      expect(result.exists, isFalse);
      expect(result.visible, isFalse);
    });
  });

  group('checkVisibleByKey', () {
    testWidgets('returns visible for on-screen element', (tester) async {
      await tester.pumpWidget(_app(
        const Text('Hi', key: ValueKey('txt')),
      ));

      final result = walker.checkVisibleByKey('txt');
      expect(result.exists, isTrue);
      expect(result.visible, isTrue);
    });

    testWidgets('returns not-found for missing key', (tester) async {
      await tester.pumpWidget(_app(const Text('Hi')));

      final result = walker.checkVisibleByKey('missing');
      expect(result.exists, isFalse);
      expect(result.visible, isFalse);
    });
  });

  group('occlusion-aware visibility', () {
    testWidgets('a clear element is on screen, unobstructed, visible',
        (tester) async {
      await tester.pumpWidget(_app(
        const Center(child: Text('Clear', key: ValueKey('clear'))),
      ));

      final result = walker.checkVisibleByKey('clear');
      expect(result.onScreen, isTrue);
      expect(result.obstructed, isFalse);
      expect(result.visible, isTrue);
    });

    testWidgets('an element covered by an opaque overlay is obstructed',
        (tester) async {
      await tester.pumpWidget(_app(
        Stack(
          children: [
            const Center(child: Text('Behind', key: ValueKey('behind'))),
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

      final result = walker.checkVisibleByKey('behind');
      expect(result.exists, isTrue);
      expect(result.onScreen, isTrue, reason: 'still laid out on screen');
      expect(result.obstructed, isTrue, reason: 'covered by the overlay');
      expect(result.visible, isFalse, reason: 'not visible to the user');
    });

    testWidgets('an element under a bottom bar is obstructed', (tester) async {
      await tester.pumpWidget(_app(
        Stack(
          children: [
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                key: const ValueKey('row'),
                height: 50,
                color: const Color(0xFF2196F3),
                child: const Text('Row'),
              ),
            ),
            // A bottom bar painted on top, overlapping the row.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(height: 80, color: const Color(0xFF000000)),
              ),
            ),
          ],
        ),
      ));

      final result = walker.checkVisibleByKey('row');
      expect(result.onScreen, isTrue);
      expect(result.obstructed, isTrue);
      expect(result.visible, isFalse);
    });

    testWidgets('an off-screen element is not on screen and not visible',
        (tester) async {
      await tester.pumpWidget(_app(
        Transform.translate(
          offset: const Offset(0, 5000),
          child: const Text('Far', key: ValueKey('far')),
        ),
      ));

      final result = walker.checkVisibleByKey('far');
      expect(result.exists, isTrue);
      expect(result.onScreen, isFalse);
      expect(result.visible, isFalse);
    });
  });

  group('extractInfo - enabled state', () {
    testWidgets('detects enabled ElevatedButton', (tester) async {
      await tester.pumpWidget(_app(
        ElevatedButton(
          key: const ValueKey('btn'),
          onPressed: () {},
          child: const Text('Tap'),
        ),
      ));

      final info = walker.findByKey('btn');
      expect(info!.enabled, isTrue);
    });

    testWidgets('detects disabled ElevatedButton', (tester) async {
      await tester.pumpWidget(_app(
        const ElevatedButton(
          key: ValueKey('btn'),
          onPressed: null,
          child: Text('Tap'),
        ),
      ));

      final info = walker.findByKey('btn');
      expect(info!.enabled, isFalse);
    });

    testWidgets('detects enabled TextField', (tester) async {
      await tester.pumpWidget(_app(
        const TextField(key: ValueKey('field')),
      ));

      final info = walker.findByKey('field');
      expect(info!.enabled, isTrue);
    });

    testWidgets('detects disabled TextField', (tester) async {
      await tester.pumpWidget(_app(
        const TextField(key: ValueKey('field'), enabled: false),
      ));

      final info = walker.findByKey('field');
      expect(info!.enabled, isFalse);
    });
  });

  group('extractInfo - checked state', () {
    testWidgets('detects checked Checkbox', (tester) async {
      await tester.pumpWidget(_app(
        Checkbox(
          key: const ValueKey('check'),
          value: true,
          onChanged: (_) {},
        ),
      ));

      final info = walker.findByKey('check');
      expect(info!.checked, isTrue);
    });

    testWidgets('detects unchecked Checkbox', (tester) async {
      await tester.pumpWidget(_app(
        Checkbox(
          key: const ValueKey('check'),
          value: false,
          onChanged: (_) {},
        ),
      ));

      final info = walker.findByKey('check');
      expect(info!.checked, isFalse);
    });

    testWidgets('detects Switch value', (tester) async {
      await tester.pumpWidget(_app(
        Switch(
          key: const ValueKey('sw'),
          value: true,
          onChanged: (_) {},
        ),
      ));

      final info = walker.findByKey('sw');
      expect(info!.checked, isTrue);
    });
  });

  group('extractText', () {
    testWidgets('reads Text.data', (tester) async {
      await tester.pumpWidget(_app(
        const Text('Hello', key: ValueKey('txt')),
      ));

      final info = walker.findByKey('txt');
      expect(info!.text, 'Hello');
    });

    testWidgets('reads nested Text inside a container', (tester) async {
      await tester.pumpWidget(_app(
        ElevatedButton(
          key: const ValueKey('btn'),
          onPressed: () {},
          child: const Text('Nested'),
        ),
      ));

      final info = walker.findByKey('btn');
      expect(info!.text, 'Nested');
    });
  });

  group('dumpTree', () {
    testWidgets('produces structured output', (tester) async {
      await tester.pumpWidget(_app(
        const Text('Hello', key: ValueKey('txt')),
      ));

      final tree = walker.dumpTree(maxDepth: 5);
      expect(tree, isA<Map<String, dynamic>>());
      expect(tree['type'], isNotEmpty);
    });
  });

  group('dumpVisibleTree', () {
    List<Map<String, dynamic>> flatten(List<dynamic> elements) {
      final out = <Map<String, dynamic>>[];
      for (final e in elements.cast<Map<String, dynamic>>()) {
        out.add(e);
        if (e['children'] is List) {
          out.addAll(flatten(e['children'] as List));
        }
      }
      return out;
    }

    testWidgets('reports the screen size', (tester) async {
      await tester.pumpWidget(_app(const Text('hi')));
      final dump = walker.dumpVisibleTree();
      expect(dump['screen'], isA<Map<String, dynamic>>());
      final screen = dump['screen'] as Map<String, dynamic>;
      expect(screen['w'], greaterThan(0));
      expect(screen['h'], greaterThan(0));
    });

    testWidgets('finds a deeply-nested keyed field (no depth cap)',
        (tester) async {
      // 40 layers of pure wrappers around the real field — far past
      // dumpTree's old maxDepth of 30.
      Widget nested = TextField(
        key: const ValueKey('deep_field'),
        controller: TextEditingController(text: 'khaled'),
      );
      for (var i = 0; i < 40; i++) {
        nested = Padding(padding: EdgeInsets.zero, child: nested);
      }
      await tester.pumpWidget(_app(nested));

      final all = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      );
      final field = all.firstWhere(
        (e) => e['key'] == 'deep_field',
        orElse: () => <String, dynamic>{},
      );
      expect(field['type'], 'TextField');
      expect(field['rect'], isA<Map<String, dynamic>>());
    });

    testWidgets('prunes pure wrappers but keeps meaningful descendants',
        (tester) async {
      await tester.pumpWidget(_app(
        const Padding(
          padding: EdgeInsets.all(8),
          child: Center(child: Text('hello', key: ValueKey('greeting'))),
        ),
      ));

      final all = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      );
      final types = all.map((e) => e['type']).toSet();
      expect(types, contains('Text'));
      expect(types, isNot(contains('Padding')));
      expect(types, isNot(contains('Center')));
      final greeting =
          all.firstWhere((e) => e['key'] == 'greeting');
      expect(greeting['text'], 'hello');
    });

    testWidgets('excludes offstage and off-viewport widgets',
        (tester) async {
      await tester.pumpWidget(_app(
        Stack(
          children: [
            const Text('on_screen', key: ValueKey('visible_txt')),
            const Offstage(
              child: Text('hidden', key: ValueKey('offstage_txt')),
            ),
            // Pushed far below the viewport.
            Transform.translate(
              offset: const Offset(0, 9000),
              child: const Text('far', key: ValueKey('off_view_txt')),
            ),
          ],
        ),
      ));

      final keys = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      ).map((e) => e['key']).toSet();
      expect(keys, contains('visible_txt'));
      expect(keys, isNot(contains('offstage_txt')));
      expect(keys, isNot(contains('off_view_txt')));
    });

    testWidgets('a button carries its label text', (tester) async {
      await tester.pumpWidget(_app(
        ElevatedButton(
          key: const ValueKey('go'),
          onPressed: () {},
          child: const Text('Continue'),
        ),
      ));

      final all = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      );
      final btn = all.firstWhere((e) => e['key'] == 'go');
      expect(btn['text'], 'Continue');
      expect(btn['enabled'], isTrue);
    });

    testWidgets('structural wrappers carry no bubbled text',
        (tester) async {
      await tester.pumpWidget(_app(
        KeyedSubtree(
          key: const ValueKey('group'),
          child: const Column(
            children: [Text('Inner', key: ValueKey('inner'))],
          ),
        ),
      ));

      final all = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      );
      final wrapper = all.firstWhere((e) => e['key'] == 'group');
      expect(wrapper.containsKey('text'), isFalse,
          reason: 'KeyedSubtree must not inherit "Inner"');
      final inner = all.firstWhere((e) => e['key'] == 'inner');
      expect(inner['text'], 'Inner');
    });

    testWidgets('a Text emits one node, not a Text + child RichText',
        (tester) async {
      await tester.pumpWidget(_app(const Text('AL-Karmi')));

      final all = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      );
      final withText =
          all.where((e) => e['text'] == 'AL-Karmi').toList();
      expect(withText, hasLength(1),
          reason: 'the inner RichText echoing the label must be collapsed');
      expect(withText.single['type'], 'Text');
    });

    testWidgets('a labelled button collapses its inner gesture/text echoes',
        (tester) async {
      await tester.pumpWidget(_app(
        ElevatedButton(
          onPressed: () {},
          child: const Text('Get Started'),
        ),
      ));

      final all = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      );
      // The button + its internal GestureDetector/Text/RichText all carry
      // "Get Started"; only the outermost (the button) should survive.
      final labelled =
          all.where((e) => e['text'] == 'Get Started').toList();
      expect(labelled, hasLength(1),
          reason: 'one control must not become several identical refs');
      expect(labelled.single['enabled'], isTrue);
    });

    testWidgets('sibling controls sharing a label both survive',
        (tester) async {
      await tester.pumpWidget(_app(
        Row(
          children: [
            ElevatedButton(
              key: const ValueKey('edit_a'),
              onPressed: () {},
              child: const Text('Edit'),
            ),
            ElevatedButton(
              key: const ValueKey('edit_b'),
              onPressed: () {},
              child: const Text('Edit'),
            ),
          ],
        ),
      ));

      final keys = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      ).map((e) => e['key']).toSet();
      expect(keys, containsAll(<String>['edit_a', 'edit_b']),
          reason: 'dedup is per-branch, not global');
    });

    testWidgets('prunes a row scrolled out of a sub-viewport', (tester) async {
      // A short, fixed-height scroll viewport between a header and footer.
      // The last rows are laid out but clipped away by the list viewport,
      // even though their global rect still falls within the full screen.
      await tester.pumpWidget(_app(
        Column(
          children: [
            const SizedBox(
              height: 120,
              child: Center(child: Text('on_top', key: ValueKey('on_top'))),
            ),
            SizedBox(
              height: 80,
              child: ListView(
                children: List.generate(
                  40,
                  (i) => SizedBox(
                    height: 40,
                    child: Text('row_$i', key: ValueKey('row_$i')),
                  ),
                ),
              ),
            ),
          ],
        ),
      ));

      final keys = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      ).map((e) => e['key']).toSet();
      expect(keys, contains('on_top'));
      expect(keys, contains('row_0'),
          reason: 'the first row is inside the 80px viewport');
      expect(keys, isNot(contains('row_30')),
          reason: 'rows scrolled out of the sub-viewport must be pruned');
    });

    testWidgets('prunes a widget hidden behind an opaque overlay',
        (tester) async {
      await tester.pumpWidget(_app(
        Stack(
          children: [
            const Center(child: Text('under', key: ValueKey('under'))),
            // An opaque full-screen overlay on top: it is the frontmost thing
            // hit-tested at the text's center, from an unrelated branch.
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

      final keys = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      ).map((e) => e['key']).toSet();
      expect(keys, isNot(contains('under')),
          reason: 'content behind an opaque overlay is not visible');
    });

    testWidgets('prunes a fully transparent (Opacity 0) widget',
        (tester) async {
      await tester.pumpWidget(_app(
        const Stack(
          children: [
            Text('shown', key: ValueKey('shown')),
            Opacity(
              opacity: 0,
              child: Text('faded', key: ValueKey('faded')),
            ),
          ],
        ),
      ));

      final keys = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      ).map((e) => e['key']).toSet();
      expect(keys, contains('shown'));
      expect(keys, isNot(contains('faded')),
          reason: 'an opacity-0 widget is not visible');
    });

    testWidgets('keeps a half-transparent (Opacity 0.5) widget',
        (tester) async {
      await tester.pumpWidget(_app(
        const Opacity(
          opacity: 0.5,
          child: Text('half', key: ValueKey('half')),
        ),
      ));

      final keys = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      ).map((e) => e['key']).toSet();
      expect(keys, contains('half'),
          reason: 'a clearly-visible (50%) widget must be kept');
    });

    testWidgets('FadeTransition: pruned at 0, kept at 1', (tester) async {
      final faded = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      ); // value 0 by default
      final shown = AnimationController(
        vsync: tester,
        value: 1,
        duration: const Duration(seconds: 1),
      );
      addTearDown(faded.dispose);
      addTearDown(shown.dispose);

      await tester.pumpWidget(_app(
        Stack(
          children: [
            FadeTransition(
              opacity: shown,
              child: const Text('visible', key: ValueKey('fade_in')),
            ),
            FadeTransition(
              opacity: faded,
              child: const Text('gone', key: ValueKey('fade_out')),
            ),
          ],
        ),
      ));

      final keys = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      ).map((e) => e['key']).toSet();
      expect(keys, contains('fade_in'));
      expect(keys, isNot(contains('fade_out')),
          reason: 'a FadeTransition at opacity 0 is invisible');
    });

    testWidgets('reports enabled:false for a disabled custom button',
        (tester) async {
      // Mirrors PrimaryCButton: a labelled custom button whose enabled state
      // lives on an inner GestureDetector (onTap null when disabled), dimmed
      // to 0.45 opacity (still visible).
      Widget customButton({required bool enabled}) => Opacity(
            opacity: enabled ? 1 : 0.45,
            child: GestureDetector(
              onTap: enabled ? () {} : null,
              child: const Text('Create Account'),
            ),
          );

      await tester.pumpWidget(_app(Column(
        children: [
          customButton(enabled: false),
          customButton(enabled: true),
        ],
      )));

      final btns = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      ).where((e) => e['text'] == 'Create Account').toList();
      expect(btns, hasLength(2), reason: 'both buttons are visible (0.45 > 0)');
      expect(btns.any((e) => e['enabled'] == false), isTrue,
          reason: 'the disabled custom button must report enabled:false');
      expect(btns.any((e) => e['enabled'] == true), isTrue,
          reason: 'the enabled custom button must report enabled:true');
    });

    testWidgets('reports enabled state for Material buttons', (tester) async {
      await tester.pumpWidget(_app(Column(
        children: [
          ElevatedButton(
            key: const ValueKey('on'),
            onPressed: () {},
            child: const Text('On'),
          ),
          const ElevatedButton(
            key: ValueKey('off'),
            onPressed: null,
            child: Text('Off'),
          ),
        ],
      )));

      final all = flatten(
        (walker.dumpVisibleTree()['elements'] as List),
      );
      expect(all.firstWhere((e) => e['key'] == 'on')['enabled'], isTrue);
      expect(all.firstWhere((e) => e['key'] == 'off')['enabled'], isFalse);
    });

    testWidgets('reports the screen size in logical pixels', (tester) async {
      await tester.pumpWidget(_app(const Text('hi')));
      final screen =
          walker.dumpVisibleTree()['screen'] as Map<String, dynamic>;
      final view = tester.view;
      expect(
        (screen['w'] as num).toDouble(),
        closeTo(view.physicalSize.width / view.devicePixelRatio, 0.01),
      );
      expect(
        (screen['h'] as num).toDouble(),
        closeTo(view.physicalSize.height / view.devicePixelRatio, 0.01),
      );
    });
  });

  group('findControllerByText', () {
    testWidgets('resolves InputDecoration.labelText to its field',
        (tester) async {
      final controller = TextEditingController(text: 'seed');
      await tester.pumpWidget(_app(
        TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
      ));

      expect(walker.findControllerByText('Email'), same(controller));
    });

    testWidgets('resolves a sibling label to the field below it',
        (tester) async {
      final phone = TextEditingController();
      await tester.pumpWidget(_app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Name'),
            TextField(controller: TextEditingController()),
            const SizedBox(height: 24),
            const Text('Phone number'),
            TextField(controller: phone),
          ],
        ),
      ));

      expect(walker.findControllerByText('Phone number'), same(phone));
    });

    testWidgets('returns null when no field can be associated',
        (tester) async {
      await tester.pumpWidget(_app(
        const Column(children: [Text('Orphan')]),
      ));

      expect(walker.findControllerByText('Orphan'), isNull);
    });

    testWidgets('findEditableStateByText resolves the field state',
        (tester) async {
      await tester.pumpWidget(_app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Phone number'),
            TextField(controller: TextEditingController()),
          ],
        ),
      ));

      expect(walker.findEditableStateByText('Phone number'), isNotNull);
      expect(walker.findEditableStateByText('Nope'), isNull);
    });
  });

  group('dumpVisibleTree scrollables', () {
    List<Map<String, dynamic>> flatten(List<dynamic> elements) {
      final out = <Map<String, dynamic>>[];
      for (final e in elements.cast<Map<String, dynamic>>()) {
        out.add(e);
        if (e['children'] is List) {
          out.addAll(flatten(e['children'] as List));
        }
      }
      return out;
    }

    List<Map<String, dynamic>> scrollablesIn(Map<String, dynamic> dump) {
      return flatten(dump['elements'] as List)
          .where((e) => e['scrollable'] == true)
          .toList();
    }

    /// All `text` values in [node]'s subtree (node itself included).
    Set<String> subtreeTexts(Map<String, dynamic> node) {
      return flatten([node])
          .map((e) => e['text'])
          .whereType<String>()
          .toSet();
    }

    testWidgets('a vertical ListView emits one scrollable node with metrics',
        (tester) async {
      await tester.pumpWidget(_app(
        ListView(
          children: [
            for (var i = 0; i < 30; i++)
              SizedBox(height: 80, child: Text('row $i')),
          ],
        ),
      ));

      final scrollables = scrollablesIn(walker.dumpVisibleTree());
      expect(scrollables, hasLength(1));
      final node = scrollables.single;
      expect(node['type'], 'ListView');
      expect(node['axis'], 'vertical');
      expect(node['scrollIndex'], 0);
      expect(node['scrollOffset'], 0.0);
      expect(node['maxScrollExtent'], greaterThan(0));
      expect(node['rect'], isA<Map<String, dynamic>>());
      // Visible rows nest inside the scrollable node, not beside it.
      expect(subtreeTexts(node), contains('row 0'));
    });

    testWidgets('a horizontal ListView reports axis horizontal',
        (tester) async {
      await tester.pumpWidget(_app(
        SizedBox(
          height: 100,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (var i = 0; i < 30; i++)
                SizedBox(width: 80, child: Text('col $i')),
            ],
          ),
        ),
      ));

      final node = scrollablesIn(walker.dumpVisibleTree()).single;
      expect(node['type'], 'ListView');
      expect(node['axis'], 'horizontal');
    });

    testWidgets('a PageView adopts the PageView type name', (tester) async {
      await tester.pumpWidget(_app(
        PageView(
          children: const [Text('page one'), Text('page two')],
        ),
      ));

      final node = scrollablesIn(walker.dumpVisibleTree()).single;
      expect(node['type'], 'PageView');
      expect(node['axis'], 'horizontal');
    });

    testWidgets('a keyed ListView surfaces its key on the scrollable node — '
        'and only there', (tester) async {
      await tester.pumpWidget(_app(
        ListView(
          key: const ValueKey('rail'),
          children: [
            for (var i = 0; i < 30; i++)
              SizedBox(height: 80, child: Text('row $i')),
          ],
        ),
      ));

      final dump = walker.dumpVisibleTree();
      final keyed = flatten(dump['elements'] as List)
          .where((e) => e['key'] == 'rail')
          .toList();
      expect(keyed, hasLength(1));
      expect(keyed.single['scrollable'], isTrue);
      expect(keyed.single['type'], 'ListView');
    });

    testWidgets('a non-overflowing SingleChildScrollView reports '
        'maxScrollExtent 0', (tester) async {
      await tester.pumpWidget(_app(
        const SingleChildScrollView(
          child: SizedBox(height: 100, child: Text('short content')),
        ),
      ));

      final node = scrollablesIn(walker.dumpVisibleTree()).single;
      expect(node['type'], 'SingleChildScrollView');
      expect(node['maxScrollExtent'], 0.0);
    });

    testWidgets(
        'a horizontal rail inside a CustomScrollView nests its items '
        'under the rail node', (tester) async {
      await tester.pumpWidget(_app(
        CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(child: Text('Popular items')),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 120,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: const [
                    SizedBox(width: 200, child: Text('JILBAB')),
                    SizedBox(width: 200, child: Text('SWAREEH')),
                    SizedBox(width: 200, child: Text('TUNIC')),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: 2000, child: Container()),
            ),
          ],
        ),
      ));

      final scrollables = scrollablesIn(walker.dumpVisibleTree());
      expect(scrollables, hasLength(2));

      final outer = scrollables.firstWhere((e) => e['axis'] == 'vertical');
      final rail = scrollables.firstWhere((e) => e['axis'] == 'horizontal');
      expect(outer['type'], 'CustomScrollView');
      expect(rail['type'], 'ListView');

      // The rail's items belong to the rail node; the header belongs to the
      // outer scroll view but not to the rail.
      expect(subtreeTexts(rail), containsAll(['JILBAB', 'SWAREEH']));
      expect(subtreeTexts(rail), isNot(contains('Popular items')));
      expect(subtreeTexts(outer), contains('Popular items'));
    });

    testWidgets('two same-axis rails get scrollIndex 0 and 1 in tree order',
        (tester) async {
      await tester.pumpWidget(_app(
        Column(
          children: [
            SizedBox(
              height: 100,
              child: ListView(
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
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(width: 80, child: Text('second $i')),
                ],
              ),
            ),
          ],
        ),
      ));

      final rails = scrollablesIn(walker.dumpVisibleTree())
          .where((e) => e['axis'] == 'horizontal')
          .toList();
      expect(rails, hasLength(2));

      final first = rails.firstWhere((e) => e['scrollIndex'] == 0);
      final second = rails.firstWhere((e) => e['scrollIndex'] == 1);
      expect(subtreeTexts(first), contains('first 0'));
      expect(subtreeTexts(second), contains('second 0'));
    });

    testWidgets('a bare Scrollable with no wrapping scroll view keeps the '
        'Scrollable type', (tester) async {
      await tester.pumpWidget(_app(
        Scrollable(
          axisDirection: AxisDirection.down,
          viewportBuilder: (context, offset) => Viewport(
            offset: offset,
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(height: 3000, child: Container()),
              ),
              const SliverToBoxAdapter(child: Text('inside bare scrollable')),
            ],
          ),
        ),
      ));

      final node = scrollablesIn(walker.dumpVisibleTree()).single;
      expect(node['type'], 'Scrollable');
      expect(node['axis'], 'vertical');
    });
  });
}
