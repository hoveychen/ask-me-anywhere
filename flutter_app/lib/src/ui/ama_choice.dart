// A custom genui catalog component that brings the multi-question card up to
// Claude Code's AskUserQuestion fidelity, which the basic `ChoicePicker` can't:
//
//   - per-option *description* (a second line under each label),
//   - an optional free-text "Other", mutually exclusive with the options,
//   - an optional per-option *preview* shown beneath the list.
//
// It's still pure A2UI — an agent references it by component name ("AmaChoice")
// in the pushed tree; we've only grown the catalog (see [cardCatalog]). The
// selected value(s) bind to a data path exactly like ChoicePicker, so the
// `allAnswered` gate and CRDT sync keep working unchanged.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

/// Component name referenced from A2UI trees.
const String amaChoiceName = 'AmaChoice';

final _schema = S.object(
  description:
      'A single- or multi-select question where each option carries a label '
      'and an optional description, with an optional free-text "Other" '
      '(mutually exclusive with the options) and optional per-option preview.',
  properties: {
    'label': S.string(description: 'Heading shown above the options.'),
    'multiple': S.boolean(
      description: 'Allow selecting more than one option (checkboxes).',
    ),
    'value': A2uiSchemas.dataBindingSchema(
      description: 'Bound path holding the selected value(s).',
    ),
    'other': A2uiSchemas.dataBindingSchema(
      description: 'Optional bound path for the free-text "Other" answer.',
    ),
    'options': S.list(
      description: 'The options to choose from.',
      items: S.object(
        properties: {
          'label': S.string(),
          'value': S.string(),
          'description': S.string(),
          'preview': S.string(),
        },
        required: ['label', 'value'],
      ),
    ),
  },
  required: ['options', 'value'],
);

String? _bindPath(Object? ref) =>
    (ref is Map && ref['path'] is String) ? ref['path'] as String : null;

List<String> _asStringList(Object? v) {
  if (v == null) return const [];
  if (v is String) return v.isEmpty ? const [] : [v];
  if (v is Iterable) return v.map((e) => e.toString()).toList();
  return [v.toString()];
}

/// A single- or multi-select question with per-option descriptions and an
/// optional mutually-exclusive "Other" field. (Preview lands in P3.)
final amaChoice = CatalogItem(
  name: amaChoiceName,
  dataSchema: _schema,
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) => _AmaChoice(itemContext: itemContext),
);

class _AmaChoice extends StatefulWidget {
  const _AmaChoice({required this.itemContext});

  final CatalogItemContext itemContext;

  @override
  State<_AmaChoice> createState() => _AmaChoiceState();
}

class _AmaChoiceState extends State<_AmaChoice> {
  late final JsonMap _data = widget.itemContext.data as JsonMap;
  late final DataContext _dc = widget.itemContext.dataContext;
  late final bool _multiple = _data['multiple'] == true;
  late final List<JsonMap> _options =
      ((_data['options'] as List?) ?? const []).cast<JsonMap>();
  late final String _valuePath =
      _bindPath(_data['value']) ?? '${widget.itemContext.id}.value';
  late final String? _otherPath = _bindPath(_data['other']);

  final TextEditingController _otherCtrl = TextEditingController();
  ValueListenable<Object?>? _otherListenable;

  @override
  void initState() {
    super.initState();
    final String? otherPath = _otherPath;
    if (otherPath != null) {
      final listenable = _dc.subscribe<Object?>(DataPath(otherPath));
      _otherListenable = listenable;
      _otherCtrl.text = (listenable.value ?? '').toString();
      listenable.addListener(_syncOtherFromModel);
    }
  }

  @override
  void dispose() {
    _otherListenable?.removeListener(_syncOtherFromModel);
    _otherCtrl.dispose();
    super.dispose();
  }

  // Mirror remote/model changes into the text field without fighting the caret.
  void _syncOtherFromModel() {
    final String v = (_otherListenable!.value ?? '').toString();
    if (v != _otherCtrl.text) _otherCtrl.text = v;
  }

  void _pickOption(String optionValue, bool pick, List<String> selected) {
    if (_multiple) {
      final next = List<String>.from(selected);
      if (pick) {
        if (!next.contains(optionValue)) next.add(optionValue);
      } else {
        next.remove(optionValue);
      }
      _dc.update(DataPath(_valuePath), next);
    } else {
      _dc.update(DataPath(_valuePath), [optionValue]);
    }
    // Mutual exclusion: choosing an option clears any free-text "Other".
    if (_otherPath != null && _otherCtrl.text.isNotEmpty) {
      _dc.update(DataPath(_otherPath), '');
    }
  }

  void _typeOther(String text) {
    _dc.update(DataPath(_otherPath!), text);
    // Mutual exclusion: typing "Other" clears the option selection.
    if (text.isNotEmpty) _dc.update(DataPath(_valuePath), <String>[]);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Object?>(
      valueListenable: _dc.subscribe<Object?>(DataPath(_valuePath)),
      builder: (context, current, _) {
        final List<String> selected = _asStringList(current);
        final String? label = _data['label'] as String?;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label != null && label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
                child: Text(label,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            for (final opt in _options)
              _OptionTile(
                option: opt,
                multiple: _multiple,
                selected: selected.contains(opt['value']),
                onChanged: (sel) =>
                    _pickOption(opt['value'] as String, sel, selected),
              ),
            if (_otherPath != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextField(
                  controller: _otherCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Other',
                    hintText: 'Type your own answer',
                  ),
                  onChanged: _typeOther,
                ),
              ),
            ?_previewFor(context, selected),
          ],
        );
      },
    );
  }

  /// The preview panel for the currently-selected option — shown only in
  /// single-select when exactly one option is chosen and it carries a preview,
  /// mirroring AskUserQuestion's side-by-side preview (stacked here to fit the
  /// card width). Returns null when there's nothing to preview.
  Widget? _previewFor(BuildContext context, List<String> selected) {
    if (_multiple || selected.length != 1) return null;
    final JsonMap opt = _options.firstWhere(
      (o) => o['value'] == selected.first,
      orElse: () => const {},
    );
    final Object? preview = opt['preview'];
    if (preview is! String || preview.isEmpty) return null;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Text(preview, style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.option,
    required this.multiple,
    required this.selected,
    required this.onChanged,
  });

  final JsonMap option;
  final bool multiple;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final String label = option['label'] as String? ?? '';
    final String? description = option['description'] as String?;
    final Widget? subtitle =
        (description != null && description.isNotEmpty) ? Text(description) : null;

    if (multiple) {
      return CheckboxListTile(
        controlAffinity: ListTileControlAffinity.leading,
        dense: true,
        title: Text(label),
        subtitle: subtitle,
        value: selected,
        onChanged: (v) => onChanged(v ?? false),
      );
    }
    return RadioListTile<bool>(
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      title: Text(label),
      subtitle: subtitle,
      value: true,
      // ignore: deprecated_member_use
      groupValue: selected ? true : null,
      // ignore: deprecated_member_use
      onChanged: (_) => onChanged(true),
    );
  }
}
