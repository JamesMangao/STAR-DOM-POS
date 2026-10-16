import 'package:flutter_test/flutter_test.dart';

import 'package:stardom_pos/main.dart';

void main() {
  testWidgets('App starts and shows placeholder', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // Verify that the app shows the placeholder screen
    expect(find.text('STAR:DOM POS'), findsOneWidget);
    expect(
      find.text('App running - screens not yet implemented'),
      findsOneWidget,
    );
  });
}
