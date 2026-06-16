// AmaChoice: the custom catalog component that adds per-option descriptions
// (and later Other + preview) on top of a single/multi select. Driven through
// the real CardDetailView pipeline so it exercises the registered catalog.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart' show basicCatalogId;

import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

String _tree({
  bool multiple = false,
  Object? otherBinding,
  List<Map<String, Object?>> options = const [
    {'label': 'Alpha', 'value': 'a', 'description': 'the first option'},
    {'label': 'Beta', 'value': 'b', 'description': 'the second option'},
  ],
}) {
  return jsonEncode([
    {
      'version': 'v0.9',
      'createSurface': {'surfaceId': 'card', 'catalogId': basicCatalogId},
    },
    {
      'version': 'v0.9',
      'updateDataModel': {'surfaceId': 'card', 'path': '/sel', 'value': <String>[]},
    },
    {
      'version': 'v0.9',
      'updateDataModel': {'surfaceId': 'card', 'path': '/other', 'value': ''},
    },
    {
      'version': 'v0.9',
      'updateComponents': {
        'surfaceId': 'card',
        'components': [
          {
            'id': 'root',
            'component': 'AmaChoice',
            'label': 'Pick one',
            'multiple': multiple,
            'value': {'path': '/sel'},
            if (otherBinding != null) 'other': otherBinding,
            'options': options,
          },
        ],
      },
    },
  ]);
}

CardView _card(String json) => CardView(
      id: 'c',
      summary: 's',
      source: 't',
      createdAt: BigInt.zero,
      a2UiJson: json,
      status: CardStatus.unread,
    );

Future<void> _pump(WidgetTester tester, String json,
    {void Function(String, Object?)? onData}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: CardDetailView(card: _card(json), onDataChanged: onData)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders each option label and its description', (tester) async {
    await _pump(tester, _tree());
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('the first option'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('the second option'), findsOneWidget);
  });

  testWidgets('single-select writes the picked value to the bound path',
      (tester) async {
    final changes = <String>[];
    await _pump(tester, _tree(),
        onData: (path, value) => changes.add('$path=$value'));

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(changes, contains('/sel=[a]'));
  });

  testWidgets('multi-select accumulates picked values', (tester) async {
    final changes = <String>[];
    await _pump(tester, _tree(multiple: true),
        onData: (path, value) => changes.add('$path=$value'));

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(changes.last, '/sel=[a, b]');
  });

  group('Other (mutually exclusive)', () {
    testWidgets('shows an Other field when bound', (tester) async {
      await _pump(tester, _tree(otherBinding: {'path': '/other'}));
      expect(find.widgetWithText(TextField, 'Other'), findsOneWidget);
    });

    testWidgets('typing Other clears the option selection', (tester) async {
      final changes = <String>[];
      await _pump(tester, _tree(otherBinding: {'path': '/other'}),
          onData: (path, value) => changes.add('$path=$value'));

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(changes, contains('/sel=[a]'));

      await tester.enterText(find.byType(TextField), 'custom answer');
      await tester.pumpAndSettle();
      // Typing Other writes /other and clears /sel.
      expect(changes, contains('/other=custom answer'));
      expect(changes, contains('/sel=[]'));
    });

    testWidgets('picking an option clears Other', (tester) async {
      final changes = <String>[];
      await _pump(tester, _tree(otherBinding: {'path': '/other'}),
          onData: (path, value) => changes.add('$path=$value'));

      await tester.enterText(find.byType(TextField), 'custom');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      // Selecting writes /sel and clears /other.
      expect(changes, contains('/sel=[b]'));
      expect(changes.where((c) => c == '/other=').isNotEmpty, isTrue);
    });
  });
}
