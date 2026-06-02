// The macOS floating-panel UI: the resident assistant. Observes the shared
// [AssistantController] and shows the cards that still need attention. Tapping a
// card renders its live A2UI surface *inline* (reusing [CardDetailView]) instead
// of pushing a full-screen route — the whole point of the floating form. Acting
// on or dismissing a card returns to the list; "open full inbox" hands back to
// the list-mode window.
import 'package:flutter/material.dart';

import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/state/assistant_controller.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

class FloatingAssistantView extends StatefulWidget {
  const FloatingAssistantView({super.key, required this.onOpenInbox});

  /// Hand back to the full list-mode window.
  final VoidCallback onOpenInbox;

  @override
  State<FloatingAssistantView> createState() => _FloatingAssistantViewState();
}

class _FloatingAssistantViewState extends State<FloatingAssistantView> {
  AssistantController get _controller => AssistantController.instance;
  String? _openCardId;

  /// The cards worth surfacing in the panel: unread first, newest first.
  List<CardView> get _pending =>
      _controller.cards.where((c) => c.status == CardStatus.unread).toList();

  CardView? get _openCard {
    final id = _openCardId;
    if (id == null) return null;
    for (final c in _controller.cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final CardView? open = _openCard;
        return Scaffold(
          appBar: AppBar(
            leading: open != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back',
                    onPressed: () => setState(() => _openCardId = null),
                  )
                : null,
            titleSpacing: open != null ? 0 : null,
            title: Text(open?.summary ?? 'Assistant'),
            actions: [
              if (open == null)
                IconButton(
                  icon: const Icon(Icons.open_in_full),
                  tooltip: 'Open full inbox',
                  onPressed: widget.onOpenInbox,
                ),
            ],
          ),
          body: open != null ? _CardPanel(card: open, onResolved: _close) : _list(),
        );
      },
    );
  }

  void _close() => setState(() => _openCardId = null);

  Widget _list() {
    final List<CardView> pending = _pending;
    if (pending.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'All caught up.',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: pending.length,
      itemBuilder: (_, i) {
        final card = pending[i];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.mark_email_unread),
          title: Text(card.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(card.source),
          onTap: () => setState(() => _openCardId = card.id),
        );
      },
    );
  }
}

/// One card's live A2UI surface inside the floating panel, wired to the
/// controller; firing an action or dismissing returns to the list.
class _CardPanel extends StatelessWidget {
  const _CardPanel({required this.card, required this.onResolved});

  final CardView card;
  final VoidCallback onResolved;

  @override
  Widget build(BuildContext context) {
    final controller = AssistantController.instance;
    final paths = dataPaths(parseA2uiMessages(card.a2UiJson));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardDetailView(
            card: card,
            onAction: (action) {
              controller.recordAction(card.id, action.name, action.context);
              onResolved();
            },
            onDataChanged: (path, value) =>
                controller.setData(card.id, path, value),
            remoteData: controller.watchCardData(card.id, paths),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.close),
            label: const Text('Dismiss'),
            onPressed: () {
              controller.dismiss(card.id);
              onResolved();
            },
          ),
        ],
      ),
    );
  }
}
