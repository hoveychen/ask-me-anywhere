// P3 — pump the real app, tap the debug FAB, verify the new card lands in the
// rendered list. Proves "人眼能看到卡片" through automation.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_app/main.dart';
import 'package:flutter_app/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('FAB pushes a card and it appears in the list', (tester) async {
    await tester.pumpWidget(const AmaApp());

    // Boot screen → empty state. settle() waits for inbox.create() + first refresh.
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(
      find.text('(no cards yet — press the button)'),
      findsOneWidget,
      reason: 'fresh inbox should show the empty hint',
    );

    // Tap the FAB; first sample is "Deploy production?".
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.text('Deploy production?'), findsOneWidget);
    expect(find.text('(no cards yet — press the button)'), findsNothing);

    // A second tap should produce a second tile.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.text('Approve PR #42'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(2));
  });
}
