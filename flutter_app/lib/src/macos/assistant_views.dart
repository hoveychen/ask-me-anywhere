// The macOS resident-assistant surfaces (the window content for each
// AssistantSurfaceKind). All observe the shared [AssistantController]:
//
//   - [AssistantIconView]   the tiny resident icon + pending-count badge.
//   - [AssistantPickerView] a mini list to choose which pending card to open.
//   - [AssistantCardView]   one card's A2UI rendered large & centred (reusing
//                           CardDetailView — no navigation), to take full focus.
import 'package:flutter/material.dart';

import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/state/assistant_controller.dart';
import 'package:flutter_app/src/ui/assistant_visuals.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

AssistantController get _c => AssistantController.instance;

List<CardView> pendingCards() =>
    _c.cards.where((c) => c.status == CardStatus.unread).toList();

/// The resident icon: a circular chat button with a red unread badge. Tapping
/// it asks the shell to expand (the shell decides list / card / picker).
class AssistantIconView extends StatelessWidget {
  const AssistantIconView({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedBuilder(
            animation: _c.unreadCountListenable,
            builder: (context, _) =>
                AssistantBubble(count: _c.unreadCountListenable.value),
          ),
        ),
      ),
    );
  }
}

/// Mini list to pick which pending card to open (shown when ≥2 are pending).
class AssistantPickerView extends StatelessWidget {
  const AssistantPickerView({
    super.key,
    required this.onPick,
    required this.onOpenInbox,
  });

  final ValueChanged<String> onPick;
  final VoidCallback onOpenInbox;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final List<CardView> pending = pendingCards();
        return Scaffold(
          appBar: AppBar(
            title: Text('${pending.length} to handle'),
            actions: [
              IconButton(
                icon: const Icon(Icons.all_inbox),
                tooltip: 'Open full inbox',
                onPressed: onOpenInbox,
              ),
            ],
          ),
          body: ListView.builder(
            itemCount: pending.length,
            itemBuilder: (_, i) {
              final card = pending[i];
              return ListTile(
                leading: const Icon(Icons.mark_email_unread),
                title:
                    Text(card.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(card.source),
                onTap: () => onPick(card.id),
              );
            },
          ),
        );
      },
    );
  }
}

/// One card, rendered large and centred — the focus surface. The A2UI surface is
/// reused from CardDetailView; acting or dismissing calls [onResolved].
class AssistantCardView extends StatelessWidget {
  const AssistantCardView({
    super.key,
    required this.cardId,
    required this.onResolved,
    required this.onOpenInbox,
  });

  final String cardId;
  final VoidCallback onResolved;
  final VoidCallback onOpenInbox;

  CardView? _card() {
    for (final c in _c.cards) {
      if (c.id == cardId) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final CardView? card = _card();
        if (card == null) {
          // Resolved/removed elsewhere — bounce back out.
          WidgetsBinding.instance.addPostFrameCallback((_) => onResolved());
          return const SizedBox.shrink();
        }
        final paths = dataPaths(parseA2uiMessages(card.a2UiJson));
        return Scaffold(
          appBar: AppBar(
            title: Text(card.summary),
            actions: [
              IconButton(
                icon: const Icon(Icons.all_inbox),
                tooltip: 'Open full inbox',
                onPressed: onOpenInbox,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Dismiss',
                onPressed: () async {
                  await _c.dismiss(card.id);
                  onResolved();
                },
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: CardDetailView(
                  card: card,
                  onAction: (action) async {
                    await _c.recordAction(card.id, action.name, action.context);
                    onResolved();
                  },
                  onDataChanged: (path, value) => _c.setData(card.id, path, value),
                  remoteData: _c.watchCardData(card.id, paths),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
