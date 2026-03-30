import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/flutternaut.dart';

/// Wraps [child] with [Directionality] so Semantics labels resolve correctly.
Widget _wrap(Widget child) {
  return Directionality(textDirection: TextDirection.ltr, child: child);
}

void main() {
  const childWidget = SizedBox.shrink();

  group('Flutternaut', () {
    testWidgets('default constructor sets label and excludeSemantics',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const Flutternaut(label: 'test_label', child: childWidget)),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.label, 'test_label');
      expect(semantics.excludeSemantics, false);
      expect(semantics.properties.button, false);
      expect(semantics.container, true);
      expect(semantics.properties.checked, isNull);
      expect(semantics.properties.value, isNull);
    });

    testWidgets('default constructor passes value to Semantics',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const Flutternaut(
          label: 'counter',
          value: '42',
          child: childWidget,
        )),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.value, '42');
    });

    testWidgets('default constructor accepts optional parameters',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const Flutternaut(
          label: 'custom',
          button: true,
          container: true,
          checked: false,
          child: childWidget,
        )),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.button, true);
      expect(semantics.container, true);
      expect(semantics.properties.checked, false);
    });
  });

  group('Flutternaut.input', () {
    testWidgets('sets no semantic flags', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const Flutternaut.input(label: 'email_input', child: childWidget),
        ),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.label, 'email_input');
      expect(semantics.excludeSemantics, true);
      expect(semantics.properties.button, false);
      expect(semantics.container, false);
    });
  });

  group('Flutternaut.button', () {
    testWidgets('sets button: true', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const Flutternaut.button(label: 'login_button', child: childWidget),
        ),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.label, 'login_button');
      expect(semantics.properties.button, true);
      expect(semantics.container, true);
      expect(semantics.excludeSemantics, false);
    });
  });

  group('Flutternaut.text', () {
    testWidgets('passes value to Semantics', (tester) async {
      await tester.pumpWidget(
        _wrap(const Flutternaut.text(
          label: 'status',
          value: 'Online',
          child: childWidget,
        )),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.label, 'status');
      expect(semantics.properties.value, 'Online');
      expect(semantics.properties.button, false);
    });
  });

  group('Flutternaut.item', () {
    testWidgets('sets container: true', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const Flutternaut.item(label: 'todo_item', child: childWidget),
        ),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.label, 'todo_item');
      expect(semantics.container, true);
      expect(semantics.properties.button, false);
    });

    testWidgets('passes value to Semantics', (tester) async {
      await tester.pumpWidget(
        _wrap(const Flutternaut.item(
          label: 'todo_item',
          value: 'Buy milk',
          child: childWidget,
        )),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.value, 'Buy milk');
    });
  });

  group('Flutternaut.checkbox', () {
    testWidgets('sets container: true and passes checked state',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const Flutternaut.checkbox(
          label: 'agree_checkbox',
          checked: true,
          child: childWidget,
        )),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.label, 'agree_checkbox');
      expect(semantics.container, true);
      expect(semantics.properties.checked, true);
      expect(semantics.properties.button, false);
    });

    testWidgets('handles unchecked state', (tester) async {
      await tester.pumpWidget(
        _wrap(const Flutternaut.checkbox(
          label: 'agree_checkbox',
          checked: false,
          child: childWidget,
        )),
      );

      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.checked, false);
    });
  });

  group('description parameter', () {
    testWidgets('is accepted but not passed to Semantics', (tester) async {
      await tester.pumpWidget(
        _wrap(const Flutternaut(
          label: 'with_desc',
          description: 'A helpful description',
          child: childWidget,
        )),
      );

      final flutternaut = tester.widget<Flutternaut>(
        find.byType(Flutternaut),
      );
      expect(flutternaut.description, 'A helpful description');

      // Verify description does not leak into Semantics
      final semantics = tester.widget<Semantics>(find.byType(Semantics));
      expect(semantics.properties.label, 'with_desc');
      expect(semantics.properties.value, isNull);
    });

    testWidgets('works on all named constructors', (tester) async {
      const constructors = <Flutternaut>[
        Flutternaut.input(
          label: 'a',
          description: 'input desc',
          child: childWidget,
        ),
        Flutternaut.button(
          label: 'b',
          description: 'button desc',
          child: childWidget,
        ),
        Flutternaut.text(
          label: 'c',
          description: 'text desc',
          child: childWidget,
        ),
        Flutternaut.item(
          label: 'd',
          description: 'item desc',
          child: childWidget,
        ),
        Flutternaut.checkbox(
          label: 'e',
          description: 'checkbox desc',
          checked: false,
          child: childWidget,
        ),
      ];

      for (final widget in constructors) {
        expect(widget.description, isNotNull);
      }
    });
  });
}
