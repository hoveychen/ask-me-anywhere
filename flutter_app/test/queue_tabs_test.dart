// The pending-queue tab strip (shown above a card when ≥2 are pending) is a
// pure presentational widget — it takes the pending list + active id and fires
// onSelect — so it's testable without the AssistantController singleton the
// rest of the macOS surfaces lean on.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/macos/assistant_views.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';

CardView _card(String id, String summary) => CardView(
      id: id,
      summary: summary,
      source: 'test',
      createdAt: BigInt.zero,
      a2UiJson: '{}',
      status: CardStatus.unread,
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<CardView> pending,
  required String activeId,
  required ValueChanged<String> onSelect,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('active'),
          bottom: QueueTabs(
            pending: pending,
            activeId: activeId,
            onSelect: onSelect,
          ),
        ),
      ),
    ));

void main() {
  testWidgets('shows a chip per pending card and the count', (tester) async {
    await _pump(
      tester,
      pending: [_card('a', 'Deploy?'), _card('b', 'Approve PR'), _card('c', 'Migrate?')],
      activeId: 'a',
      onSelect: (_) {},
    );
    expect(find.text('3 pending'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Deploy?'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Approve PR'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Migrate?'), findsOneWidget);
  });

  testWidgets('the active card is the selected chip', (tester) async {
    await _pump(
      tester,
      pending: [_card('a', 'Deploy?'), _card('b', 'Approve PR')],
      activeId: 'b',
      onSelect: (_) {},
    );
    final ChoiceChip active =
        tester.widget(find.widgetWithText(ChoiceChip, 'Approve PR'));
    final ChoiceChip other =
        tester.widget(find.widgetWithText(ChoiceChip, 'Deploy?'));
    expect(active.selected, isTrue);
    expect(other.selected, isFalse);
  });

  testWidgets('tapping a chip fires onSelect with that card id', (tester) async {
    final picked = <String>[];
    await _pump(
      tester,
      pending: [_card('a', 'Deploy?'), _card('b', 'Approve PR')],
      activeId: 'a',
      onSelect: picked.add,
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Approve PR'));
    await tester.pumpAndSettle();
    expect(picked, ['b']);
  });
}
