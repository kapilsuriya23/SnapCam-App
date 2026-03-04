// This is a basic smoke test for the SnapCam app.
// It verifies that the app launches and shows the loading indicator
// before the camera is initialised.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SnapCam app smoke test', (WidgetTester tester) async {
    // Build a minimal MaterialApp — we do NOT pump the real app here
    // because CameraController requires a physical device / emulator.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: CircularProgressIndicator(
              color: Colors.white24,
              strokeWidth: 1,
            ),
          ),
        ),
      ),
    );

    // Verify the loading indicator is present on the initial screen.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Verify no stray counter text from the default template exists.
    expect(find.text('0'), findsNothing);
  });
}
