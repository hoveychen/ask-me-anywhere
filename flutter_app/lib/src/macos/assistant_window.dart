// macOS window geometry for the resident-assistant surfaces. ONE NSWindow
// (single FlutterEngine — a second engine would be a second isolate and
// couldn't share the in-memory inbox) is reshaped per [AssistantSurfaceKind]:
//
//   - icon   : tiny (72²), frameless, always-on-top, bottom-right corner.
//   - card   : large, centred (~82% of the screen) so a card to act on takes
//              the user's whole attention — this is the only attention-grab.
//   - list   : the full inbox as a right-edge drawer/sidecar (NOT centred — it
//              hasn't earned full focus yet), full height.
//   - picker : same right-edge drawer, to choose which pending card to open.
//
// The title bar is hidden ONCE (every surface is frameless) and never toggled
// again: flipping `titleBarStyle` mutates the macOS style mask and triggers an
// async relayout that clobbers `setSize` (it once squashed the 72² icon to
// 72×40). With the style fixed up front, each surface only resizes/repositions.
import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_app/src/state/assistant_surface.dart';

class AssistantWindowManager {
  static const Size iconSize = Size(72, 72);
  static const double drawerWidth = 400;
  static const Size _expandedMin = Size(320, 320);

  bool _frameless = false;

  /// Must run before `runApp` on macOS.
  static Future<void> ensureInitialized() => windowManager.ensureInitialized();

  /// Hide the title bar once and pin on top; every surface is frameless.
  Future<void> _ensureFrameless() async {
    if (_frameless) return;
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    _frameless = true;
  }

  /// Drive the window to match a surface state.
  Future<void> apply(AssistantSurfaceState state) async {
    await _ensureFrameless();
    switch (state.kind) {
      case AssistantSurfaceKind.icon:
        await _resize(iconSize, Alignment.bottomRight, resizable: false);
        await windowManager.show();
        break;
      case AssistantSurfaceKind.card:
        await _resize(await _cardSize(), Alignment.center, resizable: true);
        await _reveal();
        break;
      case AssistantSurfaceKind.picker:
        await _resize(await _drawerSize(), Alignment.topRight, resizable: true);
        await _reveal();
        break;
      case AssistantSurfaceKind.list:
        await _resize(await _drawerSize(), Alignment.topRight, resizable: true);
        await _reveal();
        break;
    }
  }

  Future<void> _resize(Size size, Alignment alignment,
      {required bool resizable}) async {
    // Unlock first so setSize takes; clamp min to the target for the fixed icon.
    await windowManager.setResizable(true);
    await windowManager.setMinimumSize(resizable ? _expandedMin : size);
    await windowManager.setSize(size);
    await windowManager.setAlignment(alignment);
    await windowManager.setResizable(resizable);
  }

  Future<void> _reveal() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// ~82% of the usable screen, so an open card dominates without being literally
  /// fullscreen. Falls back to a generous fixed size if the display query fails.
  Future<Size> _cardSize() async {
    try {
      final Display d = await screenRetriever.getPrimaryDisplay();
      final Size s = d.visibleSize ?? d.size;
      return Size(
        (s.width * 0.82).roundToDouble(),
        (s.height * 0.82).roundToDouble(),
      );
    } catch (_) {
      return const Size(1100, 800);
    }
  }

  /// A right-edge drawer: fixed width, full usable height. Docked via the
  /// topRight alignment by the caller. Falls back if the display query fails.
  Future<Size> _drawerSize() async {
    try {
      final Display d = await screenRetriever.getPrimaryDisplay();
      final Size s = d.visibleSize ?? d.size;
      return Size(drawerWidth, s.height.roundToDouble());
    } catch (_) {
      return const Size(drawerWidth, 800);
    }
  }
}
