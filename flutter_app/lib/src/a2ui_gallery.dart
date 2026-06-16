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

import 'a2ui_functions.dart' show allAnsweredFn, anyAnsweredFn, setDataFn;
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
    '/envOther': '',
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
    // Q1 — single select via AmaChoice: each option has a description + preview,
    // plus a mutually-exclusive Other. Next is gated on (an option OR Other).
    {
      'id': 'q1',
      'component': 'Column',
      'children': ['q1text', 'q1body', 'q1pick', 'q1nav'],
    },
    {
      'id': 'q1text',
      'component': 'Text',
      'text': 'Which environment do you want to deploy?',
      'variant': 'h4',
    },
    {
      'id': 'q1body',
      'component': 'Text',
      'text': 'Pick the target environment. This decides which secrets and '
          'database the release talks to — production is irreversible.',
    },
    {
      'id': 'q1pick',
      'component': 'AmaChoice',
      'label': 'Target',
      'value': {'path': '/env'},
      'other': {'path': '/envOther'},
      'options': const [
        {
          'label': 'Production',
          'value': 'prod',
          'description': 'Live customer traffic',
          'preview':
              'Deploys to prod.muvee.ai — real users, real data. No undo.',
        },
        {
          'label': 'Staging',
          'value': 'staging',
          'description': 'Pre-prod mirror',
          'preview': 'Deploys to staging — safe to break, resets nightly.',
        },
        {
          'label': 'Local dev',
          'value': 'local',
          'description': 'Your machine only',
        },
      ],
    },
    // Q2 — multi select via AmaChoice with per-option descriptions.
    {
      'id': 'q2',
      'component': 'Column',
      'children': ['q2text', 'q2body', 'q2pick', 'q2nav'],
    },
    {
      'id': 'q2text',
      'component': 'Text',
      'text': 'Which features should I enable?',
      'variant': 'h4',
    },
    {
      'id': 'q2body',
      'component': 'Text',
      'text': 'Choose any number — each adds a module to the build.',
    },
    {
      'id': 'q2pick',
      'component': 'AmaChoice',
      'label': 'Features',
      'multiple': true,
      'value': {'path': '/features'},
      'options': const [
        {'label': 'Auth', 'value': 'auth', 'description': 'Login + sessions'},
        {
          'label': 'Billing',
          'value': 'billing',
          'description': 'Stripe checkout',
        },
        {
          'label': 'Analytics',
          'value': 'analytics',
          'description': 'Usage tracking',
        },
      ],
    },
    // Q3 — free text, with a descriptive body.
    {
      'id': 'q3',
      'component': 'Column',
      'children': ['q3text', 'q3body', 'q3field', 'q3nav'],
    },
    {
      'id': 'q3text',
      'component': 'Text',
      'text': 'Anything else I should know?',
      'variant': 'h4',
    },
    {
      'id': 'q3body',
      'component': 'Text',
      'text': 'Free-form notes that travel with the request.',
    },
    {
      'id': 'q3field',
      'component': 'TextField',
      'label': 'Notes',
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
    // Q1 is answered by either an option OR the Other text.
    ..._stepButton(
      id: 'q1next',
      toStep: 1,
      label: 'Next →',
      gateCondition: _anyAnswered(const ['/env', '/envOther']),
    ),
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
      gateCondition: _anyAnswered(const ['/features']),
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
      // Every question answered: Q1 (option OR Other), Q2, and Q3.
      'checks': [
        {
          'message': 'Answer every question first',
          'condition': {
            'call': allAnsweredFn,
            'args': {
              'q1': _anyAnswered(const ['/env', '/envOther']),
              'q2': {'path': '/features'},
              'q3': {'path': '/note'},
            },
          },
        },
      ],
    },
    {'id': 'q3confirmText', 'component': 'Text', 'text': 'Confirm'},
  ],
);

/// An `anyAnswered` condition over [paths] — true when any one has a value.
Map<String, Object?> _anyAnswered(List<String> paths) => {
  'call': anyAnsweredFn,
  'args': {
    for (var i = 0; i < paths.length; i++) 'v$i': {'path': paths[i]},
  },
};

