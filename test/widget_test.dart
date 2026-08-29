import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:talkfree/screens/login_screen.dart';

void main() {
  testWidgets('Login screen builds', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LoginScreen(),
      ),
    );

    expect(find.text('TalkFree'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });
}
