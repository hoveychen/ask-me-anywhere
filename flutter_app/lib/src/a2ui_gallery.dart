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

import 'a2ui_functions.dart' show allAnsweredFn, setDataFn;
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
///
/// When [requireAnswered] lists data paths, the Confirm button gains a `checks`
/// condition (`allAnswered` over those paths) so it stays disabled until every
/// one is answered — the A2UI-native "Submit disabled until answered" gate.
List<Map<String, Object?>> _actionRow({List<String> requireAnswered = const []}) => [
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
    if (requireAnswered.isNotEmpty)
      'checks': [
        {
          'message': 'Answer every question first',
          'condition': {
            'call': allAnsweredFn,
            'args': {
              for (var i = 0; i < requireAnswered.length; i++)
                'v$i': {'path': requireAnswered[i]},
            },
          },
        },
      ],
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
    ..._actionRow(requireAnswered: const ['/choice']),
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
    ..._actionRow(requireAnswered: const ['/features']),
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
    ..._actionRow(requireAnswered: const ['/tags']),
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
    ..._actionRow(requireAnswered: const ['/title']),
  ],
);

/// Multi-question wizard — a Tabs layout where each tab is one question
/// (single-select / multi-select / free-text), the A2UI-native analogue of
/// Claude Code's AskUserQuestion. The tab headers (1·2·3) are the navigator;
/// `activeTab` binds to `/step` so the position rides the CRDT document. One
/// Confirm/Dismiss row at the bottom submits all answers at once. Staying in
/// pure A2UI keeps this pushable by any remote agent — AMA renders, it doesn't
/// hand-build bespoke widgets.
String _multiQuestion(String surfaceId) => _card(
  surfaceId: surfaceId,
  seeds: const {
    '/step': 0,
    '/env': <String>[],
    '/features': <String>[],
    '/note': '',
  },
  components: [
    {
      'id': 'root',
      'component': 'Column',
      'children': ['tabs'],
    },
    {
      'id': 'tabs',
      'component': 'Tabs',
      'activeTab': {'path': '/step'},
      'tabs': const [
        {'label': '1 · Env', 'content': 'q1'},
        {'label': '2 · Features', 'content': 'q2'},
        {'label': '3 · Note', 'content': 'q3'},
      ],
    },
    // Q1 — single select. Its Next button advances to tab 2, but only once an
    // environment is picked (gated via allAnswered on /env).
    {
      'id': 'q1',
      'component': 'Column',
      'children': ['q1text', 'q1pick', 'q1nav'],
    },
    {
      'id': 'q1text',
      'component': 'Text',
      'text': 'Which environment do you want to deploy?',
      'variant': 'h4',
    },
    {
      'id': 'q1pick',
      'component': 'ChoicePicker',
      'variant': 'mutuallyExclusive',
      'label': 'Target',
      'value': {'path': '/env'},
      'options': const [
        {'label': 'Production', 'value': 'prod'},
        {'label': 'Staging', 'value': 'staging'},
        {'label': 'Local dev', 'value': 'local'},
      ],
    },
    // Q2 — multi select.
    {
      'id': 'q2',
      'component': 'Column',
      'children': ['q2text', 'q2pick', 'q2nav'],
    },
    {
      'id': 'q2text',
      'component': 'Text',
      'text': 'Which features should I enable?',
      'variant': 'h4',
    },
    {
      'id': 'q2pick',
      'component': 'ChoicePicker',
      'variant': 'multipleSelection',
      'label': 'Features',
      'value': {'path': '/features'},
      'options': const [
        {'label': 'Auth', 'value': 'auth'},
        {'label': 'Billing', 'value': 'billing'},
        {'label': 'Analytics', 'value': 'analytics'},
      ],
    },
    // Q3 — free text ("Other").
    {
      'id': 'q3',
      'component': 'Column',
      'children': ['q3text', 'q3field', 'q3nav'],
    },
    {
      'id': 'q3text',
      'component': 'Text',
      'text': 'Anything else I should know?',
      'variant': 'h4',
    },
    {
      'id': 'q3field',
      'component': 'TextField',
      'label': 'Other',
      'value': {'path': '/note'},
    },
    // Per-tab navigation: Next advances the Tabs `activeTab` (/step) a step on,
    // gated on the current question; the last tab swaps Next for Confirm, gated
    // on every question. Back steps the tab index down. All pure A2UI.
    {
      'id': 'q1nav',
      'component': 'Row',
      'children': ['q1next'],
    },
    ..._stepButton(id: 'q1next', toStep: 1, label: 'Next →', gateOn: '/env'),
    {
      'id': 'q2nav',
      'component': 'Row',
      'children': ['q2back', 'q2next'],
    },
    ..._stepButton(id: 'q2back', toStep: 0, label: '← Back', primary: false),
    ..._stepButton(
      id: 'q2next',
      toStep: 2,
      label: 'Next →',
      gateOn: '/features',
    ),
    {
      'id': 'q3nav',
      'component': 'Row',
      'children': ['q3back', 'q3confirm'],
    },
    ..._stepButton(id: 'q3back', toStep: 1, label: '← Back', primary: false),
    {
      'id': 'q3confirm',
      'component': 'Button',
      'variant': 'primary',
      'child': 'q3confirmText',
      'action': {
        'event': {'name': 'confirm'},
      },
      'checks': [
        {
          'message': 'Answer every question first',
          'condition': {
            'call': allAnsweredFn,
            'args': {
              'a': {'path': '/env'},
              'b': {'path': '/features'},
              'c': {'path': '/note'},
            },
          },
        },
      ],
    },
    {'id': 'q3confirmText', 'component': 'Text', 'text': 'Confirm'},
  ],
);

/// Build a wizard navigation button + its label text. Sets the Tabs step
/// (`/step`) to [toStep] via the `setData` client function on tap; when [gateOn]
/// is given, an `allAnswered` check keeps it disabled until that path has a
/// value. [primary] picks the filled vs borderless style.
List<Map<String, Object?>> _stepButton({
  required String id,
  required int toStep,
  required String label,
  String? gateOn,
  bool primary = true,
}) {
  final String textId = '${id}Text';
  return [
    {
      'id': id,
      'component': 'Button',
      'variant': primary ? 'primary' : 'borderless',
      'child': textId,
      'action': {
        'functionCall': {
          'call': setDataFn,
          'args': {'path': '/step', 'value': toStep},
        },
      },
      if (gateOn != null)
        'checks': [
          {
            'message': 'Answer this question first',
            'condition': {
              'call': allAnsweredFn,
              'args': {
                'v': {'path': gateOn},
              },
            },
          },
        ],
    },
    {'id': textId, 'component': 'Text', 'text': label},
  ];
}

/// The full gallery the debug FAB cycles through, in display order. The first
/// entry is the multi-question wizard; the last reuses the original sample
/// (heading + note field + Approve/Dismiss).
List<GalleryCard> galleryCards = [
  GalleryCard(title: 'Multi-question', build: _multiQuestion),
  GalleryCard(title: 'Single choice', build: _singleChoice),
  GalleryCard(title: 'Multiple choice', build: _multiChoice),
  GalleryCard(title: 'Multiple choice (chips)', build: _multiChips),
  GalleryCard(title: 'Form', build: _form),
  GalleryCard(
    title: 'Note',
    build: (surfaceId) => sampleA2uiJson(surfaceId: surfaceId, title: 'Note'),
  ),
];
