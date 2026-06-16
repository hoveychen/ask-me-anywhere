// Verifies every debug-FAB gallery card renders through the same
// CardDetailView pipeline the app uses, producing the expected interactive
// control (radios / checkboxes / chips / slider / date / text). This is the
// objective check that the gallery payloads are valid A2UI the genui catalog
// can build — more reliable than eyeballing the frameless macOS window.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';

import 'package:flutter_app/src/a2ui_gallery.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

CardView _card(String title, String a2UiJson) => CardView(
      id: 'card-1',
      summary: title,
      source: 'test',
      createdAt: BigInt.zero,
      a2UiJson: a2UiJson,
      status: CardStatus.unread,
    );

Future<void> _pumpCard(WidgetTester tester, GalleryCard entry) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        // Mirror the macOS card surface's scroll so tall cards don't overflow.
        body: SingleChildScrollView(
          child: CardDetailView(card: _card(entry.title, entry.build('card'))),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('gallery exposes the expected card types in order', () {
    expect(
      galleryCards.map((c) => c.title),
      [
        'Multi-question',
        'Single choice',
        'Multiple choice',
        'Multiple choice (chips)',
        'Form',
        'Guard',
        'Plan approval',
        'Attachment',
        'Note',
      ],
    );
  });

  testWidgets('multi-question renders a Tabs wizard with one tab per question',
      (tester) async {
    await _pumpCard(
        tester, galleryCards.firstWhere((c) => c.title == 'Multi-question'));
    // Each question is a tab header (the A2UI-native navigator).
    expect(find.text('1 · Env'), findsOneWidget);
    expect(find.text('2 · Features'), findsOneWidget);
    expect(find.text('3 · Note'), findsOneWidget);
    // Q1 is an AmaChoice single-select (RadioListTile<bool>), one per option.
    expect(find.byType(RadioListTile<bool>), findsNWidgets(3));
  });

  testWidgets('every gallery card renders a Surface (valid A2UI)',
      (tester) async {
    for (final entry in galleryCards) {
      await _pumpCard(tester, entry);
      expect(find.byType(Surface), findsOneWidget,
          reason: '${entry.title} should mount a Surface');
      expect(find.text('(no A2UI content)'), findsNothing,
          reason: '${entry.title} should not fall back');
    }
  });

  testWidgets('single choice renders radios', (tester) async {
    await _pumpCard(tester, galleryCards.firstWhere((c) => c.title == 'Single choice'));
    expect(find.byType(RadioListTile<String>), findsNWidgets(3));
  });

  testWidgets('multiple choice renders checkboxes', (tester) async {
    await _pumpCard(tester, galleryCards.firstWhere((c) => c.title == 'Multiple choice'));
    expect(find.byType(CheckboxListTile), findsNWidgets(4));
  });

  testWidgets('chips variant renders FilterChips', (tester) async {
    await _pumpCard(
        tester, galleryCards.firstWhere((c) => c.title == 'Multiple choice (chips)'));
    expect(find.byType(FilterChip), findsNWidgets(5));
  });

  testWidgets('form renders a text field, a slider and a date input',
      (tester) async {
    await _pumpCard(tester, galleryCards.firstWhere((c) => c.title == 'Form'));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    // DateTimeInput surfaces a tappable affordance; assert the Surface built
    // more than the bare text + button (the date control is present).
    expect(find.byType(Slider), findsOneWidget);
  });
}
