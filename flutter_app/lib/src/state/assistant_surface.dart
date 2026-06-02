// The shared surface state machine for the resident assistant — the same model
// drives the macOS floating windows and the Android overlay, so the click
// behaviour stays identical on both. Pure data + pure transitions (no Flutter,
// no platform calls) so it's unit-testable.
//
// Resident form is a small icon with a pending-count badge. From there:
//   - tap with 0 pending  → expand the full inbox list
//   - tap with 1 pending  → open that card, centred and large
//   - tap with ≥2 pending → a mini picker list to choose which card
//   - pick from the picker → open that card centred
//   - resolve a card (action/dismiss) → recompute: 0→icon, 1→that card, ≥2→picker
//   - click away / collapse → back to the icon
//   - "open full inbox" from anywhere → the list
import 'package:flutter/foundation.dart';

enum AssistantSurfaceKind { icon, list, picker, card }

@immutable
class AssistantSurfaceState {
  const AssistantSurfaceState(this.kind, {this.cardId});

  final AssistantSurfaceKind kind;

  /// Set only when [kind] is [AssistantSurfaceKind.card].
  final String? cardId;

  static const AssistantSurfaceState icon =
      AssistantSurfaceState(AssistantSurfaceKind.icon);
  static const AssistantSurfaceState list =
      AssistantSurfaceState(AssistantSurfaceKind.list);
  static const AssistantSurfaceState picker =
      AssistantSurfaceState(AssistantSurfaceKind.picker);
  static AssistantSurfaceState card(String id) =>
      AssistantSurfaceState(AssistantSurfaceKind.card, cardId: id);

  bool get isExpanded => kind != AssistantSurfaceKind.icon;

  @override
  bool operator ==(Object other) =>
      other is AssistantSurfaceState &&
      other.kind == kind &&
      other.cardId == cardId;

  @override
  int get hashCode => Object.hash(kind, cardId);

  @override
  String toString() => 'AssistantSurfaceState($kind${cardId == null ? '' : ', $cardId'})';
}

/// Pure transitions over [AssistantSurfaceState]. [pending] is the list of
/// still-unread card ids (newest first), the only input the transitions need.
class AssistantSurface {
  const AssistantSurface._();

  /// Tapping the resident icon.
  static AssistantSurfaceState onTapIcon(List<String> pending) {
    if (pending.isEmpty) return AssistantSurfaceState.list;
    if (pending.length == 1) return AssistantSurfaceState.card(pending.first);
    return AssistantSurfaceState.picker;
  }

  /// Choosing a card from the picker.
  static AssistantSurfaceState onPick(String cardId) =>
      AssistantSurfaceState.card(cardId);

  /// A card was acted on / dismissed; [pending] is the list AFTER the change.
  /// Keep working through the queue until it's empty, then collapse.
  static AssistantSurfaceState onResolveCard(List<String> pending) {
    if (pending.isEmpty) return AssistantSurfaceState.icon;
    if (pending.length == 1) return AssistantSurfaceState.card(pending.first);
    return AssistantSurfaceState.picker;
  }

  /// Click-away / explicit collapse.
  static const AssistantSurfaceState onCollapse = AssistantSurfaceState.icon;

  /// "Open full inbox" affordance, from any expanded surface.
  static const AssistantSurfaceState onOpenInbox = AssistantSurfaceState.list;
}
