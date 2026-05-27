// P4 — CardDetailScreen: the live A2UI surface under an app bar with a top
// dismiss button. Tapping the dismiss button or any in-card action fires the
// host callback (which writes to the CRDT) and pops the screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/a2ui_sample.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/card_detail_screen.dart';

CardView _sampleCard() => CardView(
      id: 'card-1',
      summary: 'Deploy production?',
      source: 'test',
      createdAt: BigInt.zero,
      a2UiJson: sampleA2uiJson(surfaceId: 'card', title: 'Deploy production?'),
      status: CardStatus.unread,
    );

/// Pushes the screen from a list route so `maybePop` has somewhere to pop to,
/// letting us assert the screen leaves the tree after an action.
Future<void> _pushScreen(WidgetTester tester, CardDetailScreen screen) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => screen),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the card summary and the live A2UI surface',
      (tester) async {
    await _pushScreen(tester, CardDetailScreen(card: _sampleCard()));

    // Title in the app bar (the in-card heading also renders this text).
    expect(find.widgetWithText(AppBar, 'Deploy production?'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsOneWidget); // in-card Approve
    expect(find.byIcon(Icons.close), findsOneWidget); // top dismiss button
  });

  testWidgets('top dismiss button fires onDismiss and pops', (tester) async {
    var dismissed = 0;
    await _pushScreen(
      tester,
      CardDetailScreen(card: _sampleCard(), onDismiss: () => dismissed++),
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(dismissed, 1);
    expect(find.byType(CardDetailScreen), findsNothing); // popped back to list
  });

  testWidgets('an in-card action fires onAction and pops', (tester) async {
    final actions = <String>[];
    await _pushScreen(
      tester,
      CardDetailScreen(
        card: _sampleCard(),
        onAction: (a) => actions.add(a.name),
      ),
    );

    await tester.tap(find.byType(ElevatedButton)); // primary Approve
    await tester.pumpAndSettle();

    expect(actions, ['approve']);
    expect(find.byType(CardDetailScreen), findsNothing);
  });
}
