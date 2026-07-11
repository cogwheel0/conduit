import 'package:flutter/material.dart';

import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';

/// Renders a dynamic valve form from a server-provided valve [spec] (a JSON
/// schema). Mirrors Open WebUI's `Valves.svelte`: each property can be left at
/// its server default (value `null`) or overridden with a custom value, and the
/// control shape is derived from the property's `type`/`enum`/`input`.
///
/// Values are edited in a working copy; every change reports the full working
/// map through [onChanged]. `array`-typed properties are represented here as
/// comma-separated strings — the owning sheet splits them back into lists on
/// submit, matching upstream.
class WorkspaceValveForm extends StatefulWidget {
  const WorkspaceValveForm({
    super.key,
    required this.spec,
    required this.initialValues,
    required this.onChanged,
    this.enabled = true,
  });

  final WorkspaceValveSpec spec;
  final Map<String, dynamic> initialValues;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool enabled;

  @override
  State<WorkspaceValveForm> createState() => _WorkspaceValveFormState();
}

class _WorkspaceValveFormState extends State<WorkspaceValveForm> {
  late Map<String, dynamic> _values;

  @override
  void initState() {
    super.initState();
    _values = Map<String, dynamic>.from(widget.initialValues);
  }

  Map<String, dynamic> _propertySpec(String property) {
    final value = widget.spec.properties[property];
    return value is Map ? Map<String, dynamic>.from(value) : {};
  }

  void _emit() => widget.onChanged(Map<String, dynamic>.from(_values));

  void _setValue(String property, dynamic value) {
    setState(() => _values[property] = value);
    _emit();
  }

