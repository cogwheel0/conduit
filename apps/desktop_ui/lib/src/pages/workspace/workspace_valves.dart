import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../../l10n/strings.g.dart';
import '../../rpc/workspace_providers.dart';
import '../../widgets/form_field.dart';
import 'workspace_common.dart';

/// A tool's valves -- its settings, or with [user] the signed-in user's own
/// -- as a form drawn from the JSON schema the tool declares.
class ValvesDialog extends StatefulComponent {
  const ValvesDialog({
    required this.toolId,
    required this.user,
    required this.onClose,
    super.key,
  });

  final String toolId;
  final bool user;
  final void Function() onClose;

  @override
  State<ValvesDialog> createState() => _ValvesDialogState();
}

class _ValvesDialogState extends State<ValvesDialog> {
  /// What the user changed, over what the tool has.
  final Map<String, Object?> _edits = <String, Object?>{};
  bool _busy = false;
  String? _status;
  bool _statusIsError = false;

  Future<void> _save(BuildContext context, WorkspaceValves valves) async {
    setState(() => _busy = true);
    try {
      await context
          .read(workspaceActionsProvider)
          .saveValves(
            valves.copyWith(
              values: <String, dynamic>{...valves.values, ..._edits},
            ),
          );
      context.invalidate(
        workspaceValvesProvider((
          toolId: component.toolId,
          user: component.user,
        )),
      );
      _edits.clear();
      setState(() {
        _status = t.app.workspaceToolValvesSaved;
        _statusIsError = false;
      });
    } on Object {
      setState(() {
        _status = t.app.workspaceToolValvesSaveFailed;
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Component build(BuildContext context) {
    final valves = context.watch(
      workspaceValvesProvider((toolId: component.toolId, user: component.user)),
    );
    final value = valves.value;
    final properties = value?.schema['properties'];
    final required = <String>{
      for (final name in (value?.schema['required'] as List?) ?? const [])
        '$name',
    };
    return modal(
      label: component.user
          ? t.app.workspaceToolValvesUser
          : t.app.workspaceToolValvesServer,
      onClose: component.onClose,
      children: [
        if (component.user)
          statusLine(t.desktop.desktopWorkspaceValvesUserHint),
        if (valves.isLoading && value == null)
          statusLine(t.app.loadingShort)
        else if (valves.hasError && value == null)
          statusLine(t.app.workspaceToolValvesLoadFailed, error: true)
        else if (properties is! Map || properties.isEmpty)
          statusLine(t.app.workspaceToolValvesEmpty)
        else
          for (final entry in properties.entries)
            if (entry.value is Map)
              _field(
                '${entry.key}',
                (entry.value as Map).cast<String, dynamic>(),
                _edits.containsKey(entry.key)
                    ? _edits[entry.key]
                    : value!.values[entry.key],
                required: required.contains(entry.key),
              ),
        if (_status case final status?)
          statusLine(status, error: _statusIsError),
        div(classes: 'flex justify-end gap-2', [
          actionButton(t.app.close, onClick: component.onClose),
          if (value != null)
            actionButton(
              t.app.save,
              primary: true,
              id: 'valves-save',
              disabled: _busy || _edits.isEmpty,
              onClick: () => unawaited(_save(context, value)),
            ),
        ]),
      ],
    );
  }

  Component _field(
    String name,
    Map<String, dynamic> spec,
    Object? current, {
    required bool required,
  }) {
    final title = '${spec['title'] ?? name}${required ? ' *' : ''}';
    final description = spec['description'] as String?;
    final fallback = spec['default'];
    final type = spec['type'] ?? _typeOfAnyOf(spec);
    final id = 'valve-$name';
    final shown = current ?? fallback;
    void set(Object? value) => setState(() => _edits[name] = value);
    final Component control;
    if (spec['enum'] case final List<dynamic> choices) {
      control = div(classes: 'space-y-1.5', [
        label(htmlFor: id, classes: 'block text-sm font-medium', [
          Component.text(title),
        ]),
        select(
          [
            for (final choice in choices)
              option(value: '$choice', selected: '$choice' == '$shown', [
                Component.text('$choice'),
              ]),
          ],
          id: id,
          classes:
              'w-full rounded border border-border bg-background px-3 py-2 '
              'text-sm',
          onChange: (values) => set(values.isEmpty ? null : values.first),
        ),
      ]);
    } else if (type == 'boolean') {
      control = checkboxField(
        id: id,
        text: title,
        checked: shown == true,
        onChanged: ({required value}) => set(value),
      );
    } else if (type == 'integer' || type == 'number') {
      control = textField(
        id: id,
        labelText: title,
        type: InputType.number,
        value: shown == null ? '' : '$shown',
        onInput: (text) => set(
          text.trim().isEmpty
              ? null
              : type == 'integer'
              ? int.tryParse(text.trim())
              : num.tryParse(text.trim()),
        ),
      );
    } else {
      control = textField(
        id: id,
        labelText: title,
        type:
            name.toLowerCase().contains('key') ||
                name.toLowerCase().contains('password') ||
                name.toLowerCase().contains('token')
            ? InputType.password
            : InputType.text,
        value: shown == null ? '' : '$shown',
        onInput: set,
      );
    }
    return div(classes: 'space-y-1', [
      control,
      if (description != null && description.isNotEmpty)
        p(classes: 'text-xs text-muted-foreground', [
          Component.text(description),
        ]),
      if (fallback != null)
        p(classes: 'text-[11px] text-muted-foreground', [
          Component.text('${t.app.workspaceValveDefault}: $fallback'),
        ]),
    ]);
  }

  /// `Optional[int]` arrives as `anyOf: [{type: integer}, {type: null}]`.
  static Object? _typeOfAnyOf(Map<String, dynamic> spec) {
    final anyOf = spec['anyOf'];
    if (anyOf is! List) return null;
    for (final option in anyOf) {
      if (option is Map && option['type'] != 'null') return option['type'];
    }
    return null;
  }
}
