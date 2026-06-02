// The chat-head bubble — runs in flutter_overlay_window's SEPARATE engine /
// isolate. Constraint 1: there is no InboxHandle here. It only consumes `cards`
// snapshots pushed from the main isolate and sends back user commands; the main
// isolate executes them against the CRDT.
//
// Collapsed it's a small circle with a red unread badge. Tapping expands a panel
// of pending cards; tapping a card renders its A2UI inline (reusing
// CardDetailView — this is spike 2: genui must work in the overlay engine) and
// the user's action / dismiss / edits are shared back to the main isolate.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'package:flutter_app/src/android/overlay_bridge.dart';
import 'package:flutter_app/src/data/card_data_bridge.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

/// Entry point launched by flutter_overlay_window in the overlay isolate.
@pragma('vm:entry-point')
void overlayMain() {
  runApp(const OverlayBubbleApp());
}

// Collapsed / expanded overlay sizes (px). The host resizes the window to match.
const int _collapsedPx = 64;
const int _expandedW = 340;
const int _expandedH = 480;

class OverlayBubbleApp extends StatefulWidget {
  const OverlayBubbleApp({super.key});

  @override
  State<OverlayBubbleApp> createState() => _OverlayBubbleAppState();
}

class _OverlayBubbleAppState extends State<OverlayBubbleApp> {
  StreamSubscription<dynamic>? _sub;
  int _unread = 0;
  List<OverlayCard> _cards = const [];
  bool _expanded = false;
  String? _openCardId;

  // Feeds peer-synced data-model values into the open card's CardDetailView.
  final StreamController<CardDataUpdate> _remote =
      StreamController<CardDataUpdate>.broadcast();

  @override
  void initState() {
    super.initState();
    _sub = FlutterOverlayWindow.overlayListener.listen(_onMessage);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _remote.close();
    super.dispose();
  }

  void _onMessage(dynamic message) {
    final OverlaySnapshot? snap = parseSnapshot(message);
    if (snap == null) return;
    setState(() {
      _unread = snap.unreadCount;
      _cards = snap.cards;
    });
    // Push the open card's latest bound values into its surface.
    final OverlayCard? open = _open;
    if (open != null) {
      open.dataValues.forEach((path, value) {
        _remote.add(CardDataUpdate(path: path, value: value));
      });
    }
  }

  OverlayCard? get _open {
    final id = _openCardId;
    if (id == null) return null;
    for (final c in _cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _collapse() async {
    setState(() {
      _expanded = false;
      _openCardId = null;
    });
    await FlutterOverlayWindow.resizeOverlay(_collapsedPx, _collapsedPx, true);
  }

  Future<void> _expand() async {
    setState(() => _expanded = true);
    await FlutterOverlayWindow.resizeOverlay(_expandedW, _expandedH, false);
  }

  void _send(Map<String, Object?> command) => FlutterOverlayWindow.shareData(command);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: _expanded ? _panel() : _bubble(),
      ),
    );
  }

  Widget _bubble() {
    return Center(
      child: GestureDetector(
        onTap: _expand,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: Color(0xFF3D5AFE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.chat_bubble, color: Colors.white),
            ),
            if (_unread > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                  child: Text(
                    _unread > 99 ? '99+' : '$_unread',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _panel() {
    final OverlayCard? open = _open;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (open != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _openCardId = null),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    open?.summary ?? 'Assistant',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.open_in_new),
                tooltip: 'Open full inbox',
                onPressed: () => _send(openInboxCommand()),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Collapse',
                onPressed: _collapse,
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(child: open != null ? _cardDetail(open) : _cardList()),
        ],
      ),
    );
  }

  Widget _cardList() {
    final List<OverlayCard> pending =
        _cards.where((c) => c.status == 'unread').toList();
    if (pending.isEmpty) {
      return const Center(child: Text('All caught up.'));
    }
    return ListView.builder(
      itemCount: pending.length,
      itemBuilder: (_, i) {
        final c = pending[i];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.mark_email_unread),
          title: Text(c.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(c.source),
          onTap: () => setState(() => _openCardId = c.id),
        );
      },
    );
  }

  Widget _cardDetail(OverlayCard card) {
    // Reconstruct a CardView for CardDetailView (status only drives display here).
    final view = CardView(
      id: card.id,
      summary: card.summary,
      source: card.source,
      createdAt: BigInt.from(card.createdAt),
      a2UiJson: card.a2UiJson,
      status: _statusFrom(card.status),
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardDetailView(
            card: view,
            onAction: (action) {
              _send(actionCommand(card.id, action.name, action.context));
              _collapse();
            },
            onDataChanged: (path, value) =>
                _send(setDataCommand(card.id, path, value)),
            remoteData: _remote.stream,
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.close),
            label: const Text('Dismiss'),
            onPressed: () {
              _send(dismissCommand(card.id));
              _collapse();
            },
          ),
        ],
      ),
    );
  }

  CardStatus _statusFrom(String s) {
    switch (s) {
      case 'dismissed':
        return CardStatus.dismissed;
      case 'actioned':
        return CardStatus.actioned;
      default:
        return CardStatus.unread;
    }
  }
}
