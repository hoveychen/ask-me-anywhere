// macOS window geometry for the two assistant modes, driven through
// `window_manager`. The app keeps ONE NSWindow (single FlutterEngine — a second
// engine would be a second isolate and couldn't share the in-memory inbox), and
// switches it between:
//
//   - **list**: a normal titled window, centred — the full inbox.
//   - **floating**: a small, frameless, always-on-top panel pinned to the
//     bottom-right corner — the resident assistant.
//
// Closing the window doesn't quit (see RootShell + setPreventClose); it drops to
// floating mode, so the assistant stays resident.
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

enum AssistantMode { list, floating }

class AssistantWindowManager {
  static const Size floatingSize = Size(360, 540);
  static const Size listSize = Size(900, 720);

  /// Must run before `runApp` on macOS.
  static Future<void> ensureInitialized() => windowManager.ensureInitialized();

  /// Shrink to the corner, drop the title bar, pin on top.
  Future<void> enterFloating() async {
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setMinimumSize(floatingSize);
    await windowManager.setSize(floatingSize);
    await windowManager.setAlignment(Alignment.bottomRight);
  }

  /// Restore a normal titled, centred window for the full inbox.
  Future<void> enterList() async {
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setTitleBarStyle(
      TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    await windowManager.setMinimumSize(const Size(480, 480));
    await windowManager.setSize(listSize);
    await windowManager.center();
  }

  /// Bring the floating panel to the foreground (on a new card).
  Future<void> showFloating() async {
    if (!await windowManager.isVisible()) {
      await windowManager.show();
    }
    await windowManager.focus();
  }
}
