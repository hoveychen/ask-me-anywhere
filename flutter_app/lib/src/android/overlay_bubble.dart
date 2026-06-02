// The Android chat-head — runs in flutter_overlay_window's SEPARATE engine /
// isolate. Constraint 1: there is no InboxHandle here; it only consumes `cards`
// snapshots pushed from the main isolate and sends back commands.
//
// Same surface model as macOS (shared [AssistantSurface]):
//   - bubble (icon): a small circle with the pending-count badge.
//   - tap → 0 pending: the inbox list as a right-edge drawer (not full-attention).
//          → 1 pending: that card, centred and large (full attention).
//          → ≥2 pending: a picker to choose which card.
//   - tap the scrim outside the panel → collapse back to the bubble.
//
// Expanded surfaces resize the overlay to cover the screen (so the scrim catches
// outside taps); the bubble shrinks it back.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'package:flutter_app/src/android/overlay_bridge.dart';
import 'package:flutter_app/src/data/card_data_bridge.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/state/assistant_surface.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

// NOTE: the overlay isolate entry point (`overlayMain`) lives in lib/main.dart,
// NOT here. flutter_overlay_window resolves the "overlayMain" Dart entry by name
// in the ROOT library only — DartEntrypoint(bundlePath, "overlayMain") — so a
// top-level function in this (non-root) library is never found, leaving the
// overlay window blank. Keep the entry in main.dart.

const int _bubblePx = 72;

// The overlay service's own MethodChannel (handled inside the overlay isolate's
// engine). The public Dart API routes moveOverlay() through the *main* plugin
// channel, which the overlay isolate can't reach — but the service also accepts
// `updateOverlayPosition` on this channel, so we drive position resets directly.
const MethodChannel _overlayServiceCh = MethodChannel('x-slayer/overlay');

class OverlayBubbleApp extends StatefulWidget {
  const OverlayBubbleApp({super.key});

  @override
  State<OverlayBubbleApp> createState() => _OverlayBubbleAppState();
}

