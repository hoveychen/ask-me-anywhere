// ask-me-anywhere — Flutter macOS shell.
//
// Boots an in-memory inbox via the FRB bridge to ama-core, renders the local
// cards in a list, and lets you tap into a card's live A2UI surface. The debug
// FAB pushes a real sample A2UI tree so there's something to render; tapping a
// card opens it, where actions (Approve / Dismiss) and bound-field edits flow
// back into the CRDT. A `watch()` subscription refreshes the list as state
// converges. M3c adds QR pairing + native notifications.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:flutter_app/src/a2ui_sample.dart';
import 'package:flutter_app/src/data/card_data_bridge.dart';
import 'package:flutter_app/src/notify/card_notifier.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/rust/frb_generated.dart';
import 'package:flutter_app/src/ui/card_detail_screen.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';
import 'package:flutter_app/src/ui/join_screen.dart';
import 'package:flutter_app/src/ui/pairing_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const AmaApp());
}

class AmaApp extends StatelessWidget {
  const AmaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ask-me-anywhere',
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: const InboxView(),
    );
  }
}

class InboxView extends StatefulWidget {
  const InboxView({super.key});

  @override
  State<InboxView> createState() => _InboxViewState();
}

class _InboxViewState extends State<InboxView> {
  InboxHandle? _inbox;
  List<CardView> _cards = const [];
  Object? _error;
  bool _booting = true;
  StreamSubscription<DocEvent>? _watchSub;
  final LocalCardNotifier _notifier = LocalCardNotifier();
  // Card ids we've already raised a notification for (notify at most once each).
  final Set<String> _notified = {};
  // Cycle a few representative summaries for the debug FAB.
  static const _samples = [
    'Deploy production?',
    'Approve PR #42',
    'Lunch time',
    'Run the migration?',
  ];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      // Notifications are best-effort; a denied/failed init must not block boot.
      try {
        await _notifier.init();
      } catch (_) {}
      final inbox = await InboxHandle.create(device: 'desktop');
      _inbox = inbox;
      // Refresh + maybe notify whenever the doc changes (local + remote writes).
      _watchSub = inbox.watch().listen(_onDocEvent);
      await _refresh();
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _booting = false);
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

  Future<void> _refresh() async {
    final inbox = _inbox;
    if (inbox == null) return;
    final cards = await inbox.listMessages();
    if (!mounted) return;
    setState(() => _cards = cards);
  }

  Future<void> _pushDebugCard() async {
    final inbox = _inbox;
    if (inbox == null) return;
    final summary = _samples[_cards.length % _samples.length];
    await inbox.push(
      summary: summary,
      a2UiJson: sampleA2uiJson(surfaceId: 'card', title: summary),
    );
    await _refresh();
  }

  Future<void> _openCard(CardView card) async {
    final inbox = _inbox;
    if (inbox == null) return;
    final List<String> paths = dataPaths(parseA2uiMessages(card.a2UiJson));
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CardDetailScreen(
          card: card,
          onAction: (action) => inbox.recordAction(
            msgId: card.id,
            actionName: action.name,
            actionContextJson:
                action.context.isEmpty ? null : jsonEncode(action.context),
          ),
          onDismiss: () =>
              inbox.recordAction(msgId: card.id, actionName: 'dismiss'),
          onDataChanged: (path, value) => inbox.setData(
            msgId: card.id,
            bindPath: path,
            valueJson: jsonEncode(value),
          ),
          remoteData: _watchCardData(inbox, card.id, paths),
        ),
      ),
    );
    await _refresh();
  }

  /// Fetch this inbox's pairing ticket and show it as a QR code to scan.
  Future<void> _openPairing() async {
    final inbox = _inbox;
    if (inbox == null) return;
    final String ticket = await inbox.ticket();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PairingScreen(ticket: ticket)),
    );
  }

  /// Open the join screen; on success we're now running the joined inbox.
  Future<void> _openJoin() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => JoinScreen(onJoin: _joinInbox)),
    );
  }

  /// Spin up a node that joins the inbox behind [ticket] and switch to it — the
  /// list then fills with the peer's synced cards.
  Future<void> _joinInbox(String ticket) async {
    final joined = await InboxHandle.join(ticket: ticket, device: 'desktop');
    await _watchSub?.cancel();
    _inbox = joined;
    _watchSub = joined.watch().listen(_onDocEvent);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ask-me-anywhere · inbox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'Pair a device',
            onPressed: _inbox != null ? _openPairing : null,
          ),
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: 'Join an inbox',
            onPressed: _inbox != null ? _openJoin : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _inbox != null ? _refresh : null,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _inbox != null ? _pushDebugCard : null,
        icon: const Icon(Icons.add),
        label: const Text('Push test card'),
      ),
      body: _booting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('boot failed: $_error'))
              : _cards.isEmpty
                  ? const Center(
                      child: Text(
                        '(no cards yet — press the button)',
                        style: TextStyle(fontStyle: FontStyle.italic),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _cards.length,
                      itemBuilder: (_, i) =>
                          _CardTile(_cards[i], onTap: () => _openCard(_cards[i])),
                    ),
    );
  }
}

/// Live data-model updates for one card, derived from the inbox event stream:
/// on any `data` event for this card (or a `tick` marking freshly-synced remote
/// content as readable), re-pull each declared bind path and emit its value.
Stream<CardDataUpdate> _watchCardData(
  InboxHandle inbox,
  String cardId,
  List<String> paths,
) async* {
  if (paths.isEmpty) return;
  await for (final DocEvent event in inbox.watch()) {
    final bool relevant =
        (event.kind == 'data' && event.msgId == cardId) || event.kind == 'tick';
    if (!relevant) continue;
    for (final String path in paths) {
      final String? json = await inbox.getData(msgId: cardId, bindPath: path);
      if (json != null) {
        yield CardDataUpdate(path: path, value: jsonDecode(json));
      }
    }
  }
}

class _CardTile extends StatelessWidget {
  final CardView card;
  final VoidCallback onTap;
  const _CardTile(this.card, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final created =
        DateTime.fromMillisecondsSinceEpoch(card.createdAt.toInt()).toLocal();
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(child: Icon(_iconForStatus(card.status))),
      title: Text(card.summary),
      subtitle: Text(
        '${_formatTime(created)} · ${card.source} · ${card.status.name}',
      ),
      trailing: Text(
        card.id.length > 8 ? card.id.substring(0, 8) : card.id,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    );
  }

  IconData _iconForStatus(CardStatus s) {
    switch (s) {
      case CardStatus.unread:
        return Icons.mark_email_unread;
      case CardStatus.dismissed:
        return Icons.done;
      case CardStatus.actioned:
        return Icons.check_circle;
    }
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
