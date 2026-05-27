// Bridges a rendered surface's GenUI [DataModel] to the CRDT data-model entries
// (`data/<id>/<bindPath>`) in both directions, for one card:
//
//   - **Local → remote:** a user edit to a bound field changes the data model;
//     [onLocalChange] fires so the host can `InboxHandle.setData(...)`.
//   - **Remote → local:** the host calls [applyRemote] with a value synced from
//     a peer; it's written into the data model so the bound widget rebuilds.
//
// The `_lastSynced` map is the echo guard: a remote apply records the value it
// wrote, so the resulting (synchronous) data-model notification is recognised as
// an echo and NOT re-emitted as a local change — otherwise two devices would
// ping-pong the same value forever.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart';

/// A single data-model value synced from a peer, addressed by JSON-pointer path.
@immutable
class CardDataUpdate {
  const CardDataUpdate({required this.path, required this.value});

  final String path;
  final Object? value;
}

class CardDataBridge {
  CardDataBridge({
    required DataModel dataModel,
    required Iterable<String> paths,
    required void Function(String path, Object? value) onLocalChange,
  })  : _dataModel = dataModel,
        _onLocalChange = onLocalChange {
    for (final String path in paths) {
      final ValueNotifier<Object?> notifier =
          dataModel.subscribe<Object?>(DataPath(path));
      _lastSynced[path] = jsonEncode(notifier.value);
      void listener() => _onLocalNotify(path, notifier.value);
      notifier.addListener(listener);
      _notifiers[path] = notifier;
      _listeners[path] = listener;
    }
  }

  final DataModel _dataModel;
  final void Function(String path, Object? value) _onLocalChange;
  final Map<String, ValueNotifier<Object?>> _notifiers = {};
  final Map<String, VoidCallback> _listeners = {};

  /// `path -> jsonEncode(lastValue we pushed or applied)`. Both directions write
  /// here before/while changing the model, so a notification matching it is a
  /// no-op echo rather than a fresh user edit.
  final Map<String, String> _lastSynced = {};

  void _onLocalNotify(String path, Object? value) {
    final String encoded = jsonEncode(value);
    if (_lastSynced[path] == encoded) return; // unchanged, or a remote echo
    _lastSynced[path] = encoded;
    _onLocalChange(path, value);
  }

  /// Apply a value synced from a peer without re-emitting it as a local change.
  void applyRemote(String path, Object? value) {
    _lastSynced[path] = jsonEncode(value);
    _dataModel.update(DataPath(path), value);
  }

  void dispose() {
    for (final MapEntry<String, VoidCallback> e in _listeners.entries) {
      _notifiers[e.key]?.removeListener(e.value);
    }
    for (final ValueNotifier<Object?> n in _notifiers.values) {
      n.dispose(); // ref-counted: decrements, only frees at zero
    }
    _notifiers.clear();
    _listeners.clear();
  }
}
