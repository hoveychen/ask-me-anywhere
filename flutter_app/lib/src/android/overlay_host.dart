// Main-isolate side of the chat-head bubble. Owns the overlay's lifecycle and
// the bridge to the shared controller: it pushes `cards` snapshots into the
// overlay isolate and routes the user's bubble commands back to the CRDT.
// Constraint 1 lives here — the InboxHandle never leaves this isolate; the
// overlay only ever sees serialized snapshots.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'package:flutter_app/src/android/overlay_bridge.dart';
import 'package:flutter_app/src/android/overlay_permission.dart';
import 'package:flutter_app/src/rust/api/inbox.dart';
import 'package:flutter_app/src/state/assistant_controller.dart';
import 'package:flutter_app/src/ui/card_detail_view.dart';

class OverlayHost {
  OverlayHost(this._controller);

  static const MethodChannel _appChannel = MethodChannel('ama/overlay');

  final AssistantController _controller;
  StreamSubscription<dynamic>? _cmdSub;
  bool _shown = false;
  bool _pushing = false;

  /// Show the bubble (requesting overlay permission the first time). No-op if
  /// permission is denied or it's already up.
  Future<void> show() async {
    if (_shown) return;
    if (!await OverlayPermission.ensure()) return;
    await FlutterOverlayWindow.showOverlay(
      height: 200,
      width: 200,
      alignment: OverlayAlignment.centerRight,
      flag: OverlayFlag.defaultFlag,
      enableDrag: true,
      positionGravity: PositionGravity.auto,
      overlayTitle: 'ask-me-anywhere',
      overlayContent: 'Assistant',
    );
    _shown = true;
    _cmdSub ??= FlutterOverlayWindow.overlayListener.listen(_onCommand);
    _controller.addListener(_pushSnapshot);
    await _pushSnapshotAsync();
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
    await _cmdSub?.cancel();
    _cmdSub = null;
  }

  // ChangeNotifier callback is sync; kick the async push without awaiting.
  void _pushSnapshot() {
    unawaited(_pushSnapshotAsync());
  }

  Future<void> _pushSnapshotAsync() async {
    if (_pushing) return; // coalesce bursts
    _pushing = true;
    try {
      final List<CardView> pending = _controller.cards
          .where((c) => c.status == CardStatus.unread)
          .toList();
      final List<Map<String, Object?>> cards = [];
      for (final CardView c in pending) {
        final List<String> paths = dataPaths(parseA2uiMessages(c.a2UiJson));
        final Map<String, Object?> values = await _controller.cardData(c.id, paths);
        cards.add(cardToJson(c, dataValues: values));
      }
      await FlutterOverlayWindow.shareData(
        snapshotToJson(_controller.unreadCount, cards),
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

  Future<void> _bringAppToFront() async {
    try {
      await _appChannel.invokeMethod<void>('bringToFront');
    } catch (_) {}
  }
}
