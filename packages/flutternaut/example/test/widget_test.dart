import 'package:flutter_test/flutter_test.dart';
import 'package:flutternaut_example/main.dart';

void main() {
  testWidgets('App renders login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const FlutternautExampleApp());
    expect(find.text('Login'), findsOneWidget);
  });
}
