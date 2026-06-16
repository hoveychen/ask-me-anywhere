// Regression: the multi-question wizard must NOT let you Confirm before every
// question is answered (Fleet's AskUserQuestion disables Submit until then).
// Drives the real widgets the way a user would — pick a radio, switch tabs,
// tick a checkbox, type the free-text answer — and watches Confirm flip from
// disabled to enabled only once all three questions are answered.
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

bool _confirmEnabled(WidgetTester tester) {
  final button = tester.widget<ElevatedButton>(
    find.widgetWithText(ElevatedButton, 'Confirm'),
  );
  return button.onPressed != null;
}

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

  testWidgets('Confirm stays disabled until every question is answered',
      (tester) async {
    final entry = galleryCards.firstWhere((c) => c.title == 'Multi-question');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CardDetailView(card: _card(entry.build('card')))),
    ));
    await tester.pumpAndSettle();

    // Nothing answered yet → disabled.
    expect(_confirmEnabled(tester), isFalse);

    // Q1 (single-select) — pick an environment.
    await tester.tap(find.text('Production'));
    await tester.pumpAndSettle();
    expect(_confirmEnabled(tester), isFalse);

    // Q2 (multi-select) — switch tab, tick a feature.
    await tester.tap(find.text('2 · Features'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auth'));
    await tester.pumpAndSettle();
    expect(_confirmEnabled(tester), isFalse);

    // Q3 (free-text) — switch tab, type the answer.
    await tester.tap(find.text('3 · Note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'looks good');
    await tester.pumpAndSettle();

    // All three answered → enabled.
    expect(_confirmEnabled(tester), isTrue);
  });
}
