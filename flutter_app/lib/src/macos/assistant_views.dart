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

/// One card, rendered large and centred — the focus surface. When ≥2 cards are
/// pending it carries a tab strip across the top so the whole queue is
/// switchable in place (Fleet's Decision Panel model): tap a tab to switch the
/// active card, resolve one and it advances to the next without bouncing back
/// to the picker. [onResolved] fires only when the queue empties (→ icon).
class AssistantCardView extends StatefulWidget {
  const AssistantCardView({
    super.key,
    required this.cardId,
    required this.onResolved,
    required this.onOpenInbox,
  });

  final String cardId;
  final VoidCallback onResolved;
  final VoidCallback onOpenInbox;

  @override
  State<AssistantCardView> createState() => _AssistantCardViewState();
}

class _AssistantCardViewState extends State<AssistantCardView> {
  late String _activeId = widget.cardId;

  @override
  void didUpdateWidget(AssistantCardView old) {
    super.didUpdateWidget(old);
    // The shell pushed a different card (e.g. a fresh single-card open): follow it.
    if (widget.cardId != old.cardId) _activeId = widget.cardId;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final List<CardView> pending = pendingCards();
        if (pending.isEmpty) {
          // Queue drained — collapse to the icon.
          WidgetsBinding.instance.addPostFrameCallback((_) => widget.onResolved());
          return const SizedBox.shrink();
        }
        // Keep the active id valid: if the active card was just resolved, fall
        // through to the next still-pending card instead of leaving the surface.
        final CardView active = pending.firstWhere(
          (c) => c.id == _activeId,
          orElse: () => pending.first,
        );
        if (active.id != _activeId) _activeId = active.id;

        final paths = dataPaths(parseA2uiMessages(active.a2UiJson));
        return Scaffold(
          appBar: AppBar(
            title: Text(active.summary),
            bottom: pending.length >= 2
                ? QueueTabs(
                    pending: pending,
                    activeId: _activeId,
                    onSelect: (id) => setState(() => _activeId = id),
                  )
                : null,
            actions: [
              IconButton(
                icon: const Icon(Icons.all_inbox),
                tooltip: 'Open full inbox',
                onPressed: widget.onOpenInbox,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Dismiss',
                onPressed: () => _c.dismiss(active.id),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: CardDetailView(
                  // Key by id so switching tabs rebuilds the surface cleanly.
                  key: ValueKey(active.id),
                  card: active,
                  onAction: (action) =>
                      _c.recordAction(active.id, action.name, action.context),
                  onDataChanged: (path, value) =>
                      _c.setData(active.id, path, value),
                  remoteData: _c.watchCardData(active.id, paths),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The pending-queue tab strip shown above a card when ≥2 are waiting: a
/// horizontally scrollable row of chips — the active card highlighted, a
/// pending count on the left — that switches the active card in place.
class QueueTabs extends StatelessWidget implements PreferredSizeWidget {
  const QueueTabs({
    required this.pending,
    required this.activeId,
    required this.onSelect,
  });

  final List<CardView> pending;
  final String activeId;
  final ValueChanged<String> onSelect;

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '${pending.length} pending',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 12),
              itemCount: pending.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final card = pending[i];
                final bool selected = card.id == activeId;
                return Center(
                  child: ChoiceChip(
                    label: Text(
                      card.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: selected,
                    onSelected: (_) => onSelect(card.id),
                    selectedColor: scheme.primaryContainer,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
