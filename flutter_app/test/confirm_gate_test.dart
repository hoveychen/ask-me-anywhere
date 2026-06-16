// Regression: the multi-question wizard steps through one question per tab — a
// "Next" button (gated on the current question) advances the tab, and only the
// last tab's "Confirm" appears, gated on every question being answered. You can
// never Confirm with an unanswered question (Fleet's AskUserQuestion model).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/a2ui_functions.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';
import 'package:flutter_app/src/a2ui_gallery.dart';

CardView _card(String a2UiJson) => CardView(
      id: 'card-1',
      summary: 'Multi-question',
      source: 'test',
      createdAt: BigInt.zero,
      a2UiJson: a2UiJson,
      status: CardStatus.unread,
    );

// genui's Tabs only builds the active tab's content, so the Confirm button
// exists solely on the last tab and Next solely on the others — exactly the
// "the button becomes Confirm at the end" shape.
bool _confirmEnabled(WidgetTester tester) =>
    tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Confirm'))
        .onPressed !=
    null;

final Finder _next = find.widgetWithText(ElevatedButton, 'Next →');
bool _nextEnabled(WidgetTester tester) =>
    tester.widget<ElevatedButton>(_next).onPressed != null;

void main() {
  group('isAnswered', () {
    test('empty list / blank string / null are unanswered', () {
      expect(isAnswered(<String>[]), isFalse);
      expect(isAnswered(''), isFalse);
      expect(isAnswered('   '), isFalse);
      expect(isAnswered(null), isFalse);
    });
    test('non-empty list / text / scalar are answered', () {
      expect(isAnswered(['a']), isTrue);
      expect(isAnswered('hi'), isTrue);
      expect(isAnswered(3), isTrue);
    });
  });

  testWidgets('Next advances per tab; Confirm appears only on the last tab',
      (tester) async {
    final entry = galleryCards.firstWhere((c) => c.title == 'Multi-question');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        // The macOS card surface scrolls (AssistantCardView); mirror that so a
        // tall question doesn't overflow the test viewport.
        body: SingleChildScrollView(
          child: CardDetailView(card: _card(entry.build('card'))),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Q1: a Next button (no Confirm yet), disabled until an environment is picked.
    expect(find.text('Confirm'), findsNothing);
    expect(_nextEnabled(tester), isFalse);
    await tester.tap(find.text('Production'));
    await tester.pumpAndSettle();
    expect(_nextEnabled(tester), isTrue);

    // Advancing lands on Q2 (its features question becomes visible); still no Confirm.
    await tester.tap(_next);
    await tester.pumpAndSettle();
    expect(find.text('Which features should I enable?'), findsOneWidget);
    expect(find.text('Confirm'), findsNothing);

    // Q2: Next gated until a feature is ticked, then advance to Q3.
    expect(_nextEnabled(tester), isFalse);
    await tester.tap(find.text('Auth'));
    await tester.pumpAndSettle();
    expect(_nextEnabled(tester), isTrue);
    await tester.tap(_next);
    await tester.pumpAndSettle();

    // Q3: now Confirm appears and Next is gone; Confirm gated until the note is filled.
    expect(find.text('Next →'), findsNothing);
    expect(_confirmEnabled(tester), isFalse);
    await tester.enterText(find.byType(TextField), 'looks good');
    await tester.pumpAndSettle();
    expect(_confirmEnabled(tester), isTrue);
  });
}
