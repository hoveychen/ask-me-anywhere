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
import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

/// Component name referenced from A2UI trees.
const String amaChoiceName = 'AmaChoice';

final _schema = S.object(
  description:
      'A single- or multi-select question where each option carries a label '
      'and an optional description, with an optional free-text "Other" and '
      'optional per-option preview.',
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

String _bindPath(Object? ref, String fallback) =>
    (ref is Map && ref['path'] is String) ? ref['path'] as String : fallback;

List<String> _asStringList(Object? v) {
  if (v == null) return const [];
  if (v is String) return v.isEmpty ? const [] : [v];
  if (v is Iterable) return v.map((e) => e.toString()).toList();
  return [v.toString()];
}

/// A single- or multi-select question with per-option descriptions. (Other +
/// preview land in later steps.)
final amaChoice = CatalogItem(
  name: amaChoiceName,
  dataSchema: _schema,
  isImplicitlyFlexible: true,
  widgetBuilder: (itemContext) {
    final JsonMap data = itemContext.data as JsonMap;
    final bool multiple = data['multiple'] == true;
    final List<JsonMap> options =
        ((data['options'] as List?) ?? const []).cast<JsonMap>();
    final String valuePath = _bindPath(data['value'], '${itemContext.id}.value');
    final DataContext dc = itemContext.dataContext;

    return ValueListenableBuilder<Object?>(
      valueListenable: dc.subscribe<Object?>(DataPath(valuePath)),
      builder: (context, current, _) {
        final List<String> selected = _asStringList(current);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (data['label'] is String &&
                (data['label'] as String).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 4, top: 4),
                child: Text(
                  data['label'] as String,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            for (final opt in options)
              _OptionTile(
                option: opt,
                multiple: multiple,
                selected: selected.contains(opt['value']),
                onChanged: (sel) => _updateSelection(
                  dc: dc,
                  valuePath: valuePath,
                  optionValue: opt['value'] as String,
                  multiple: multiple,
                  selected: selected,
                  pick: sel,
                ),
              ),
          ],
        );
      },
    );
  },
);

void _updateSelection({
  required DataContext dc,
  required String valuePath,
  required String optionValue,
  required bool multiple,
  required List<String> selected,
  required bool pick,
}) {
  if (!multiple) {
    dc.update(DataPath(valuePath), [optionValue]);
    return;
  }
  final next = List<String>.from(selected);
  if (pick) {
    if (!next.contains(optionValue)) next.add(optionValue);
  } else {
    next.remove(optionValue);
  }
  dc.update(DataPath(valuePath), next);
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
