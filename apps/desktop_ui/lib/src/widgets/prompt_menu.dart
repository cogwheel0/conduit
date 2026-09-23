import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../l10n/strings.g.dart';
import 'form_field.dart';

/// The `/` menu over the composer (WP-3.3).
///
/// The field keeps focus throughout, as in the command palette: the arrows
/// move the highlight from inside the text, so the menu is a listbox the
/// caret never enters.
class PromptMenu extends StatelessComponent {
  const PromptMenu({
    required this.prompts,
    required this.highlighted,
    required this.onChoose,
    required this.onHighlight,
    super.key,
  });

  final List<PromptSummary> prompts;
  final int highlighted;
  final void Function(PromptSummary prompt) onChoose;
  final void Function(int index) onHighlight;

  @override
  Component build(BuildContext context) => div(
    id: 'prompt-menu',
    classes:
        'mx-auto mb-2 max-h-64 max-w-3xl overflow-y-auto rounded border '
        'border-border bg-popover p-1 text-popover-foreground shadow',
    attributes: <String, String>{
      'role': 'listbox',
      'aria-label': t.desktop.desktopPromptMenu,
    },
    [
      for (var i = 0; i < prompts.length; i++)
        div(
          key: ValueKey('prompt-${prompts[i].command}'),
          id: 'prompt-option-$i',
          classes:
              'flex cursor-pointer items-baseline gap-3 rounded px-3 py-1.5 '
              'text-sm ${i == highlighted ? 'bg-accent text-accent-foreground' : ''}',
          attributes: <String, String>{
            'role': 'option',
            'aria-selected': '${i == highlighted}',
          },
          events: <String, EventCallback>{
            'click': (_) => onChoose(prompts[i]),
            'mouseenter': (_) => onHighlight(i),
          },
          [
            span(classes: 'shrink-0 font-mono text-xs', [
              Component.text(prompts[i].command),
            ]),
            span(classes: 'min-w-0 truncate', [
              Component.text(prompts[i].title),
            ]),
            if (prompts[i].description case final description?
                when description.isNotEmpty)
              span(
                classes:
                    'ml-auto min-w-0 truncate text-xs text-muted-foreground',
                [Component.text(description)],
              ),
          ],
        ),
    ],
  );
}

/// A menu over the composer for `@` and `#` (WP-3.3): models, knowledge.
///
/// One shape for both, as the `/` menu has: the field keeps focus and the
/// arrows move the highlight from inside the text.
class SuggestionMenu extends StatelessComponent {
  const SuggestionMenu({
    required this.idPrefix,
    required this.label,
    required this.items,
    required this.highlighted,
    required this.onChoose,
    required this.onHighlight,
    super.key,
  });

  /// Rows are `$idPrefix-option-$i`, which the arrows scroll into view.
  final String idPrefix;
  final String label;
  final List<({String key, String title, String? detail})> items;
  final int highlighted;
  final void Function(int index) onChoose;
  final void Function(int index) onHighlight;

  @override
  Component build(BuildContext context) => div(
    id: '$idPrefix-menu',
    classes:
        'mx-auto mb-2 max-h-64 max-w-3xl overflow-y-auto rounded border '
        'border-border bg-popover p-1 text-popover-foreground shadow',
    attributes: <String, String>{'role': 'listbox', 'aria-label': label},
    [
      for (var i = 0; i < items.length; i++)
        div(
          key: ValueKey('$idPrefix-${items[i].key}'),
          id: '$idPrefix-option-$i',
          classes:
              'flex cursor-pointer items-baseline gap-3 rounded px-3 py-1.5 '
              'text-sm ${i == highlighted ? 'bg-accent text-accent-foreground' : ''}',
          attributes: <String, String>{
            'role': 'option',
            'aria-selected': '${i == highlighted}',
          },
          events: <String, EventCallback>{
            'click': (_) => onChoose(i),
            'mouseenter': (_) => onHighlight(i),
          },
          [
            span(classes: 'min-w-0 truncate', [Component.text(items[i].title)]),
            if (items[i].detail case final detail? when detail.isNotEmpty)
              span(
                classes:
                    'ml-auto min-w-0 truncate text-xs text-muted-foreground',
                [Component.text(detail)],
              ),
          ],
        ),
    ],
  );
}

