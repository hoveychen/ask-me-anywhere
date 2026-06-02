// P1 — AssistantController is the shared inbox state. These tests drive it
// through the narrow [InboxApi] / [CardNotifierApi] seams (the real FRB handle
// is opaque and can't be mocked), checking: boot populates the list, unreadCount
// counts only unread cards, card actions forward to the inbox, and a new card
// notifies at most once.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/notify/card_notifier.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/state/assistant_controller.dart';

CardView _card(String id, String summary, CardStatus status) => CardView(
      id: id,
      summary: summary,
      source: 'peer',
      createdAt: BigInt.zero,
      a2UiJson: '{}',
      status: status,
    );

class FakeInbox implements InboxApi {
  FakeInbox(this.cards);

  List<CardView> cards;
  final StreamController<DocEvent> _events = StreamController<DocEvent>.broadcast();
  final List<Map<String, String?>> actions = [];
  final List<Map<String, String>> dataWrites = [];

  void emit(DocEvent e) => _events.add(e);

  @override
  Future<List<CardView>> listMessages() async => cards;
  @override
  Stream<DocEvent> watch() => _events.stream;
  @override
  Future<String> push({required String summary, required String a2UiJson}) async =>
      'pushed';
  @override
  Future<void> recordAction({
    required String msgId,
    required String actionName,
    String? actionContextJson,
  }) async {
    actions.add({'id': msgId, 'name': actionName, 'ctx': actionContextJson});
  }

  @override
  Future<void> setData({
    required String msgId,
    required String bindPath,
    required String valueJson,
  }) async {
    dataWrites.add({'id': msgId, 'path': bindPath, 'value': valueJson});
  }

  @override
  Future<String?> getData({
    required String msgId,
    required String bindPath,
  }) async =>
      null;
  @override
  Future<String> ticket() async => 'TICKET';
}

class FakeNotifier implements CardNotifierApi {
  int initCalls = 0;
  final List<String> notified = [];

  @override
  Future<void> init() async => initCalls++;
  @override
  Future<void> notifyCard(CardView card) async => notified.add(card.id);
}

AssistantController _controllerFor(FakeInbox inbox, FakeNotifier notifier) =>
    AssistantController(
      createInbox: () async => inbox,
      joinInbox: (_) async => inbox,
      notifier: notifier,
    );

// Let the async watch() → _onDocEvent → _refresh chain settle.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('boot loads the list and inits the notifier once', () async {
    final inbox = FakeInbox([_card('a', 'A', CardStatus.unread)]);
    final notifier = FakeNotifier();
    final c = _controllerFor(inbox, notifier);

    await c.boot();

    expect(c.booting, isFalse);
    expect(c.error, isNull);
    expect(c.cards.map((e) => e.id), ['a']);
    expect(notifier.initCalls, 1);
  });

  test('boot is idempotent', () async {
    final inbox = FakeInbox([_card('a', 'A', CardStatus.unread)]);
    final notifier = FakeNotifier();
    final c = _controllerFor(inbox, notifier);

    await c.boot();
    await c.boot();

    expect(notifier.initCalls, 1);
  });

  test('unreadCount counts only unread cards', () async {
    final inbox = FakeInbox([
      _card('a', 'A', CardStatus.unread),
      _card('b', 'B', CardStatus.unread),
      _card('c', 'C', CardStatus.actioned),
      _card('d', 'D', CardStatus.dismissed),
    ]);
    final c = _controllerFor(inbox, FakeNotifier());

    await c.boot();

    expect(c.unreadCount, 2);
  });

  test('recordAction forwards name + context and refreshes', () async {
    final inbox = FakeInbox([_card('a', 'A', CardStatus.unread)]);
    final c = _controllerFor(inbox, FakeNotifier());
    await c.boot();

    await c.recordAction('a', 'approve', {'ok': true});

    expect(inbox.actions, hasLength(1));
    expect(inbox.actions.single['id'], 'a');
    expect(inbox.actions.single['name'], 'approve');
    expect(inbox.actions.single['ctx'], '{"ok":true}');
  });

  test('recordAction with empty context sends null context json', () async {
    final inbox = FakeInbox([_card('a', 'A', CardStatus.unread)]);
    final c = _controllerFor(inbox, FakeNotifier());
    await c.boot();

    await c.recordAction('a', 'approve', const {});

    expect(inbox.actions.single['ctx'], isNull);
  });

  test('dismiss forwards the dismiss action', () async {
    final inbox = FakeInbox([_card('a', 'A', CardStatus.unread)]);
    final c = _controllerFor(inbox, FakeNotifier());
    await c.boot();

    await c.dismiss('a');

    expect(inbox.actions.single['name'], 'dismiss');
  });

  test('setData forwards a json-encoded value', () async {
    final inbox = FakeInbox([_card('a', 'A', CardStatus.unread)]);
    final c = _controllerFor(inbox, FakeNotifier());
    await c.boot();

    await c.setData('a', '/note', 'hi');

    expect(inbox.dataWrites.single['path'], '/note');
    expect(inbox.dataWrites.single['value'], '"hi"');
  });

  test('a new card notifies at most once even on repeated message events',
      () async {
    final inbox = FakeInbox([_card('a', 'A', CardStatus.unread)]);
    final notifier = FakeNotifier();
    final c = _controllerFor(inbox, notifier);
    await c.boot();

    inbox.emit(const DocEvent(kind: 'message', msgId: 'a'));
    await _settle();
    inbox.emit(const DocEvent(kind: 'message', msgId: 'a'));
    await _settle();

    expect(notifier.notified, ['a']);
  });

  test('non-message events do not notify', () async {
    final inbox = FakeInbox([_card('a', 'A', CardStatus.unread)]);
    final notifier = FakeNotifier();
    final c = _controllerFor(inbox, notifier);
    await c.boot();

    inbox.emit(const DocEvent(kind: 'tick'));
    inbox.emit(const DocEvent(kind: 'data', msgId: 'a', bindPath: '/note'));
    await _settle();

    expect(notifier.notified, isEmpty);
  });
}