/// Build a wizard navigation button + its label text. Sets the Tabs step
/// (`/step`) to [toStep] via the `setData` client function on tap. Gate it by
/// passing either [gateOn] (a single path, wrapped in `allAnswered`) or a full
/// [gateCondition] expression; [primary] picks the filled vs borderless style.
List<Map<String, Object?>> _stepButton({
  required String id,
  required int toStep,
  required String label,
  String? gateOn,
  Map<String, Object?>? gateCondition,
  bool primary = true,
}) {
  final String textId = '${id}Text';
  final Map<String, Object?>? condition = gateCondition ??
      (gateOn == null
          ? null
          : {
              'call': allAnsweredFn,
              'args': {
                'v': {'path': gateOn},
              },
            });
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
      if (condition != null)
        'checks': [
          {'message': 'Answer this question first', 'condition': condition},
        ],
    },
    {'id': textId, 'component': 'Text', 'text': label},
  ];
}

/// Guard card — intercept a risky command (Fleet's guard decision). Shows the
/// command + its risk tags and an optional block reason; Allow / Block fire
/// `allow` / `block` events through the normal action → CRDT path.
String _guard(String surfaceId) => _card(
  surfaceId: surfaceId,
  seeds: const {'/reason': ''},
  components: [
    {
      'id': 'root',
      'component': 'Column',
      'children': ['heading', 'cmd', 'risks', 'reason', 'actions'],
    },
    {
      'id': 'heading',
      'component': 'Text',
      'text': 'Allow this command to run?',
      'variant': 'h3',
    },
    {'id': 'cmd', 'component': 'Text', 'text': r'$ rm -rf ./build'},
    {
      'id': 'risks',
      'component': 'Text',
      'text': '⚠ Risk: deletion · recursive · non-reversible',
    },
    {
      'id': 'reason',
      'component': 'TextField',
      'label': 'Reason (if blocking)',
      'value': {'path': '/reason'},
    },
    {
      'id': 'actions',
      'component': 'Row',
      'children': ['allowBtn', 'blockBtn'],
    },
    {
      'id': 'allowBtn',
      'component': 'Button',
      'variant': 'primary',
      'child': 'allowText',
      'action': {
        'event': {'name': 'allow'},
      },
    },
    {'id': 'allowText', 'component': 'Text', 'text': 'Allow'},
    {
      'id': 'blockBtn',
      'component': 'Button',
      'variant': 'borderless',
      'child': 'blockText',
      'action': {
        'event': {'name': 'block'},
      },
    },
    {'id': 'blockText', 'component': 'Text', 'text': 'Block'},
  ],
);

/// Plan approval card — review an agent's plan (Fleet's plan-approval
/// decision). Shows the plan body and an optional feedback note; Approve /
/// Reject fire `approve` / `reject` events.
String _planApproval(String surfaceId) => _card(
  surfaceId: surfaceId,
  seeds: const {'/feedback': ''},
  components: [
    {
      'id': 'root',
      'component': 'Column',
      'children': ['heading', 'plan', 'feedback', 'actions'],
    },
    {
      'id': 'heading',
      'component': 'Text',
      'text': 'Approve this plan?',
      'variant': 'h3',
    },
    {
      'id': 'plan',
      'component': 'Text',
      'text': '1. Add the auth middleware\n'
          '2. Migrate the session store\n'
          '3. Update the integration tests\n'
          '4. Roll out behind a flag',
    },
    {
      'id': 'feedback',
      'component': 'TextField',
      'label': 'Feedback (if rejecting)',
      'value': {'path': '/feedback'},
    },
    {
      'id': 'actions',
      'component': 'Row',
      'children': ['approveBtn', 'rejectBtn'],
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
      'id': 'rejectBtn',
      'component': 'Button',
      'variant': 'borderless',
      'child': 'rejectText',
      'action': {
        'event': {'name': 'reject'},
      },
    },
    {'id': 'rejectText', 'component': 'Text', 'text': 'Reject'},
  ],
);

/// The full gallery the debug FAB cycles through, in display order. The first
/// entry is the multi-question wizard; the last reuses the original sample
/// (heading + note field + Approve/Dismiss).
List<GalleryCard> galleryCards = [
  GalleryCard(title: 'Multi-question', build: _multiQuestion),
  GalleryCard(title: 'Single choice', build: _singleChoice),
  GalleryCard(title: 'Multiple choice', build: _multiChoice),
  GalleryCard(title: 'Multiple choice (chips)', build: _multiChips),
  GalleryCard(title: 'Form', build: _form),
  GalleryCard(title: 'Guard', build: _guard),
  GalleryCard(title: 'Plan approval', build: _planApproval),
  GalleryCard(
    title: 'Note',
    build: (surfaceId) => sampleA2uiJson(surfaceId: surfaceId, title: 'Note'),
  ),
];
