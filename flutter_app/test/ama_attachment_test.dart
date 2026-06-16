// AmaAttachment: pick → base64 data URL → bound path; renders a thumbnail +
// Remove once attached. The native picker itself isn't widget-testable, so we
// cover the pure data-URL codec and the seeded-value render path here.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart' show Surface, basicCatalogId;

import 'package:flutter_app/src/a2ui_gallery.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/ama_attachment.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

// A 1x1 transparent PNG.
const _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

String _tree({String seed = ''}) => jsonEncode([
      {
        'version': 'v0.9',
        'createSurface': {'surfaceId': 'card', 'catalogId': basicCatalogId},
      },
      {
        'version': 'v0.9',
        'updateDataModel': {'surfaceId': 'card', 'path': '/img', 'value': seed},
      },
      {
        'version': 'v0.9',
        'updateComponents': {
          'surfaceId': 'card',
          'components': [
            {
              'id': 'root',
              'component': 'AmaAttachment',
              'label': 'Screenshot',
              'value': {'path': '/img'},
            },
          ],
        },
      },
    ]);

CardView _card(String json) => CardView(
      id: 'c',
      summary: 's',
      source: 't',
      createdAt: BigInt.zero,
      a2UiJson: json,
      status: CardStatus.unread,
    );

Future<void> _pump(WidgetTester tester, String json) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: CardDetailView(card: _card(json))),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('data URL codec', () {
    test('round-trips bytes', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final url = imageDataUrl(bytes, 'image/png');
      expect(url.startsWith('data:image/png;base64,'), isTrue);
      expect(decodeDataUrl(url), bytes);
    });
    test('rejects non-data values', () {
      expect(decodeDataUrl(''), isNull);
      expect(decodeDataUrl('hello'), isNull);
      expect(decodeDataUrl(null), isNull);
      expect(decodeDataUrl(42), isNull);
    });
  });

  testWidgets('shows Add image when empty', (tester) async {
    await _pump(tester, _tree());
    expect(find.byType(Surface), findsOneWidget);
    expect(find.text('Add image'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('shows the thumbnail + Remove when an image is attached',
      (tester) async {
    await _pump(tester, _tree(seed: 'data:image/png;base64,$_png1x1'));
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    expect(find.text('Add image'), findsNothing);
  });

  testWidgets('the gallery Attachment card renders with the picker',
      (tester) async {
    final entry = galleryCards.firstWhere((c) => c.title == 'Attachment');
    await _pump(tester, entry.build('card'));
    expect(find.byType(Surface), findsOneWidget);
    expect(find.text('Attach a screenshot'), findsOneWidget);
    expect(find.text('Add image'), findsOneWidget);
  });
}
