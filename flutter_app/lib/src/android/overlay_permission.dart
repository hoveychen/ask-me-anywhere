// SYSTEM_ALERT_WINDOW ("display over other apps") is a special permission — it
// can't be granted by a runtime dialog; the user has to flip it in a system
// settings page. requestPermission() opens that page and resolves once they
// return. We gate the chat-head bubble on it.
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

class OverlayPermission {
  /// True if the overlay permission is (now) granted, requesting it if needed.
  static Future<bool> ensure() async {
    if (await FlutterOverlayWindow.isPermissionGranted()) return true;
    final bool? granted = await FlutterOverlayWindow.requestPermission();
    return granted ?? false;
  }
}
