// macOS Dock-tile red-dot badge. The number of unread cards is pushed over the
// `ama/dock` MethodChannel to native (AppDelegate sets NSApp.dockTile.badgeLabel
// on the main thread). This is the Dock badge, distinct from the notification-
// centre badge that flutter_local_notifications owns.
import 'package:flutter/services.dart';

import 'package:flutter_app/src/state/badge_sink.dart';

class DockBadge implements BadgeSink {
  static const MethodChannel _channel = MethodChannel('ama/dock');

  @override
  void setBadge(int count) {
    // Fire-and-forget; a failed channel call must never break the inbox.
    _channel.invokeMethod<void>('setBadge', count).catchError((_) {});
  }
}
