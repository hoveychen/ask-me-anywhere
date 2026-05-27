// P1 — CardDetailView renders an A2UI message tree into live widgets, and
// falls back to a plain summary for empty / malformed payloads.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';

import 'package:flutter_app/src/a2ui_sample.dart';
import 'package:flutter_app/src/data/card_data_bridge.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

CardView _card({required String summary, required String a2UiJson}) => CardView(
      id: 'card-1',
      summary: summary,
      source: 'test',
      createdAt: BigInt.zero,
      a2UiJson: a2UiJson,
      status: CardStatus.unread,
    );

Future<void> _pump(
  WidgetTester tester,
  CardView card, {
  ValueChanged<CardAction>? onAction,
  void Function(String path, Object? value)? onDataChanged,
  Stream<CardDataUpdate>? remoteData,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CardDetailView(
          card: card,
          onAction: onAction,
          onDataChanged: onDataChanged,
          remoteData: remoteData,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

CardView _sampleCard() => _card(
      summary: 'Deploy production?',
      a2UiJson: sampleA2uiJson(surfaceId: 'card', title: 'Deploy production?'),
    );

void main() {
  group('parseA2uiMessages', () {
    test('array of messages passes through', () {
      final messages = parseA2uiMessages(
        sampleA2uiJson(surfaceId: 's', title: 'hi'),
      );
      expect(messages.length, 3);
      expect(firstSurfaceId(messages), 's');
    });

    test('single message object is wrapped', () {
      final messages = parseA2uiMessages(
        '{"version":"v0.9","createSurface":{"surfaceId":"x","catalogId":"c"}}',
      );
      expect(messages.length, 1);
      expect(firstSurfaceId(messages), 'x');
    });

    test('empty object / invalid json yield nothing', () {
      expect(parseA2uiMessages('{}'), isEmpty);
      expect(parseA2uiMessages('not json'), isEmpty);
      expect(parseA2uiMessages('42'), isEmpty);
    });

    test('tree with no createSurface has no surface id', () {
      expect(firstSurfaceId(parseA2uiMessages('[{"version":"v0.9"}]')), isNull);
    });

    test('dataPaths collects updateDataModel paths, deduped', () {
      final messages = parseA2uiMessages(
        sampleA2uiJson(surfaceId: 's', title: 'hi'),
      );
      expect(dataPaths(messages), ['/note']);
    });
  });

  testWidgets('renders the A2UI tree into interactive widgets', (tester) async {
    await _pump(
      tester,
      _card(
        summary: 'Deploy production?',
        a2UiJson: sampleA2uiJson(surfaceId: 'card', title: 'Deploy production?'),
      ),
    );

    // The Surface is mounted and the catalog built real, interactive widgets.
    expect(find.byType(Surface), findsOneWidget);
    expect(find.byType(ElevatedButton), findsOneWidget); // primary Approve
    expect(find.byType(TextButton), findsOneWidget); // borderless Dismiss
    expect(find.byType(TextField), findsOneWidget); // bound note field
    // The fallback is NOT shown when the tree renders.
    expect(find.text('(no A2UI content)'), findsNothing);
  });

  testWidgets('button taps surface as CardActions', (tester) async {
    final List<CardAction> fired = [];
    final card = _card(
      summary: 'Deploy production?',
      a2UiJson: sampleA2uiJson(surfaceId: 'card', title: 'Deploy production?'),
    );
    await _pump(tester, card, onAction: fired.add);

    await tester.tap(find.byType(ElevatedButton)); // primary Approve
    await tester.pumpAndSettle();
    expect(fired.map((a) => a.name), ['approve']);

    await tester.tap(find.byType(TextButton)); // borderless Dismiss
    await tester.pumpAndSettle();
    expect(fired.map((a) => a.name), ['approve', 'dismiss']);
  });

  testWidgets('local edits to a bound field surface via onDataChanged',
      (tester) async {
    final changes = <String>[];
    await _pump(
      tester,
      _sampleCard(),
      onDataChanged: (path, value) => changes.add('$path=$value'),
    );

    await tester.enterText(find.byType(TextField), 'shipping it');
    await tester.pumpAndSettle();

    expect(changes, contains('/note=shipping it'));
  });

  testWidgets('remote data updates land in the bound field', (tester) async {
    final remote = StreamController<CardDataUpdate>();
    addTearDown(remote.close);
    await _pump(tester, _sampleCard(), remoteData: remote.stream);

    remote.add(const CardDataUpdate(path: '/note', value: 'from a peer'));
    await tester.pumpAndSettle();

    expect(find.text('from a peer'), findsOneWidget); // shown in the TextField
  });

  testWidgets('falls back to summary for an empty payload', (tester) async {
    await _pump(tester, _card(summary: 'Plain card', a2UiJson: '{}'));

    expect(find.byType(Surface), findsNothing);
    expect(find.text('Plain card'), findsOneWidget);
    expect(find.text('(no A2UI content)'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('falls back when the tree has no surface', (tester) async {
    await _pump(
      tester,
      _card(summary: 'No surface', a2UiJson: '[{"version":"v0.9"}]'),
    );

    expect(find.byType(Surface), findsNothing);
    expect(find.text('No surface'), findsOneWidget);
  });
}