/// Asks for a prompt's values before it goes into the composer.
///
/// Open WebUI shows a modal for this. Inline here, directly above the
/// field it will fill, so the user can still see what they had typed.
class PromptInputsForm extends StatefulComponent {
  const PromptInputsForm({
    required this.title,
    required this.inputs,
    required this.onSubmit,
    required this.onCancel,
    super.key,
  });

  final String title;
  final List<PromptInput> inputs;
  final void Function(Map<String, String> values) onSubmit;
  final void Function() onCancel;

  @override
  State<PromptInputsForm> createState() => _PromptInputsFormState();
}

class _PromptInputsFormState extends State<PromptInputsForm> {
  late final Map<String, String> _values = <String, String>{
    for (final field in component.inputs)
      field.name:
          field.defaultValue ??
          (field.type == 'select' && field.options.isNotEmpty
              ? field.options.first
              : ''),
  };

  bool get _complete => component.inputs.every(
    (field) => !field.required || (_values[field.name] ?? '').trim().isNotEmpty,
  );

  @override
  Component build(BuildContext context) => div(
    classes:
        'mx-auto mb-2 max-w-3xl space-y-3 rounded border border-border '
        'bg-popover p-3 text-popover-foreground',
    attributes: <String, String>{
      'role': 'group',
      'aria-label': t.desktop.desktopPromptFill(title: component.title),
    },
    [
      p(classes: 'text-sm font-medium', [
        Component.text(t.desktop.desktopPromptFill(title: component.title)),
      ]),
      for (final field in component.inputs) _field(field),
      div(classes: 'flex justify-end gap-2', [
        button(
          [Component.text(t.app.cancel)],
          classes: 'rounded px-3 py-1.5 text-sm hover:bg-accent',
          type: ButtonType.button,
          onClick: component.onCancel,
        ),
        button(
          [Component.text(t.desktop.desktopPromptInsert)],
          classes:
              'rounded bg-primary px-3 py-1.5 text-sm text-primary-foreground '
              'disabled:opacity-50',
          type: ButtonType.button,
          disabled: !_complete,
          // Checked here too: `disabled` is a presentation the handler
          // should not depend on.
          onClick: () {
            if (_complete) component.onSubmit(Map<String, String>.of(_values));
          },
        ),
      ]),
    ],
  );

  Component _field(PromptInput field) {
    final id = 'prompt-input-${field.name}';
    final label = field.required ? '${field.label} *' : field.label;
    void update(String value) => setState(() => _values[field.name] = value);
    return switch (field.type) {
      'textarea' => textAreaField(
        id: id,
        labelText: label,
        value: _values[field.name] ?? '',
        placeholder: field.placeholder,
        onInput: update,
      ),
      'select' when field.options.isNotEmpty => div(classes: 'space-y-1.5', [
        Component.element(
          tag: 'label',
          attributes: <String, String>{'for': id},
          classes: 'text-sm font-medium',
          children: <Component>[Component.text(label)],
        ),
        select(
          [
            for (final choice in field.options)
              option(value: choice, selected: _values[field.name] == choice, [
                Component.text(choice),
              ]),
          ],
          id: id,
          classes:
              'w-full rounded border border-border bg-background px-2 '
              'py-1.5 text-sm',
          onChange: (values) {
            if (values.isNotEmpty) update(values.first);
          },
        ),
      ]),
      _ => textField(
        id: id,
        labelText: label,
        value: _values[field.name] ?? '',
        placeholder: field.placeholder,
        type: field.type == 'number' ? InputType.number : InputType.text,
        onInput: update,
      ),
    };
  }
}
