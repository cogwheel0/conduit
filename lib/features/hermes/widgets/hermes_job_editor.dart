import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';

/// Validates the five-field cron syntax accepted by the Hermes jobs API.
/// Supports wildcards, lists, ranges, steps, numeric values, and standard
/// month/weekday names.
@visibleForTesting
bool isValidHermesCronExpression(String value) {
  final fields = value.trim().split(RegExp(r'\s+'));
  if (fields.length != 5) return false;
  const bounds = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)];
  const names = [
    <String, int>{},
    <String, int>{},
    <String, int>{},
    {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    },
    {'sun': 0, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6},
  ];

  int? parseValue(String raw, int field) =>
      int.tryParse(raw) ?? names[field][raw.toLowerCase()];

  bool inBounds(int value, int field) {
    final (minimum, maximum) = bounds[field];
    return value >= minimum && value <= maximum;
  }

  bool validPart(String raw, int field) {
    if (raw.isEmpty) return false;
    final stepParts = raw.split('/');
    if (stepParts.length > 2) return false;
    if (stepParts.length == 2) {
      final step = int.tryParse(stepParts[1]);
      if (step == null || step <= 0) return false;
    }

    final base = stepParts.first;
    if (base == '*') return true;
    final range = base.split('-');
    if (range.length > 2) return false;
    final start = parseValue(range.first, field);
    if (start == null || !inBounds(start, field)) return false;
    if (range.length == 1) return true;
    final end = parseValue(range.last, field);
    return end != null && inBounds(end, field) && start <= end;
  }

  for (var field = 0; field < fields.length; field++) {
    final parts = fields[field].split(',');
    if (parts.isEmpty || parts.any((part) => !validPart(part, field))) {
      return false;
    }
  }
  return true;
}

/// Shows the create/edit dialog for a scheduled Hermes job and returns the
/// entered prompt + cron schedule, or null if cancelled.
Future<({String prompt, String schedule})?> showHermesJobEditor(
  BuildContext context, {
  String? initialPrompt,
  String? initialSchedule,
}) {
  return showDialog<({String prompt, String schedule})>(
    context: context,
    builder: (context) => _HermesJobEditorDialog(
      initialPrompt: initialPrompt,
      initialSchedule: initialSchedule,
    ),
  );
}

class _HermesJobEditorDialog extends StatefulWidget {
  const _HermesJobEditorDialog({this.initialPrompt, this.initialSchedule});

  final String? initialPrompt;
  final String? initialSchedule;

  @override
  State<_HermesJobEditorDialog> createState() => _HermesJobEditorDialogState();
}

class _HermesJobEditorDialogState extends State<_HermesJobEditorDialog> {
  late final TextEditingController _prompt;
  late final TextEditingController _schedule;
  bool _showErrors = false;

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(text: widget.initialPrompt ?? '');
    _schedule = TextEditingController(
      text: widget.initialSchedule ?? '0 9 * * *',
    );
  }

  @override
  void dispose() {
    _prompt.dispose();
    _schedule.dispose();
    super.dispose();
  }

  void _save() {
    final prompt = _prompt.text.trim();
    final schedule = _schedule.text.trim();
    if (prompt.isEmpty || !isValidHermesCronExpression(schedule)) {
      setState(() => _showErrors = true);
      return;
    }
    Navigator.of(context).pop((prompt: prompt, schedule: schedule));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final isEditing = widget.initialPrompt != null;

    return AlertDialog(
      backgroundColor: theme.surfaceBackground,
      title: Text(isEditing ? 'Edit job' : 'New scheduled job'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConduitInput(
              label: 'Prompt',
              hint: 'What should the agent do each run?',
              controller: _prompt,
              minLines: 2,
              maxLines: 5,
              errorText: _showErrors && _prompt.text.trim().isEmpty
                  ? 'Required'
                  : null,
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
            ),
            const SizedBox(height: Spacing.md),
            ConduitInput(
              label: 'Schedule (cron)',
              hint: '0 9 * * *',
              controller: _schedule,
              errorText: _showErrors && _schedule.text.trim().isEmpty
                  ? 'Required'
                  : _showErrors && !isValidHermesCronExpression(_schedule.text)
                  ? 'Use a valid five-field cron schedule'
                  : null,
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
            ),
            const SizedBox(height: Spacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Cron format: minute hour day month weekday. '
                'Example: "0 9 * * 1" = 9am every Monday.',
                style: AppTypography.captionStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
