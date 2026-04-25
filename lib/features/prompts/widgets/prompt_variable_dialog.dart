import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:conduit/core/utils/prompt_variable_parser.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/conduit_input_styles.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';

/// A dialog that collects user input for prompt variables.
///
/// Displays input fields for each variable based on their type (text, textarea,
/// select, number) and validates required fields before submission.
class PromptVariableDialog extends StatefulWidget {
  const PromptVariableDialog({
    super.key,
    required this.variables,
    required this.promptTitle,
  });

  /// The variables that require user input.
  final List<PromptVariable> variables;

  /// The title of the prompt being used.
  final String promptTitle;

  /// Shows the dialog and returns a map of variable name to user-provided value.
  /// Returns null if the user cancels the dialog.
  static Future<Map<String, String>?> show(
    BuildContext context, {
    required List<PromptVariable> variables,
    required String promptTitle,
  }) {
    return showDialog<Map<String, String>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          PromptVariableDialog(variables: variables, promptTitle: promptTitle),
    );
  }

  @override
  State<PromptVariableDialog> createState() => _PromptVariableDialogState();
}

class _PromptVariableDialogState extends State<PromptVariableDialog> {
  late final Map<String, TextEditingController> _controllers;
  late final Map<String, String?> _selectValues;
  final _formKey = GlobalKey<FormState>();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _controllers = {};
    _selectValues = {};

    for (final variable in widget.variables) {
      if (variable.type == PromptVariableType.select) {
        _selectValues[variable.name] = variable.defaultValue;
      } else {
        _controllers[variable.name] = TextEditingController(
          text: variable.defaultValue ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_isSubmitting) return;

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSubmitting = true);

    final values = <String, String>{};
    for (final variable in widget.variables) {
      if (variable.type == PromptVariableType.select) {
        values[variable.name] = _selectValues[variable.name] ?? '';
      } else {
        values[variable.name] = _controllers[variable.name]?.text ?? '';
      }
    }

    Navigator.of(context).pop(values);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      backgroundColor: theme.surfaceBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.dialog),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.promptTitle.isNotEmpty
                ? widget.promptTitle
                : l10n.promptVariablesTitle,
            style: AppTypography.titleMediumStyle.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            l10n.promptVariablesDescription,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < widget.variables.length; i++) ...[
                  if (i > 0) const SizedBox(height: Spacing.md),
                  _buildField(widget.variables[i]),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        AdaptiveButton(
          onPressed: () => Navigator.of(context).pop(null),
          label: l10n.cancel,
          textColor: theme.textSecondary,
          style: AdaptiveButtonStyle.plain,
        ),
        AdaptiveButton(
          onPressed: _isSubmitting ? null : _submit,
          label: l10n.continueAction,
          textColor: _isSubmitting ? theme.textSecondary : theme.buttonPrimary,
          style: AdaptiveButtonStyle.plain,
        ),
      ],
    );
  }

  Widget _buildField(PromptVariable variable) {
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                variable.displayLabel,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (variable.isRequired)
              Text(
                ' *',
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        _buildInputWidget(variable),
      ],
    );
  }

  Widget _buildInputWidget(PromptVariable variable) {
    switch (variable.type) {
      case PromptVariableType.textarea:
        return _buildTextareaField(variable);
      case PromptVariableType.select:
        return _buildSelectField(variable);
      case PromptVariableType.number:
        return _buildNumberField(variable);
      case PromptVariableType.text:
        return _buildTextField(variable);
    }
  }

  Widget _buildTextField(PromptVariable variable) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return TextFormField(
      controller: _controllers[variable.name],
      style: AppTypography.bodyMediumStyle.copyWith(color: theme.inputText),
      decoration: context.conduitInputStyles.standard(
        hint: variable.placeholder,
      ),
      validator: (value) {
        if (variable.isRequired && (value == null || value.trim().isEmpty)) {
          return l10n.requiredFieldHelper;
        }
        return null;
      },
      onFieldSubmitted: (_) => _submit(),
    );
  }

  Widget _buildTextareaField(PromptVariable variable) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return TextFormField(
      controller: _controllers[variable.name],
      style: AppTypography.bodyMediumStyle.copyWith(color: theme.inputText),
      decoration: context.conduitInputStyles.standard(
        hint: variable.placeholder,
      ),
      minLines: 3,
      maxLines: 6,
      validator: (value) {
        if (variable.isRequired && (value == null || value.trim().isEmpty)) {
          return l10n.requiredFieldHelper;
        }
        return null;
      },
    );
  }

  Widget _buildSelectField(PromptVariable variable) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final options = variable.options;

    return DropdownButtonFormField<String>(
      initialValue: _selectValues[variable.name],
      decoration: context.conduitInputStyles.standard(
        hint: variable.placeholder,
      ),
      dropdownColor: theme.surfaceBackground,
      style: AppTypography.bodyMediumStyle.copyWith(color: theme.inputText),
      items: options.map((option) {
        return DropdownMenuItem<String>(value: option, child: Text(option));
      }).toList(),
      onChanged: (value) {
        setState(() {
          _selectValues[variable.name] = value;
        });
      },
      validator: (value) {
        if (variable.isRequired && (value == null || value.isEmpty)) {
          return l10n.requiredFieldHelper;
        }
        return null;
      },
    );
  }

  Widget _buildNumberField(PromptVariable variable) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return TextFormField(
      controller: _controllers[variable.name],
      style: AppTypography.bodyMediumStyle.copyWith(color: theme.inputText),
      decoration: context.conduitInputStyles.standard(
        hint: variable.placeholder,
      ),
      keyboardType: TextInputType.numberWithOptions(
        decimal: variable.step != null && variable.step! < 1,
        signed: variable.min != null && variable.min! < 0,
      ),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.-]'))],
      validator: (value) {
        if (variable.isRequired && (value == null || value.trim().isEmpty)) {
          return l10n.requiredFieldHelper;
        }
        if (value != null && value.isNotEmpty) {
          final num = double.tryParse(value);
          if (num == null) {
            return l10n.validationFormatError;
          }
          if (variable.min != null && num < variable.min!) {
            return l10n.promptVariableNumberMin(variable.min!);
          }
          if (variable.max != null && num > variable.max!) {
            return l10n.promptVariableNumberMax(variable.max!);
          }
        }
        return null;
      },
      onFieldSubmitted: (_) => _submit(),
    );
  }
}
