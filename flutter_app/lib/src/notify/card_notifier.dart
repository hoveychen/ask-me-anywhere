// Native (macOS) notifications for arriving cards. A doc `watch()` event of kind
// "message" means a card was inserted (locally pushed or synced from a peer);
// we raise a system notification titled with the card's summary.
//
// [newCardFor] is the pure, testable decision (which event → which card);
// [LocalCardNotifier] is the thin flutter_local_notifications wrapper the host
// drives. The host also dedupes by card id so a card notifies at most once.
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:flutter_app/src/rust/api/inbox.dart';

/// The card a doc event refers to *if* it's a new-message event for a card we
/// already have locally; otherwise null (non-message events, or a card not yet
/// in the list).
CardView? newCardFor(String kind, String? msgId, List<CardView> cards) {
  if (kind != 'message' || msgId == null) return null;
  for (final CardView card in cards) {
    if (card.id == msgId) return card;
  }
  return null;
}

/// Raises native macOS notifications via flutter_local_notifications.
class LocalCardNotifier {
  LocalCardNotifier([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  int _nextId = 0;

  /// Initialize the plugin and request macOS notification authorization. Safe to
  /// call once at startup.
  Future<void> init() async {
    const settings = InitializationSettings(
      macOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: false,
        requestSoundPermission: true,
      ),
    );
    await _plugin.initialize(settings: settings);
    await _plugin
        .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: false, sound: true);
  }

  /// Show a notification for a card: its summary as the title.
  Future<void> notifyCard(CardView card) async {
    await _plugin.show(
      id: _nextId++,
      title: card.summary,
      body: 'New card from ${card.source}',
      notificationDetails:
          const NotificationDetails(macOS: DarwinNotificationDetails()),
    );
  }
}
