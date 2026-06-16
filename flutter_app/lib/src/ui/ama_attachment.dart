// A custom genui catalog component for the "attach an image" decision-card
// pattern (Fleet's elicitation attachments). It picks an image, base64-encodes
// it into a `data:` URL, and writes that into a bound data path via the normal
// CRDT setData pipeline — so the bytes ride iroh-docs/blobs to every device with
// zero new transport (see the integrator doc §5.5/§5.6). Small images only:
// base64 in the CRDT is ~33% overhead and the in-memory blob store isn't durable
// across restarts; large/durable files want the blob-ticket path instead.
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

/// Component name referenced from A2UI trees.
const String amaAttachmentName = 'AmaAttachment';

/// Encode raw bytes as a `data:<mime>;base64,…` URL — the value stored in the
/// bound path. Pure, for unit testing.
String imageDataUrl(Uint8List bytes, String mime) =>
    'data:$mime;base64,${base64Encode(bytes)}';

/// Decode a `data:…;base64,…` URL back to bytes, or null if [value] isn't one.
Uint8List? decodeDataUrl(Object? value) {
  if (value is! String) return null;
  final int comma = value.indexOf(',');
  if (!value.startsWith('data:') || comma < 0) return null;
  try {
    return base64Decode(value.substring(comma + 1));
  } catch (_) {
    return null;
  }
}

final _schema = S.object(
  description:
      'A field that lets the user attach a single image, stored as a base64 '
      'data URL in the bound path. Small images only.',
  properties: {
    'label': S.string(description: 'Heading shown above the picker.'),
    'value': A2uiSchemas.dataBindingSchema(
      description: 'Bound path holding the base64 data URL of the image.',
    ),
  },
  required: ['value'],
);

String? _bindPath(Object? ref) =>
    (ref is Map && ref['path'] is String) ? ref['path'] as String : null;

/// A2UI component: pick an image → base64 data URL → bound data path. Renders a
/// thumbnail + Remove once one is attached.
final amaAttachment = CatalogItem(
  name: amaAttachmentName,
  dataSchema: _schema,
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) => _AmaAttachment(itemContext: itemContext),
);

class _AmaAttachment extends StatelessWidget {
  const _AmaAttachment({required this.itemContext});

  final CatalogItemContext itemContext;

  Future<void> _pick(String path) async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = result?.files.singleOrNull;
    final bytes = file?.bytes;
    if (bytes == null) return; // cancelled
    final String ext = (file?.extension ?? 'png').toLowerCase();
    final String mime = ext == 'jpg' ? 'image/jpeg' : 'image/$ext';
    itemContext.dataContext.update(DataPath(path), imageDataUrl(bytes, mime));
  }

  @override
  Widget build(BuildContext context) {
    final JsonMap data = itemContext.data as JsonMap;
    final String? path = _bindPath(data['value']);
    if (path == null) return const SizedBox.shrink();
    final String? label = data['label'] as String?;

    return ValueListenableBuilder<Object?>(
      valueListenable:
          itemContext.dataContext.subscribe<Object?>(DataPath(path)),
      builder: (context, current, _) {
        final Uint8List? bytes = decodeDataUrl(current);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label != null && label.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(label,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              if (bytes != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        bytes,
                        width: 96,
                        height: 96,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      onPressed: () =>
                          itemContext.dataContext.update(DataPath(path), ''),
                      icon: const Icon(Icons.close),
                      label: const Text('Remove'),
                    ),
                  ],
                )
              else
                OutlinedButton.icon(
                  onPressed: () => _pick(path),
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Add image'),
                ),
            ],
          ),
        );
      },
    );
  }
}
