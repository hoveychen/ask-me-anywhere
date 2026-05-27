// P2 — Dart-side smoke of the InboxHandle bridge:
// create → push → list, all going through the Rust ama-core Inbox via FRB.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('Dart push -> Rust list round-trips a card', (tester) async {
    final inbox = await InboxHandle.create(device: 'desktop');

    // Empty to start.
    expect(await inbox.listMessages(), isEmpty);

    // Push three cards in order; capture their ids.
    final id1 = await inbox.push(summary: 'Deploy?', a2UiJson: '{}');
    final id2 = await inbox.push(summary: 'Approve PR #42', a2UiJson: '{}');
    final id3 = await inbox.push(summary: 'Lunch time', a2UiJson: '{}');

    final cards = await inbox.listMessages();
    expect(cards, hasLength(3));

    // list_messages sorts newest-created first; the last push (id3) wins.
    expect(cards.first.id, id3);
    expect(cards.first.summary, 'Lunch time');
    expect(cards.first.source, 'app');
    expect(cards.first.status, CardStatus.unread);

    // Every pushed id is present.
    final ids = cards.map((c) => c.id).toSet();
    expect(ids, containsAll([id1, id2, id3]));
  });
}
