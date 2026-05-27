// A small but *real* A2UI v0.9 message tree used by the debug push FAB and the
// widget tests. It exercises the pieces M3b cares about: a heading, a note
// field two-way bound to the data model (`/note`), and Approve / Dismiss
// buttons whose actions feed the CRDT state write.
//
// The card's stored `a2ui` payload is a JSON *array* of A2UI v0.9 messages —
// see [CardDetailView] for how it's fed into a `SurfaceController`.
import 'dart:convert';

import 'package:genui/genui.dart' show basicCatalogId;

/// JSON Pointer of the note field bound into the sample card's data model.
const String sampleNotePath = '/note';

/// Builds the sample card payload as a JSON string. `surfaceId` identifies the
/// surface inside the message tree; `title` is the heading text.
String sampleA2uiJson({required String surfaceId, required String title}) {
  final List<Map<String, Object?>> messages = [
    {
      'version': 'v0.9',
      'createSurface': {
        'surfaceId': surfaceId,
        'catalogId': basicCatalogId,
      },
    },
    {
      'version': 'v0.9',
      'updateDataModel': {
        'surfaceId': surfaceId,
        'path': sampleNotePath,
        'value': '',
      },
    },
    {
      'version': 'v0.9',
      'updateComponents': {
        'surfaceId': surfaceId,
        'components': [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['heading', 'note', 'actions'],
          },
          {
            'id': 'heading',
            'component': 'Text',
            'text': title,
            'variant': 'h3',
          },
          {
            'id': 'note',
            'component': 'TextField',
            'label': 'Note',
            'value': {'path': sampleNotePath},
          },
          {
            'id': 'actions',
            'component': 'Row',
            'children': ['approveBtn', 'dismissBtn'],
          },
          {
            'id': 'approveBtn',
            'component': 'Button',
            'variant': 'primary',
            'child': 'approveText',
            'action': {
              'event': {'name': 'approve'},
            },
          },
          {'id': 'approveText', 'component': 'Text', 'text': 'Approve'},
          {
            'id': 'dismissBtn',
            'component': 'Button',
            'variant': 'borderless',
            'child': 'dismissText',
            'action': {
              'event': {'name': 'dismiss'},
            },
          },
          {'id': 'dismissText', 'component': 'Text', 'text': 'Dismiss'},
        ],
      },
    },
  ];
  return jsonEncode(messages);
}
