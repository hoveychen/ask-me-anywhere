// P4 — newCardFor decides which doc events raise a native notification: only a
// "message" event whose card is present in the current list.
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/notify/card_notifier.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';

CardView _card(String id, String summary) => CardView(
      id: id,
      summary: summary,
      source: 'peer',
      createdAt: BigInt.zero,
      a2UiJson: '{}',
      status: CardStatus.unread,
    );

void main() {
  final cards = [_card('a', 'Deploy?'), _card('b', 'Approve PR')];

  test('a message event for a known card returns that card', () {
    expect(newCardFor('message', 'b', cards)?.summary, 'Approve PR');
  });

  test('non-message events never notify', () {
    expect(newCardFor('data', 'a', cards), isNull);
    expect(newCardFor('state', 'a', cards), isNull);
    expect(newCardFor('tick', null, cards), isNull);
  });

  test('a message event for an unknown / missing id returns null', () {
    expect(newCardFor('message', 'zzz', cards), isNull);
    expect(newCardFor('message', null, cards), isNull);
  });
}
