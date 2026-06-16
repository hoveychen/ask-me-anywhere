// Guard + Plan-approval gallery cards: pure A2UI decision cards whose buttons
// fire allow/block/approve/reject through the normal action path. Driven via
// the real CardDetailView pipeline.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/a2ui_gallery.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

CardView _card(String title, String json) => CardView(
      id: 'c',
      summary: title,
      source: 't',
      createdAt: BigInt.zero,
      a2UiJson: json,
      status: CardStatus.unread,
    );

Future<List<String>> _pumpAndCollect(
  WidgetTester tester,
  String title,
) async {
  final fired = <String>[];
  final entry = galleryCards.firstWhere((c) => c.title == title);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: CardDetailView(
          card: _card(title, entry.build('card')),
          onAction: (a) => fired.add(a.name),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return fired;
}

void main() {
  testWidgets('Guard shows command + risks and fires allow/block',
      (tester) async {
    final fired = await _pumpAndCollect(tester, 'Guard');
    expect(find.text(r'$ rm -rf ./build'), findsOneWidget);
    expect(find.textContaining('Risk:'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Reason (if blocking)'),
        findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Allow'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Block'));
    await tester.pumpAndSettle();
    expect(fired, ['allow', 'block']);
  });

  testWidgets('Plan approval shows the plan and fires approve/reject',
      (tester) async {
    final fired = await _pumpAndCollect(tester, 'Plan approval');
    expect(find.textContaining('Add the auth middleware'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Feedback (if rejecting)'),
        findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Reject'));
    await tester.pumpAndSettle();
    expect(fired, ['approve', 'reject']);
  });
}
