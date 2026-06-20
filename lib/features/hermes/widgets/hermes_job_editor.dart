import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';

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
    if (prompt.isEmpty || schedule.isEmpty) {
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
            ),
            const SizedBox(height: Spacing.md),
            ConduitInput(
              label: 'Schedule (cron)',
              hint: '0 9 * * *',
              controller: _schedule,
              errorText: _showErrors && _schedule.text.trim().isEmpty
                  ? 'Required'
                  : null,
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
