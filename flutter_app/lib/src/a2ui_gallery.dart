// A small gallery of *real* A2UI v0.9 message trees used by the debug push FAB
// ("Push test card"). Each entry exercises a different genui catalog component
// so tapping the FAB cycles through the app's rendering capabilities — the
// fastest way to eyeball single-select / multi-select / form / slider / date
// cards without an agent on the other end of the inbox.
//
// Every bound field (`value: {path: ...}`) needs a matching `updateDataModel`
// seed so CardDetailView's two-way CRDT binding picks it up (see
// [CardDetailView.dataPaths]). [_card] assembles the three-message envelope
// (createSurface → seeds → updateComponents) for each entry.
import 'dart:convert';

import 'package:genui/genui.dart' show basicCatalogId;

import 'a2ui_sample.dart' show sampleA2uiJson;

/// A named demo card for the "Push test card" gallery. [title] is the inbox
/// summary; [build] returns the card's A2UI payload for the given surface.
class GalleryCard {
  const GalleryCard({required this.title, required this.build});

  final String title;
  final String Function(String surfaceId) build;
}

/// Wrap a `confirm` / `dismiss` action row mirroring the sample card's buttons
/// (primary + borderless), so the gallery feels like a real decision card.
List<Map<String, Object?>> _actionRow() => [
  {
    'id': 'actions',
    'component': 'Row',
    'children': ['confirmBtn', 'dismissBtn'],
  },
  {
    'id': 'confirmBtn',
    'component': 'Button',
    'variant': 'primary',
    'child': 'confirmText',
    'action': {
      'event': {'name': 'confirm'},
    },
  },
  {'id': 'confirmText', 'component': 'Text', 'text': 'Confirm'},
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
];

/// Assemble the standard three-message envelope: create the surface, seed each
/// bound data path, then push the component tree.
String _card({
  required String surfaceId,
  Map<String, Object?> seeds = const {},
  required List<Map<String, Object?>> components,
}) {
  final messages = <Map<String, Object?>>[
    {
      'version': 'v0.9',
      'createSurface': {'surfaceId': surfaceId, 'catalogId': basicCatalogId},
    },
    for (final entry in seeds.entries)
      {
        'version': 'v0.9',
        'updateDataModel': {
          'surfaceId': surfaceId,
          'path': entry.key,
          'value': entry.value,
        },
      },
    {
      'version': 'v0.9',
      'updateComponents': {'surfaceId': surfaceId, 'components': components},
    },
  ];
  return jsonEncode(messages);
}

/// Single-select — ChoicePicker `mutuallyExclusive` renders RadioListTiles,
/// the closest analogue to Claude Code's AskUserQuestion single-select.
String _singleChoice(String surfaceId) => _card(
  surfaceId: surfaceId,
  seeds: const {'/choice': <String>[]},
  components: [
    {
      'id': 'root',
      'component': 'Column',
      'children': ['heading', 'picker', 'actions'],
    },
    {
      'id': 'heading',
      'component': 'Text',
      'text': 'Which environment do you want to deploy?',
      'variant': 'h3',
    },
    {
      'id': 'picker',
      'component': 'ChoicePicker',
      'variant': 'mutuallyExclusive',
      'label': 'Target',
      'value': {'path': '/choice'},
      'options': const [
        {'label': 'Production', 'value': 'prod'},
        {'label': 'Staging', 'value': 'staging'},
        {'label': 'Local dev', 'value': 'local'},
      ],
    },
    ..._actionRow(),
  ],
);

/// Multi-select — ChoicePicker `multipleSelection` renders CheckboxListTiles.
String _multiChoice(String surfaceId) => _card(
  surfaceId: surfaceId,
  seeds: const {'/features': <String>[]},
  components: [
    {
      'id': 'root',
      'component': 'Column',
      'children': ['heading', 'picker', 'actions'],
    },
    {
      'id': 'heading',
      'component': 'Text',
      'text': 'Which features should I enable?',
      'variant': 'h3',
    },
    {
      'id': 'picker',
      'component': 'ChoicePicker',
      'variant': 'multipleSelection',
      'label': 'Features',
      'value': {'path': '/features'},
      'options': const [
        {'label': 'Auth', 'value': 'auth'},
        {'label': 'Billing', 'value': 'billing'},
        {'label': 'Analytics', 'value': 'analytics'},
        {'label': 'Notifications', 'value': 'notifications'},
      ],
    },
    ..._actionRow(),
  ],
);

/// Multi-select rendered as chips — same data shape, denser layout.
String _multiChips(String surfaceId) => _card(
  surfaceId: surfaceId,
  seeds: const {'/tags': <String>[]},
  components: [
    {
      'id': 'root',
      'component': 'Column',
      'children': ['heading', 'picker', 'actions'],
    },
    {
      'id': 'heading',
      'component': 'Text',
      'text': 'Tag this conversation',
      'variant': 'h3',
    },
    {
      'id': 'picker',
      'component': 'ChoicePicker',
      'variant': 'multipleSelection',
      'displayStyle': 'chips',
      'label': 'Tags',
      'value': {'path': '/tags'},
      'options': const [
        {'label': 'bug', 'value': 'bug'},
        {'label': 'feature', 'value': 'feature'},
        {'label': 'urgent', 'value': 'urgent'},
        {'label': 'question', 'value': 'question'},
        {'label': 'wontfix', 'value': 'wontfix'},
      ],
    },
    ..._actionRow(),
  ],
);

/// Form — free-text + slider + date, the building blocks of fleet__ask's
/// formFields, all two-way bound to the CRDT document.
String _form(String surfaceId) => _card(
  surfaceId: surfaceId,
  seeds: const {'/title': '', '/priority': 5, '/due': ''},
  components: [
    {
      'id': 'root',
      'component': 'Column',
      'children': ['heading', 'title', 'priorityLabel', 'priority', 'due', 'actions'],
    },
    {
      'id': 'heading',
      'component': 'Text',
      'text': 'Create a task',
      'variant': 'h3',
    },
    {
      'id': 'title',
      'component': 'TextField',
      'label': 'Title',
      'value': {'path': '/title'},
    },
    {
      'id': 'priorityLabel',
      'component': 'Text',
      'text': 'Priority (0–10)',
      'variant': 'body',
    },
    {
      'id': 'priority',
      'component': 'Slider',
      'min': 0,
      'max': 10,
      'value': {'path': '/priority'},
    },
    {
      'id': 'due',
      'component': 'DateTimeInput',
      'value': {'path': '/due'},
      'enableTime': false,
    },
    ..._actionRow(),
  ],
);

/// The full gallery the debug FAB cycles through, in display order. The last
/// entry reuses the original sample (heading + note field + Approve/Dismiss).
List<GalleryCard> galleryCards = [
  GalleryCard(title: 'Single choice', build: _singleChoice),
  GalleryCard(title: 'Multiple choice', build: _multiChoice),
  GalleryCard(title: 'Multiple choice (chips)', build: _multiChips),
  GalleryCard(title: 'Form', build: _form),
  GalleryCard(
    title: 'Note',
    build: (surfaceId) => sampleA2uiJson(surfaceId: surfaceId, title: 'Note'),
  ),
];
