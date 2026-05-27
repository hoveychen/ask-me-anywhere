// Renders a card's A2UI message tree into live Flutter widgets via the GenUI
// `SurfaceController`. The card's `a2uiJson` is a JSON array of A2UI v0.9
// messages (createSurface / updateComponents / updateDataModel); we feed each
// into a fresh controller and embed the resulting `Surface`.
//
// An empty (`{}` / `[]`), missing-surface, or malformed payload falls back to a
// plain summary so a card always renders *something* and never throws into the
// widget tree. (Action → CRDT and data-model sync land in P2/P3.)
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import 'package:flutter_app/src/rust/api/inbox.dart';

class CardDetailView extends StatefulWidget {
  const CardDetailView({super.key, required this.card});

  final CardView card;

  @override
  State<CardDetailView> createState() => _CardDetailViewState();
}

class _CardDetailViewState extends State<CardDetailView> {
  SurfaceController? _controller;
  String? _surfaceId;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _buildSurface();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Parse the payload and feed it into a fresh controller. Any failure leaves
  /// [_surfaceId] null, so [build] shows the fallback instead of throwing.
  void _buildSurface() {
    final List<Map<String, Object?>> messages =
        parseA2uiMessages(widget.card.a2UiJson);
    final String? surfaceId = firstSurfaceId(messages);
    if (surfaceId == null) return;

    final controller =
        SurfaceController(catalogs: [BasicCatalogItems.asCatalog()]);
    try {
      for (final message in messages) {
        controller.handleMessage(A2uiMessage.fromJson(message));
      }
    } catch (e) {
      controller.dispose();
      _error = e;
      return;
    }
    _controller = controller;
    _surfaceId = surfaceId;
  }

  @override
  Widget build(BuildContext context) {
    final SurfaceController? controller = _controller;
    final String? surfaceId = _surfaceId;
    if (controller == null || surfaceId == null) {
      return _Fallback(summary: widget.card.summary, error: _error);
    }
    return Surface(surfaceContext: controller.contextFor(surfaceId));
  }
}

/// Decode a card payload into the list of A2UI messages it carries. Accepts a
/// JSON array of messages or a single message object; anything else (empty
/// object, scalar, invalid JSON) yields an empty list.
List<Map<String, Object?>> parseA2uiMessages(String a2uiJson) {
  Object? decoded;
  try {
    decoded = jsonDecode(a2uiJson);
  } catch (_) {
    return const [];
  }
  if (decoded is List) {
    return decoded.whereType<Map<String, Object?>>().toList(growable: false);
  }
  if (decoded is Map<String, Object?> && decoded.isNotEmpty) {
    return [decoded];
  }
  return const [];
}

/// The `surfaceId` of the first `createSurface` message, or null if none — a
/// tree without a surface to create has nothing renderable.
String? firstSurfaceId(List<Map<String, Object?>> messages) {
  for (final message in messages) {
    final Object? create = message['createSurface'];
    if (create is Map && create['surfaceId'] is String) {
      return create['surfaceId'] as String;
    }
  }
  return null;
}

/// Shown when a card has no renderable A2UI tree: the plain-text summary plus a
/// note about why nothing rendered.
class _Fallback extends StatelessWidget {
  const _Fallback({required this.summary, this.error});

  final String summary;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(summary, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            error != null
                ? '(could not render A2UI: $error)'
                : '(no A2UI content)',
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}
