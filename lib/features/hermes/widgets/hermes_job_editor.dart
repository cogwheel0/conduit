import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../models/hermes_job.dart';

final RegExp _hermesDurationPattern = RegExp(
  r'^\d+\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$',
  caseSensitive: false,
);
final RegExp _hermesCronFieldPattern = RegExp(r'^[\d*,-/]+$');
final RegExp _hermesIsoDateTimePattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?(?:Z|([+-])(\d{2}):?(\d{2}))?)?$',
);

/// Mirrors the schedule forms accepted by Hermes's `parse_schedule`: bare
/// durations, recurring `every …` intervals, ISO date/times, and five-, six-,
/// or seven-field numeric cron expressions (with optional seconds and year).
@visibleForTesting
bool isValidHermesSchedule(String value) {
  final schedule = value.trim();
  if (schedule.isEmpty) return false;
  final lower = schedule.toLowerCase();
  if (lower.startsWith('every ')) {
    return _hermesDurationPattern.hasMatch(schedule.substring(6).trim());
  }
  if (_hermesDurationPattern.hasMatch(schedule)) return true;
  if (schedule.contains('T') ||
      RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(schedule)) {
    return _isValidHermesIsoDateTime(schedule);
  }

  final fields = schedule.split(RegExp(r'\s+'));
  if (fields.length < 5 || fields.length > 7) return false;
  if (fields.any((field) => !_hermesCronFieldPattern.hasMatch(field))) {
    return false;
  }
  const bounds = [
    (0, 59),
    (0, 23),
    (1, 31),
    (1, 12),
    (0, 7),
    (0, 59),
    (1970, 2099),
  ];

  bool inBounds(int value, int field) {
    final (minimum, configuredMaximum) = bounds[field];
    // croniter accepts Sunday=7 only in the traditional five-field form.
    // Extended forms use the sixth field for seconds and require weekdays
    // in the 0-6 range.
    final maximum = field == 4 && fields.length > 5 ? 6 : configuredMaximum;
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
    final start = int.tryParse(range.first);
    if (start == null || !inBounds(start, field)) return false;
    if (range.length == 1) return true;
    final end = int.tryParse(range.last);
    // croniter intentionally accepts wrap-around ranges such as 22-2 hours
    // and 5-1 weekdays.
    return end != null && inBounds(end, field);
  }

  for (var field = 0; field < fields.length; field++) {
    final parts = fields[field].split(',');
    if (parts.isEmpty || parts.any((part) => !validPart(part, field))) {
      return false;
    }
  }
  return true;
}

bool _isValidHermesIsoDateTime(String value) {
  final match = _hermesIsoDateTimePattern.firstMatch(value);
  if (match == null) return false;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (year == 0 || month < 1 || month > 12 || day < 1 || day > 31) {
    return false;
  }
  final normalizedDate = DateTime.utc(year, month, day);
  if (normalizedDate.year != year ||
      normalizedDate.month != month ||
      normalizedDate.day != day) {
    return false;
  }
  final hourText = match.group(4);
  if (hourText == null) return true;
  final hour = int.parse(hourText);
  final minute = int.parse(match.group(5)!);
  final second = int.tryParse(match.group(6) ?? '0') ?? 0;
  if (hour > 23 || minute > 59 || second > 59) return false;
  final offsetHour = int.tryParse(match.group(9) ?? '0') ?? 0;
  final offsetMinute = int.tryParse(match.group(10) ?? '0') ?? 0;
  return offsetHour <= 23 && offsetMinute <= 59;
}

/// Shows the create/edit dialog for a scheduled Hermes job and returns the
/// entered name, prompt, and schedule, or null if cancelled.
Future<({String name, String prompt, String schedule})?> showHermesJobEditor(
  BuildContext context, {
  String? initialName,
  String? initialPrompt,
  String? initialSchedule,
}) {
  return showDialog<({String name, String prompt, String schedule})>(
    context: context,
    builder: (context) => _HermesJobEditorDialog(
      initialName: initialName,
      initialPrompt: initialPrompt,
      initialSchedule: initialSchedule,
    ),
  );
}

class _HermesJobEditorDialog extends StatefulWidget {
  const _HermesJobEditorDialog({
    this.initialName,
    this.initialPrompt,
    this.initialSchedule,
  });

  final String? initialName;
  final String? initialPrompt;
  final String? initialSchedule;

  @override
  State<_HermesJobEditorDialog> createState() => _HermesJobEditorDialogState();
}

class _HermesJobEditorDialogState extends State<_HermesJobEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _schedule;
  bool _showErrors = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName ?? '');
    _prompt = TextEditingController(text: widget.initialPrompt ?? '');
    _schedule = TextEditingController(
      text: widget.initialSchedule ?? '0 9 * * *',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _schedule.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    final schedule = _schedule.text.trim();
    if (name.isEmpty ||
        name.runes.length > kMaxHermesJobNameCharacters ||
        prompt.isEmpty ||
        prompt.runes.length > kMaxHermesJobPromptCharacters ||
        !isValidHermesSchedule(schedule)) {
      setState(() => _showErrors = true);
      return;
    }
    Navigator.of(context).pop((name: name, prompt: prompt, schedule: schedule));
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
              label: 'Name',
              hint: 'Daily summary',
              controller: _name,
              errorText: _showErrors && _name.text.trim().isEmpty
                  ? 'Required'
                  : _showErrors &&
                        _name.text.trim().runes.length >
                            kMaxHermesJobNameCharacters
                  ? 'Use $kMaxHermesJobNameCharacters characters or fewer'
                  : null,
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
            ),
            const SizedBox(height: Spacing.md),
            ConduitInput(
              label: 'Prompt',
              hint: 'What should the agent do each run?',
              controller: _prompt,
              minLines: 2,
              maxLines: 5,
              errorText: _showErrors && _prompt.text.trim().isEmpty
                  ? 'Required'
                  : _showErrors &&
                        _prompt.text.trim().runes.length >
                            kMaxHermesJobPromptCharacters
                  ? 'Use $kMaxHermesJobPromptCharacters characters or fewer'
                  : null,
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
            ),
            const SizedBox(height: Spacing.md),
            ConduitInput(
              label: 'Schedule',
              hint: '0 9 * * * or every 2h',
              controller: _schedule,
              errorText: _showErrors && _schedule.text.trim().isEmpty
                  ? 'Required'
                  : _showErrors && !isValidHermesSchedule(_schedule.text)
                  ? 'Use a duration, interval, date/time, or valid cron schedule'
                  : null,
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
            ),
            const SizedBox(height: Spacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Use cron (0 9 * * *), an interval (every 2h), a delay '
                '(30m), or an ISO date/time.',
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
