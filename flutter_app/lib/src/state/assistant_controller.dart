// Process-wide shared state for the inbox, lifted out of `_InboxViewState` so
// the full-screen list page, the macOS floating window, and the Android overlay
// bridge can all observe one inbox and one card list.
//
// The controller owns the `InboxHandle` (held behind the narrow [InboxApi]
// seam so it stays unit-testable — the FRB-generated handle is an opaque class
// that can't be mocked directly), the `watch()` subscription, the new-card
// notification dedup, and the unread count. UI just listens (`ChangeNotifier`)
// and calls the action-forwarding methods.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter_app/src/a2ui_sample.dart';
import 'package:flutter_app/src/data/card_data_bridge.dart';
import 'package:flutter_app/src/notify/card_notifier.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/state/badge_sink.dart';

/// The slice of `InboxHandle` the controller depends on. A real implementation
/// ([InboxHandleApi]) delegates to the FRB handle; tests supply a fake.
abstract class InboxApi {
  Future<List<CardView>> listMessages();
  Stream<DocEvent> watch();
  Future<String> push({required String summary, required String a2UiJson});
  Future<void> recordAction({
    required String msgId,
    required String actionName,
    String? actionContextJson,
  });
  Future<void> setData({
    required String msgId,
    required String bindPath,
    required String valueJson,
  });
  Future<String?> getData({required String msgId, required String bindPath});
  Future<String> ticket();
}

/// [InboxApi] backed by a real FRB [InboxHandle].
class InboxHandleApi implements InboxApi {
  InboxHandleApi(this._handle);

  final InboxHandle _handle;

  @override
  Future<List<CardView>> listMessages() => _handle.listMessages();
  @override
  Stream<DocEvent> watch() => _handle.watch();
  @override
  Future<String> push({required String summary, required String a2UiJson}) =>
      _handle.push(summary: summary, a2UiJson: a2UiJson);
  @override
  Future<void> recordAction({
    required String msgId,
    required String actionName,
    String? actionContextJson,
  }) =>
      _handle.recordAction(
        msgId: msgId,
        actionName: actionName,
        actionContextJson: actionContextJson,
      );
  @override
  Future<void> setData({
    required String msgId,
    required String bindPath,
    required String valueJson,
  }) =>
      _handle.setData(msgId: msgId, bindPath: bindPath, valueJson: valueJson);
  @override
  Future<String?> getData({required String msgId, required String bindPath}) =>
      _handle.getData(msgId: msgId, bindPath: bindPath);
  @override
  Future<String> ticket() => _handle.ticket();
}

typedef InboxFactory = Future<InboxApi> Function();
typedef JoinFactory = Future<InboxApi> Function(String ticket);

Future<InboxApi> _defaultCreate() async =>
    InboxHandleApi(await InboxHandle.create(device: 'desktop'));

Future<InboxApi> _defaultJoin(String ticket) async =>
    InboxHandleApi(await InboxHandle.join(ticket: ticket, device: 'desktop'));

/// Shared, observable inbox state. Construct your own (with injected deps) in
/// tests; production code uses [AssistantController.instance].
class AssistantController extends ChangeNotifier {
  AssistantController({
    InboxFactory? createInbox,
    JoinFactory? joinInbox,
    CardNotifierApi? notifier,
    BadgeSink? badge,
  })  : _createInbox = createInbox ?? _defaultCreate,
        _joinInbox = joinInbox ?? _defaultJoin,
        _notifier = notifier ?? LocalCardNotifier(),
        _badge = badge ?? const NoopBadgeSink();

  /// The process-wide instance the app's UIs share.
  static final AssistantController instance = AssistantController();

  /// Swap the badge surface after construction — used by `boot()`'s platform
  /// wiring (P5) since [instance] is built before we know the platform deps.
  set badge(BadgeSink sink) {
    _badge = sink;
    _badge.setBadge(unreadCount);
  }

  final InboxFactory _createInbox;
  final JoinFactory _joinInbox;
  final CardNotifierApi _notifier;
  BadgeSink _badge;

  /// Unread-card count as a listenable, for badge widgets that want to rebuild
  /// on it alone rather than on the whole controller.
  final ValueNotifier<int> _unreadCount = ValueNotifier<int>(0);
  ValueListenable<int> get unreadCountListenable => _unreadCount;

  InboxApi? _inbox;
  List<CardView> _cards = const [];
  Object? _error;
  bool _booting = true;
  bool _bootStarted = false;
  StreamSubscription<DocEvent>? _watchSub;

  /// Card ids we've already raised a notification for (notify at most once each).
  final Set<String> _notified = {};

