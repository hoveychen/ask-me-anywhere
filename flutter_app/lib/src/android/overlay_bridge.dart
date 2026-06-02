// The wire protocol between the main isolate (which owns the InboxHandle) and
// the chat-head overlay isolate (which owns no inbox — see constraint 1). All
// payloads are plain JSON maps, because flutter_overlay_window's shareData uses
// a JSONMessageCodec BasicMessageChannel.
//
//   main → overlay : a `cards` snapshot — everything the overlay needs to draw
//                    the red dot AND render a card's A2UI (a2UiJson + the bound
//                    paths + their current values), since it can't read the CRDT.
//   overlay → main : a command — the user acted in the bubble; the main isolate
//                    routes it to the controller (recordAction / setData / open).
//
// Pure functions only, so the round-trip is unit-testable without a device.
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

// ---------------------------------------------------------------------------
// main → overlay: the cards snapshot
// ---------------------------------------------------------------------------

/// One card flattened for the overlay isolate. Carries the rendering inputs the
/// overlay can't derive itself (no inbox there): the A2UI tree, its bound paths,
/// and the latest known values per path.
class OverlayCard {
  const OverlayCard({
    required this.id,
    required this.summary,
    required this.source,
    required this.createdAt,
    required this.a2UiJson,
    required this.status,
    required this.dataPaths,
    required this.dataValues,
  });

  final String id;
  final String summary;
  final String source;
  final int createdAt;
  final String a2UiJson;
  final String status;
  final List<String> dataPaths;
  final Map<String, Object?> dataValues;
}

/// What the overlay isolate receives each push.
class OverlaySnapshot {
  const OverlaySnapshot({
    required this.unreadCount,
    required this.cards,
    this.screenWidth = 0,
    this.screenHeight = 0,
  });

  final int unreadCount;
  final List<OverlayCard> cards;

  /// Logical-pixel (dp) size of the device screen, measured on the main isolate
  /// (the overlay's own view only spans the bubble, so it can't measure this
  /// itself). The overlay needs concrete dp to go full-screen: resizeOverlay()
  /// cannot set a MATCH_PARENT height — the plugin's height branch is a
  /// tautology that always runs dpToPx(height) — so we pass the real height.
  final double screenWidth;
  final double screenHeight;
}

/// Serialize one card for the wire. [dataValues] is the host's best-effort
/// snapshot of each bound path's converged value (may be partial / empty).
Map<String, Object?> cardToJson(
  CardView card, {
  Map<String, Object?> dataValues = const {},
}) {
  return {
    'id': card.id,
    'summary': card.summary,
    'source': card.source,
    'createdAt': card.createdAt.toInt(),
    'a2UiJson': card.a2UiJson,
    'status': card.status.name,
    'dataPaths': dataPaths(parseA2uiMessages(card.a2UiJson)),
    'dataValues': dataValues,
  };
}

OverlayCard _cardFromJson(Map<Object?, Object?> m) {
  return OverlayCard(
    id: m['id'] as String? ?? '',
    summary: m['summary'] as String? ?? '',
    source: m['source'] as String? ?? '',
    createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
    a2UiJson: m['a2UiJson'] as String? ?? '{}',
    status: m['status'] as String? ?? 'unread',
    dataPaths: (m['dataPaths'] as List?)?.whereType<String>().toList() ?? const [],
    dataValues: (m['dataValues'] as Map?)?.cast<String, Object?>() ?? const {},
  );
}

/// Build the snapshot the host pushes to the overlay. [screenWidth] /
/// [screenHeight] are the device's logical-pixel size (see [OverlaySnapshot]).
Map<String, Object?> snapshotToJson(
  int unreadCount,
  List<Map<String, Object?>> cards, {
  double screenWidth = 0,
  double screenHeight = 0,
}) {
  return {
    'type': 'cards',
    'unreadCount': unreadCount,
    'cards': cards,
    'screenWidth': screenWidth,
    'screenHeight': screenHeight,
  };
}

/// Parse a snapshot on the overlay side; null if [msg] isn't a cards snapshot.
OverlaySnapshot? parseSnapshot(dynamic msg) {
  if (msg is! Map || msg['type'] != 'cards') return null;
  final List cards = msg['cards'] as List? ?? const [];
  return OverlaySnapshot(
    unreadCount: (msg['unreadCount'] as num?)?.toInt() ?? 0,
    cards: cards
        .whereType<Map>()
        .map((e) => _cardFromJson(e.cast<Object?, Object?>()))
        .toList(growable: false),
    screenWidth: (msg['screenWidth'] as num?)?.toDouble() ?? 0,
    screenHeight: (msg['screenHeight'] as num?)?.toDouble() ?? 0,
  );
}

// ---------------------------------------------------------------------------
// overlay → main: user commands
// ---------------------------------------------------------------------------

enum OverlayCommandType { action, dismiss, setData, openInbox }

class OverlayCommand {
  const OverlayCommand({
    required this.type,
    this.cardId,
    this.name,
    this.context = const {},
    this.path,
    this.value,
  });

  final OverlayCommandType type;
  final String? cardId;
  final String? name; // action name
  final Map<String, Object?> context;
  final String? path; // setData path
  final Object? value; // setData value
}

Map<String, Object?> actionCommand(
  String cardId,
  String name,
  Map<String, Object?> context,
) =>
    {'type': 'action', 'cardId': cardId, 'name': name, 'context': context};

Map<String, Object?> dismissCommand(String cardId) =>
    {'type': 'dismiss', 'cardId': cardId};

Map<String, Object?> setDataCommand(String cardId, String path, Object? value) =>
    {'type': 'setData', 'cardId': cardId, 'path': path, 'value': value};

Map<String, Object?> openInboxCommand() => {'type': 'openInbox'};

/// Parse a command on the main side; null if [msg] isn't a recognised command.
OverlayCommand? parseCommand(dynamic msg) {
  if (msg is! Map) return null;
  switch (msg['type']) {
    case 'action':
      return OverlayCommand(
        type: OverlayCommandType.action,
        cardId: msg['cardId'] as String?,
        name: msg['name'] as String?,
        context: (msg['context'] as Map?)?.cast<String, Object?>() ?? const {},
      );
    case 'dismiss':
      return OverlayCommand(
        type: OverlayCommandType.dismiss,
        cardId: msg['cardId'] as String?,
      );
    case 'setData':
      return OverlayCommand(
        type: OverlayCommandType.setData,
        cardId: msg['cardId'] as String?,
        path: msg['path'] as String?,
        value: msg['value'],
      );
    case 'openInbox':
      return const OverlayCommand(type: OverlayCommandType.openInbox);
    default:
      return null;
  }
}
