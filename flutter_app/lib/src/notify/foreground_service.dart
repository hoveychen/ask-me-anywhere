// Controls the Android foreground service that keeps the process — and thus the
// iroh node syncing on its Rust threads — alive while the app is backgrounded.
// No-op on every other platform. See M4 P3.
import 'dart:io';

import 'package:flutter/services.dart';

class ForegroundService {
  static const MethodChannel _channel = MethodChannel('ama/foreground');

  /// Start the persistent background-sync service (Android only).
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('start');
  }

  /// Stop it.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stop');
  }
}
