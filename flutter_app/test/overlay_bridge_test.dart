// P4 — the main↔overlay wire protocol. The overlay isolate owns no inbox, so
// the snapshot must carry everything it needs to render a card; these tests
// round-trip both directions through plain JSON maps (what shareData transmits).
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/android/overlay_bridge.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';

// A real A2UI tree with one createSurface + one bound data-model path, so
// dataPaths() has something to extract.
const _a2ui = '['
    '{"createSurface":{"surfaceId":"card"}},'
    '{"updateDataModel":{"path":"/note"}}'
    ']';

CardView _card(String id, CardStatus status) => CardView(
      id: id,
      summary: 'Deploy?',
      source: 'peer',
      createdAt: BigInt.from(1234),
      a2UiJson: _a2ui,
      status: status,
    );

void main() {
  group('cards snapshot (main → overlay)', () {
    test('cardToJson + parseSnapshot round-trips a card', () {
      final json = cardToJson(_card('a', CardStatus.unread),
          dataValues: {'/note': 'hi'});
      final snap = parseSnapshot(snapshotToJson(1, [json]));

      expect(snap, isNotNull);
      expect(snap!.unreadCount, 1);
      expect(snap.cards, hasLength(1));
      final c = snap.cards.single;
      expect(c.id, 'a');
      expect(c.summary, 'Deploy?');
      expect(c.source, 'peer');
      expect(c.createdAt, 1234);
      expect(c.a2UiJson, _a2ui);
      expect(c.status, 'unread');
      expect(c.dataPaths, ['/note']); // extracted from the A2UI tree
      expect(c.dataValues, {'/note': 'hi'});
    });

    test('dataPaths is derived from the tree even with no values', () {
      final json = cardToJson(_card('a', CardStatus.unread));
      final snap = parseSnapshot(snapshotToJson(0, [json]))!;
      expect(snap.cards.single.dataPaths, ['/note']);
      expect(snap.cards.single.dataValues, isEmpty);
    });

    test('parseSnapshot rejects non-cards messages', () {
      expect(parseSnapshot({'type': 'action', 'cardId': 'a'}), isNull);
      expect(parseSnapshot('garbage'), isNull);
      expect(parseSnapshot(null), isNull);
    });
  });

  group('commands (overlay → main)', () {
    test('action command round-trips name + context', () {
      final cmd = parseCommand(actionCommand('a', 'approve', {'ok': true}))!;
      expect(cmd.type, OverlayCommandType.action);
      expect(cmd.cardId, 'a');
      expect(cmd.name, 'approve');
      expect(cmd.context, {'ok': true});
    });

    test('dismiss command round-trips', () {
      final cmd = parseCommand(dismissCommand('b'))!;
      expect(cmd.type, OverlayCommandType.dismiss);
      expect(cmd.cardId, 'b');
    });

    test('setData command round-trips path + value', () {
      final cmd = parseCommand(setDataCommand('c', '/note', 'typed'))!;
      expect(cmd.type, OverlayCommandType.setData);
      expect(cmd.cardId, 'c');
      expect(cmd.path, '/note');
      expect(cmd.value, 'typed');
    });

    test('openInbox command round-trips', () {
      final cmd = parseCommand(openInboxCommand())!;
      expect(cmd.type, OverlayCommandType.openInbox);
    });

    test('parseCommand rejects unknown / malformed messages', () {
      expect(parseCommand({'type': 'cards'}), isNull);
      expect(parseCommand({'type': 'nope'}), isNull);
      expect(parseCommand(42), isNull);
    });
  });
}