  /// Toggles a property between its server default (null) and a custom value.
  void _toggleDefault(String property) {
    final spec = _propertySpec(property);
    final isDefault = (_values[property]) == null;
    dynamic next;
    if (isDefault) {
      final enumValues = spec['enum'];
      if (spec['type'] == 'array') {
        final defaultArray = spec['default'];
        next = defaultArray is List ? defaultArray.join(', ') : '';
      } else if (enumValues is List && enumValues.isNotEmpty) {
        // Enum valves must start on an allowed option of the correct runtime
        // type. Prefer the declared default; otherwise seed the first option so
        // an untouched custom control never submits a value outside the schema
        // (and never the empty string for a numeric/boolean enum).
        next = spec['default'] ?? enumValues.first;
      } else {
        // Fall back to a type-appropriate empty value when the schema omits a
        // default, so a boolean valve becomes `false` (not `''`) and a numeric
        // valve becomes `0` — otherwise a custom-but-untouched control would
        // submit a string where the server expects a bool/number.
        next = spec['default'] ?? _typedFallback(spec['type']?.toString());
      }
    } else {
      next = null;
    }
    _setValue(property, next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final properties = widget.spec.properties.keys.toList(growable: false);
    if (properties.isEmpty) {
      return Padding(
        key: const Key('workspace-tool-valves-empty'),
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Text(
          l10n.workspaceToolValvesEmpty,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final property in properties) _field(context, l10n, property),
      ],
    );
  }

  Widget _field(
    BuildContext context,
    AppLocalizations l10n,
    String property,
  ) {
    final theme = context.conduitTheme;
    final spec = _propertySpec(property);
    final title = spec['title']?.toString() ?? property;
    final isRequired = widget.spec.required.contains(property);
    final isDefault = _values[property] == null;
    final description = spec['description']?.toString();

    return Padding(
      key: Key('workspace-tool-valve-$property'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: title,
                    style: theme.label,
                    children: [
                      if (isRequired)
                        TextSpan(
                          text: '  ${l10n.workspaceValveRequired}',
                          style: theme.caption?.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              TextButton(
                key: Key('workspace-tool-valve-toggle-$property'),
                onPressed: widget.enabled
                    ? () => _toggleDefault(property)
                    : null,
                child: Text(
                  isDefault
                      ? (isRequired
                            ? l10n.workspaceValveNone
                            : l10n.workspaceValveDefault)
                      : l10n.workspaceValveCustom,
                ),
              ),
            ],
          ),
          if (!isDefault) _control(context, l10n, property, spec),
          if (description != null && description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xxs),
              child: Text(
                description,
                style: theme.caption?.copyWith(color: theme.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _control(
    BuildContext context,
    AppLocalizations l10n,
    String property,
    Map<String, dynamic> spec,
  ) {
    final controlKey = Key('workspace-tool-valve-input-$property');
    final theme = context.conduitTheme;
    final enumValues = spec['enum'];
    final type = spec['type']?.toString();
    final title = spec['title']?.toString() ?? property;

    if (enumValues is List && enumValues.isNotEmpty) {
      final current = _values[property]?.toString();
      return DropdownButtonFormField<String>(
        key: controlKey,
        initialValue: enumValues.map((e) => e.toString()).contains(current)
            ? current
            : null,
        isDense: true,
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
        ),
        items: [
          for (final option in enumValues)
            DropdownMenuItem<String>(
              value: option.toString(),
              child: Text(option.toString()),
            ),
        ],
        onChanged: widget.enabled
            ? (value) => _setValue(property, _enumValueFor(enumValues, value))
            : null,
      );
    }

    if (type == 'boolean') {
      final current = _values[property] == true;
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            current ? l10n.workspaceValveEnabled : l10n.workspaceValveDisabled,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
          Switch(
            key: controlKey,
            value: current,
            onChanged: widget.enabled
                ? (value) => _setValue(property, value)
                : null,
          ),
        ],
      );
    }

    final inputSpec = spec['input'];
    final isPassword =
        type == 'string' &&
        inputSpec is Map &&
        inputSpec['type']?.toString() == 'password';
    final isNumber = type == 'integer' || type == 'number';

    return TextFormField(
      key: controlKey,
      initialValue: _values[property]?.toString() ?? '',
      enabled: widget.enabled,
      obscureText: isPassword,
      keyboardType: isNumber
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      minLines: 1,
      maxLines: isPassword ? 1 : 3,
      style: theme.bodyMedium,
      decoration: InputDecoration(
        hintText: title,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (value) =>
          _setValue(property, _coerce(type, value, _values[property])),
    );
  }

  /// Maps a dropdown's stringified selection back to the original enum entry so
  /// numeric/boolean enums keep their runtime type (e.g. `1`, not `"1"`). The
  /// string form is only ever a display label.
  static dynamic _enumValueFor(List<dynamic> enumValues, String? selection) {
    if (selection == null) return null;
    for (final option in enumValues) {
      if (option.toString() == selection) return option;
    }
    return selection;
  }

  /// The type-appropriate empty value used when toggling a property to custom
  /// and the schema declares no `default`. Keeps the working value's runtime
  /// type aligned with the schema so an untouched control never submits `''`
  /// where a bool/number is required.
  static dynamic _typedFallback(String? type) {
    switch (type) {
      case 'boolean':
        return false;
      case 'integer':
      case 'number':
        return 0;
      default:
        return '';
    }
  }

  /// Coerces raw text into the schema type where it is unambiguous. Numbers are
  /// parsed when valid; `array` stays a string here (split on submit); anything
  /// else is stored verbatim.
  ///
  /// For numeric schema types a cleared or malformed field ([value] that fails
  /// to parse) must never be stored — that would submit a `String` where the
  /// server expects a number. In that case the last valid value ([previous]) is
  /// retained so the submit path only ever sends a number.
  dynamic _coerce(String? type, String value, dynamic previous) {
    if (type == 'integer') {
      return int.tryParse(value.trim()) ?? previous;
    }
    if (type == 'number') {
      return num.tryParse(value.trim()) ?? previous;
    }
    return value;
  }
}