  // Cycle a few representative summaries for the debug push.
  static const _samples = [
    'Deploy production?',
    'Approve PR #42',
    'Lunch time',
    'Run the migration?',
  ];

  List<CardView> get cards => _cards;
  Object? get error => _error;
  bool get booting => _booting;
  InboxApi? get inbox => _inbox;

  /// Number of still-unread cards — the source of truth for every red-dot badge.
  int get unreadCount =>
      _cards.where((c) => c.status == CardStatus.unread).length;

  @override
  void dispose() {
    _watchSub?.cancel();
    _unreadCount.dispose();
    super.dispose();
  }

  /// Recompute the unread count and push it to the listenable + badge surface.
  /// Called after every list change so the red dot stays in sync.
  void _publishUnread() {
    final int count = unreadCount;
    _unreadCount.value = count; // ValueNotifier no-ops if unchanged
    _badge.setBadge(count);
  }

  /// Boot the inbox node and start watching. Idempotent: safe to call from more
  /// than one UI entry point; only the first call does the work.
  Future<void> boot() async {
    if (_bootStarted) return;
    _bootStarted = true;
    try {
      // Notifications are best-effort; a denied/failed init must not block boot.
      try {
        await _notifier.init();
      } catch (_) {}
      final inbox = await _createInbox();
      _inbox = inbox;
      _watchSub = inbox.watch().listen(_onDocEvent);
      await _refresh();
    } catch (e) {
      _error = e;
    } finally {
      _booting = false;
      notifyListeners();
    }
  }

  /// Refresh the list on any doc change, and raise a native notification the
  /// first time a card arrives (kind == "message").
  Future<void> _onDocEvent(DocEvent event) async {
    await _refresh();
    final CardView? card = newCardFor(event.kind, event.msgId, _cards);
    if (card != null && _notified.add(card.id)) {
      await _notifier.notifyCard(card);
    }
  }

  Future<void> refresh() => _refresh();

  Future<void> _refresh() async {
    final inbox = _inbox;
    if (inbox == null) return;
    _cards = await inbox.listMessages();
    _publishUnread();
    notifyListeners();
  }

  /// Push a representative sample card (debug affordance).
  Future<void> pushDebugCard() async {
    final inbox = _inbox;
    if (inbox == null) return;
    final summary = _samples[_cards.length % _samples.length];
    await inbox.push(
      summary: summary,
      a2UiJson: sampleA2uiJson(surfaceId: 'card', title: summary),
    );
    await _refresh();
  }

  /// This inbox's pairing ticket, for rendering as a QR code.
  Future<String> ticket() async {
    final inbox = _inbox;
    if (inbox == null) {
      throw StateError('inbox not booted');
    }
    return inbox.ticket();
  }

  /// Spin up a node that joins the inbox behind [ticket] and switch to it.
  Future<void> joinInbox(String ticket) async {
    final joined = await _joinInbox(ticket);
    await _watchSub?.cancel();
    _inbox = joined;
    _notified.clear();
    _watchSub = joined.watch().listen(_onDocEvent);
    await _refresh();
  }

  // --- Card action forwarding (used by list page + floating surfaces) ---

  Future<void> recordAction(
    String cardId,
    String name,
    Map<String, Object?> context,
  ) async {
    await _inbox?.recordAction(
      msgId: cardId,
      actionName: name,
      actionContextJson: context.isEmpty ? null : jsonEncode(context),
    );
    await _refresh();
  }

  Future<void> dismiss(String cardId) async {
    await _inbox?.recordAction(msgId: cardId, actionName: 'dismiss');
    await _refresh();
  }

  Future<void> setData(String cardId, String path, Object? value) async {
    await _inbox?.setData(
      msgId: cardId,
      bindPath: path,
      valueJson: jsonEncode(value),
    );
  }

  /// Live data-model updates for one card, derived from the inbox event stream:
  /// on any `data` event for this card (or a `tick` marking freshly-synced
  /// remote content as readable), re-pull each declared bind path and emit it.
  Stream<CardDataUpdate> watchCardData(String cardId, List<String> paths) async* {
    final inbox = _inbox;
    if (inbox == null || paths.isEmpty) return;
    await for (final DocEvent event in inbox.watch()) {
      final bool relevant =
          (event.kind == 'data' && event.msgId == cardId) ||
              event.kind == 'tick';
      if (!relevant) continue;
      for (final String path in paths) {
        final String? json = await inbox.getData(msgId: cardId, bindPath: path);
        if (json != null) {
          yield CardDataUpdate(path: path, value: jsonDecode(json));
        }
      }
    }
  }
}