class _OverlayBubbleAppState extends State<OverlayBubbleApp> {
  StreamSubscription<dynamic>? _sub;
  OverlaySnapshot _snap = const OverlaySnapshot(unreadCount: 0, cards: []);
  AssistantSurfaceState _surface = AssistantSurfaceState.icon;
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
    setState(() => _snap = snap);
    // Feed the open card's latest bound values into its surface.
    final open = _openCard;
    if (open != null) {
      open.dataValues.forEach((path, value) {
        _remote.add(CardDataUpdate(path: path, value: value));
      });
    }
  }

  List<OverlayCard> get _cards => _snap.cards;
  List<String> get _pendingIds =>
      _cards.where((c) => c.status == 'unread').map((c) => c.id).toList();

  OverlayCard? get _openCard {
    if (_surface.kind != AssistantSurfaceKind.card) return null;
    for (final c in _cards) {
      if (c.id == _surface.cardId) return c;
    }
    return null;
  }

  void _send(Map<String, Object?> command) =>
      FlutterOverlayWindow.shareData(command);

  Future<void> _go(AssistantSurfaceState state) async {
    setState(() => _surface = state);
    if (state.isExpanded) {
      // Reset the window to the screen origin FIRST. The bubble carries a drag
      // offset (e.g. parked at the right edge), and resizeOverlay does NOT clear
      // x/y — so without this the grown window stays pushed off-screen and only
      // a sliver shows. gravity is RIGHT|CENTER, so x=0 anchors it flush.
      await _moveTo(0, 0);
      // Full-screen. Width MATCH_PARENT works, but resizeOverlay's HEIGHT branch
      // is a plugin bug — `(height != 1999 || height != -1)` is always true, so
      // it always runs dpToPx(height) and can never set MATCH_PARENT. Passing
      // matchParent(-1) becomes dpToPx(-1) ≈ -2 = WRAP_CONTENT, collapsing the
      // content to nothing (the white sliver). So we pass the real screen height
      // in dp, measured on the main isolate and shipped in the snapshot.
      final int heightDp = _snap.screenHeight > 0
          ? _snap.screenHeight.round()
          : WindowSize.matchParent;
      await FlutterOverlayWindow.resizeOverlay(
          WindowSize.matchParent, heightDp, false);
    } else {
      await FlutterOverlayWindow.resizeOverlay(_bubblePx, _bubblePx, true);
      // Return the bubble to a predictable anchor so the next expand starts clean.
      await _moveTo(0, 0);
    }
  }

  /// Reset the overlay window position via the service channel (the public
  /// moveOverlay() API isn't reachable from the overlay isolate).
  Future<void> _moveTo(int x, int y) async {
    try {
      await _overlayServiceCh
          .invokeMethod('updateOverlayPosition', {'x': x, 'y': y});
    } catch (_) {
      // Best-effort; a failed move must not break the surface transition.
    }
  }

  void _resolve(String cardId) {
    final remaining = _pendingIds.where((id) => id != cardId).toList();
    _go(AssistantSurface.onResolveCard(remaining));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: _surface.kind == AssistantSurfaceKind.icon ? _bubble() : _expanded(),
      ),
    );
  }

  // --- bubble ---

  Widget _bubble() {
    return Center(
      child: GestureDetector(
        onTap: () => _go(AssistantSurface.onTapIcon(_pendingIds)),
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
              child: const Icon(Icons.all_inbox, color: Colors.white),
            ),
            if (_snap.unreadCount > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    _snap.unreadCount > 99 ? '99+' : '${_snap.unreadCount}',
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

  // --- expanded: scrim + panel ---

  Widget _expanded() {
    return Stack(
      children: [
        // Tap-away scrim collapses to the bubble.
        Positioned.fill(
          child: GestureDetector(
            onTap: () => _go(AssistantSurface.onCollapse),
            child: Container(color: Colors.black54),
          ),
        ),
        _panel(),
      ],
    );
  }

  Widget _panel() {
    switch (_surface.kind) {
      case AssistantSurfaceKind.card:
        return _cardPanel();
      case AssistantSurfaceKind.picker:
        return _centeredList('Pick one to handle');
      case AssistantSurfaceKind.list:
        return _drawerList();
      case AssistantSurfaceKind.icon:
        return const SizedBox.shrink();
    }
  }

  /// The inbox as a right-edge drawer (not the full-attention surface).
  Widget _drawerList() {
    return Align(
      alignment: Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 0.82,
        heightFactor: 1,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(child: _cardListBody('Inbox')),
        ),
      ),
    );
  }

  /// The picker — a centred chooser when several cards are pending.
  Widget _centeredList(String title) {
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.86,
        heightFactor: 0.7,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: _cardListBody(title),
        ),
      ),
    );
  }

  Widget _cardListBody(String title) {
    final pending = _cards.where((c) => c.status == 'unread').toList();
    return Column(
      children: [
        AppBar(
          title: Text(title),
          automaticallyImplyLeading: false,
          actions: [
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => _go(AssistantSurface.onCollapse),
            ),
          ],
        ),
        Expanded(
          child: pending.isEmpty
              ? const Center(child: Text('All caught up.'))
              : ListView.builder(
                  itemCount: pending.length,
                  itemBuilder: (_, i) {
                    final c = pending[i];
                    return ListTile(
                      leading: const Icon(Icons.mark_email_unread),
                      title: Text(c.summary,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(c.source),
                      onTap: () => _go(AssistantSurface.onPick(c.id)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// One card, centred and large — the full-attention surface.
  Widget _cardPanel() {
    final OverlayCard? card = _openCard;
    if (card == null) {
      return const SizedBox.shrink();
    }
    final view = CardView(
      id: card.id,
      summary: card.summary,
      source: card.source,
      createdAt: BigInt.from(card.createdAt),
      a2UiJson: card.a2UiJson,
      status: CardStatus.unread,
    );
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.92,
        heightFactor: 0.86,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              AppBar(
                title: Text(card.summary,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                automaticallyImplyLeading: false,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.open_in_new),
                    tooltip: 'Open full inbox',
                    onPressed: () => _send(openInboxCommand()),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Dismiss',
                    onPressed: () {
                      _send(dismissCommand(card.id));
                      _resolve(card.id);
                    },
                  ),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: CardDetailView(
                    card: view,
                    onAction: (action) {
                      _send(actionCommand(card.id, action.name, action.context));
                      _resolve(card.id);
                    },
                    onDataChanged: (path, value) =>
                        _send(setDataCommand(card.id, path, value)),
                    remoteData: _remote.stream,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
