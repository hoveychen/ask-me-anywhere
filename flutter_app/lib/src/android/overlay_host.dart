// Main-isolate side of the chat-head bubble. Owns the overlay's lifecycle and
// the bridge to the shared controller: it pushes `cards` snapshots into the
// overlay isolate and routes the user's bubble commands back to the CRDT.
// Constraint 1 lives here — the InboxHandle never leaves this isolate; the
// overlay only ever sees serialized snapshots.
import 'dart:async';
import 'dart:ui' show FlutterView, Size;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'package:flutter_app/src/android/overlay_bridge.dart';
import 'package:flutter_app/src/android/overlay_permission.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/state/assistant_controller.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

class OverlayHost {
  OverlayHost(this._controller);

  static const MethodChannel _appChannel = MethodChannel('ama/overlay');
  // Main-engine end of the overlay→main command relay (see MainActivity.kt and
  // overlay_bubble.dart). The overlay can't reach us via shareData, so its
  // commands are forwarded here through native.
  static const MethodChannel _cmdChannel = MethodChannel('ama/overlay_cmd');

  final AssistantController _controller;
  bool _shown = false;
  bool _pushing = false;

  /// Show the bubble (requesting overlay permission the first time). No-op if
  /// permission is denied or it's already up.
  Future<void> show() async {
    if (_shown) return;
    if (!await OverlayPermission.ensure()) return;
    // Start as the small draggable bubble; the overlay isolate resizes itself
    // to full-screen when a surface expands and back to bubble on collapse.
    //
    // showOverlay treats width/height as raw *physical px* (the plugin sets the
    // initial LayoutParams without dpToPx), whereas resizeOverlay later runs
    // dpToPx — so passing a bare 72 makes the first bubble ~72px (tiny on a
    // hi-dpi screen) until the first resize. Pre-multiply by the device pixel
    // ratio so the bubble is a full 72 *logical* px from the very first frame,
    // matching the resizeOverlay(72,72) the collapse path uses.
    final Iterable<FlutterView> views =
        WidgetsBinding.instance.platformDispatcher.views;
    final double dpr =
        views.isNotEmpty ? views.first.devicePixelRatio : 1.0;
    final int bubblePx = (72 * dpr).round();
    await FlutterOverlayWindow.showOverlay(
      height: bubblePx,
      width: bubblePx,
      alignment: OverlayAlignment.centerRight,
      flag: OverlayFlag.defaultFlag,
      enableDrag: true,
      // NOT PositionGravity.auto: auto re-snaps the window's x to the nearest
      // edge on touch-up, which races and overrides the _moveTo(0,0) the overlay
      // runs when expanding. Parked on the LEFT, that left over a left x-offset,
      // so the expanded full-screen surface (and its right-aligned drawer) was
      // shifted left (bug #2). With `none`, position is driven solely by our
      // explicit moveOverlay resets, so expand/collapse anchor deterministically.
      positionGravity: PositionGravity.none,
      overlayTitle: 'ask-me-anywhere',
      overlayContent: 'Assistant',
    );
    _shown = true;
    _cmdChannel.setMethodCallHandler(_onCmdCall);
    await _attachRelay();
    _controller.addListener(_pushSnapshot);
    await _pushSnapshotAsync();
  }

  /// Ask the activity to wire the overlay→main relay onto the overlay engine.
  /// The overlay engine is created by showOverlay() above, but caching can lag,
  /// so retry a few times before giving up.
  Future<void> _attachRelay() async {
    for (int i = 0; i < 10; i++) {
      final bool ok =
          await _appChannel.invokeMethod<bool>('attachOverlayRelay') ?? false;
      if (ok) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _onCmdCall(MethodCall call) async {
    if (call.method == 'cmd') await _onCommand(call.arguments);
  }

  /// Hide the bubble (e.g. when the app returns to the foreground).
  Future<void> hide() async {
    if (!_shown) return;
    _controller.removeListener(_pushSnapshot);
    await FlutterOverlayWindow.closeOverlay();
    _shown = false;
  }

  Future<void> dispose() async {
    _controller.removeListener(_pushSnapshot);
    _cmdChannel.setMethodCallHandler(null);
  }

  // ChangeNotifier callback is sync; kick the async push without awaiting.
  void _pushSnapshot() {
    unawaited(_pushSnapshotAsync());
  }

  Future<void> _pushSnapshotAsync() async {
    if (_pushing) return; // coalesce bursts
    _pushing = true;
    try {
      // Push ALL cards (so the drawer can show the inbox), but only resolve the
      // bound-value snapshot for the unread ones the overlay can actually open.
      final List<Map<String, Object?>> cards = [];
      for (final CardView c in _controller.cards) {
        Map<String, Object?> values = const {};
        if (c.status == CardStatus.unread) {
          final List<String> paths = dataPaths(parseA2uiMessages(c.a2UiJson));
          values = await _controller.cardData(c.id, paths);
        }
        cards.add(cardToJson(c, dataValues: values));
      }
      // The overlay can't measure the full screen from its bubble-sized view,
      // so the main isolate (whose view spans the whole screen) measures it and
      // ships logical-pixel dims for the full-screen resize on expand.
      final Size screen = _screenLogicalSize();
      await FlutterOverlayWindow.shareData(
        snapshotToJson(
          _controller.unreadCount,
          cards,
          screenWidth: screen.width,
          screenHeight: screen.height,
        ),
      );
    } catch (_) {
      // A failed push must never take down the inbox.
    } finally {
      _pushing = false;
    }
  }

  Future<void> _onCommand(dynamic message) async {
    final OverlayCommand? cmd = parseCommand(message);
    if (cmd == null) return;
    switch (cmd.type) {
      case OverlayCommandType.action:
        if (cmd.cardId != null && cmd.name != null) {
          await _controller.recordAction(cmd.cardId!, cmd.name!, cmd.context);
        }
        break;
      case OverlayCommandType.dismiss:
        if (cmd.cardId != null) await _controller.dismiss(cmd.cardId!);
        break;
      case OverlayCommandType.setData:
        if (cmd.cardId != null && cmd.path != null) {
          await _controller.setData(cmd.cardId!, cmd.path!, cmd.value);
        }
        break;
      case OverlayCommandType.openInbox:
        await _bringAppToFront();
        break;
    }
  }

  /// The device screen size in logical pixels (dp), from the main activity's
  /// view. devicePixelRatio converts the physical frame back to dp.
  Size _screenLogicalSize() {
    final FlutterView? view =
        WidgetsBinding.instance.platformDispatcher.views.isNotEmpty
            ? WidgetsBinding.instance.platformDispatcher.views.first
            : null;
    if (view == null) return Size.zero;
    final double dpr = view.devicePixelRatio == 0 ? 1 : view.devicePixelRatio;
    return view.physicalSize / dpr;
  }

  Future<void> _bringAppToFront() async {
    try {
      await _appChannel.invokeMethod<void>('bringToFront');
    } catch (_) {}
  }
}
