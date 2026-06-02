// ask-me-anywhere — Flutter shell.
//
// Boots an in-memory inbox via the FRB bridge to ama-core and renders the local
// cards. State now lives in a shared [AssistantController] (lifted out of this
// widget) so the macOS floating window and the Android overlay can observe the
// same inbox; this list page is one observer of it. Tapping a card opens its
// live A2UI surface, where actions (Approve / Dismiss) and bound-field edits
// flow back into the CRDT. M3c adds QR pairing + native notifications.
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_app/src/android/overlay_host.dart';
import 'package:flutter_app/src/macos/assistant_views.dart';
import 'package:flutter_app/src/macos/assistant_window.dart';
import 'package:flutter_app/src/macos/dock_badge.dart';
import 'package:flutter_app/src/notify/foreground_service.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/rust/frb_generated.dart';
import 'package:flutter_app/src/state/assistant_controller.dart';
import 'package:flutter_app/src/state/assistant_surface.dart';
import 'package:flutter_app/src/ui/card_detail_screen.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';
import 'package:flutter_app/src/ui/join_screen.dart';
import 'package:flutter_app/src/ui/pairing_screen.dart';

bool get _isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
bool get _isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  if (_isMacOS) {
    await AssistantWindowManager.ensureInitialized();
  }
  runApp(const AmaApp());
}

class AmaApp extends StatelessWidget {
  const AmaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ask-me-anywhere',
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: const RootShell(),
    );
  }
}

/// The resident assistant shell. On macOS it owns the window surface state
/// machine: a tiny always-on-top icon that expands — on tap or click-away
/// collapse — into the inbox list, a centred card, or a picker, per
/// [AssistantSurface]. Closing the window collapses to the icon (never quits).
/// On every other platform it's just the inbox list (Android adds the overlay).
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell>
    with WindowListener, WidgetsBindingObserver {
  final AssistantWindowManager _window = AssistantWindowManager();
  AssistantSurfaceState _surface = AssistantSurfaceState.icon;
  OverlayHost? _overlayHost;
  // Reshaping + focusing the window emits transient blur events; ignore
  // click-away collapse while a transition is still settling.
  bool _settling = false;

  List<String> get _pendingIds =>
      AssistantController.instance.cards
          .where((c) => c.status == CardStatus.unread)
          .map((c) => c.id)
          .toList();

  @override
  void initState() {
    super.initState();
    if (_isMacOS) {
      windowManager.addListener(this);
      // Closing the window must not quit — collapse to the resident icon.
      windowManager.setPreventClose(true);
      AssistantController.instance.badge = DockBadge();
      // Start resident as the icon once the first frame is up.
      WidgetsBinding.instance.addPostFrameCallback((_) => _go(AssistantSurfaceState.icon));
    }
    if (_isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      _overlayHost = OverlayHost(AssistantController.instance);
    }
  }

  @override
  void dispose() {
    if (_isMacOS) {
      windowManager.removeListener(this);
    }
    if (_isAndroid) {
      WidgetsBinding.instance.removeObserver(this);
      _overlayHost?.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isAndroid) return;
    // Resident assistant: show the chat-head bubble while the app is away,
    // hide it when the user is back in the full inbox.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _overlayHost?.show();
        break;
      case AppLifecycleState.resumed:
        _overlayHost?.hide();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void onWindowClose() {
    // preventClose swallowed the quit; collapse to the resident icon.
    if (_isMacOS) _go(AssistantSurfaceState.icon);
  }

  @override
  void onWindowBlur() {
    // Click-away: any expanded surface collapses back to the icon — but not the
    // transient blur emitted mid-transition (that would collapse instantly).
    if (_isMacOS && !_settling && _surface.isExpanded) {
      _go(AssistantSurfaceState.icon);
    }
  }

  /// Switch to [state]: reshape the window, then render its surface.
  Future<void> _go(AssistantSurfaceState state) async {
    if (!mounted) return;
    _settling = true;
    setState(() => _surface = state);
    await _window.apply(state);
    // Let focus settle before re-arming click-away collapse.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _settling = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isMacOS) return const InboxView();
    switch (_surface.kind) {
      case AssistantSurfaceKind.icon:
        return AssistantIconView(
          onTap: () => _go(AssistantSurface.onTapIcon(_pendingIds)),
        );
      case AssistantSurfaceKind.picker:
        return AssistantPickerView(
          onPick: (id) => _go(AssistantSurface.onPick(id)),
          onOpenInbox: () => _go(AssistantSurface.onOpenInbox),
        );
      case AssistantSurfaceKind.card:
        return AssistantCardView(
          cardId: _surface.cardId!,
          onResolved: () => _go(AssistantSurface.onResolveCard(_pendingIds)),
          onOpenInbox: () => _go(AssistantSurface.onOpenInbox),
        );
      case AssistantSurfaceKind.list:
        return const InboxView();
    }
  }
}

/// The full-screen "complete inbox": the card list plus pairing / join entry
/// points. A thin observer of [AssistantController.instance].
class InboxView extends StatefulWidget {
  const InboxView({super.key});

  @override
  State<InboxView> createState() => _InboxViewState();
}

class _InboxViewState extends State<InboxView> {
  AssistantController get _controller => AssistantController.instance;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _controller.boot();
    // Keep the node syncing when backgrounded (Android only; best-effort).
    try {
      await ForegroundService.start();
    } catch (_) {}
  }

  Future<void> _openCard(CardView card) async {
    final List<String> paths = dataPaths(parseA2uiMessages(card.a2UiJson));
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CardDetailScreen(
          card: card,
          onAction: (action) =>
              _controller.recordAction(card.id, action.name, action.context),
          onDismiss: () => _controller.dismiss(card.id),
          onDataChanged: (path, value) =>
              _controller.setData(card.id, path, value),
          remoteData: _controller.watchCardData(card.id, paths),
        ),
      ),
    );
    await _controller.refresh();
  }

  /// Fetch this inbox's pairing ticket and show it as a QR code to scan.
  Future<void> _openPairing() async {
    final String ticket = await _controller.ticket();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PairingScreen(ticket: ticket)),
    );
  }

  /// Open the join screen; on success we're now running the joined inbox.
  Future<void> _openJoin() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JoinScreen(onJoin: _controller.joinInbox),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final bool ready = !_controller.booting && _controller.inbox != null;
        final List<CardView> cards = _controller.cards;
        return Scaffold(
          appBar: AppBar(
            title: const Text('ask-me-anywhere · inbox'),
            actions: [
              IconButton(
                icon: const Icon(Icons.qr_code),
                tooltip: 'Pair a device',
                onPressed: ready ? _openPairing : null,
              ),
              IconButton(
                icon: const Icon(Icons.group_add),
                tooltip: 'Join an inbox',
                onPressed: ready ? _openJoin : null,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: ready ? _controller.refresh : null,
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: ready ? _controller.pushDebugCard : null,
            icon: const Icon(Icons.add),
            label: const Text('Push test card'),
          ),
          body: _controller.booting
              ? const Center(child: CircularProgressIndicator())
              : _controller.error != null
                  ? Center(child: Text('boot failed: ${_controller.error}'))
                  : cards.isEmpty
                      ? const Center(
                          child: Text(
                            '(no cards yet — press the button)',
                            style: TextStyle(fontStyle: FontStyle.italic),
                          ),
                        )
                      : ListView.builder(
                          itemCount: cards.length,
                          itemBuilder: (_, i) => _CardTile(
                            cards[i],
                            onTap: () => _openCard(cards[i]),
                          ),
                        ),
        );
      },
    );
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
