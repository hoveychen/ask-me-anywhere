// Full-screen detail for one card: an app bar with a top dismiss button over
// the live A2UI surface ([CardDetailView]). Firing any A2UI action — or the top
// dismiss button — resolves the card and pops back to the inbox.
//
// FFI-free by design: it takes plain callbacks the host (InboxView) binds to the
// CRDT (`recordAction` / `setData`), so the screen stays widget-testable.
import 'package:flutter/material.dart';

import 'package:flutter_app/src/data/card_data_bridge.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

class CardDetailScreen extends StatelessWidget {
  const CardDetailScreen({
    super.key,
    required this.card,
    this.onAction,
    this.onDataChanged,
    this.onDismiss,
    this.remoteData,
  });

  final CardView card;

  /// A2UI action fired from the rendered surface (e.g. an Approve button).
  final ValueChanged<CardAction>? onAction;

  /// A bound data-model field was edited locally.
  final void Function(String path, Object? value)? onDataChanged;

  /// The top dismiss button was pressed.
  final VoidCallback? onDismiss;

  /// Values synced from peers for this card.
  final Stream<CardDataUpdate>? remoteData;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(card.summary),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Dismiss',
            onPressed: () {
              onDismiss?.call();
              Navigator.of(context).maybePop();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: CardDetailView(
          card: card,
          onAction: (action) {
            onAction?.call(action);
            Navigator.of(context).maybePop();
          },
          onDataChanged: onDataChanged,
          remoteData: remoteData,
        ),
      ),
    );
  }
}
