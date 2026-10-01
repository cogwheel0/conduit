/// Client-side check of a Hermes scheduled job's `schedule` field, so the
/// job editor can refuse a value the server would reject.
library;

import 'package:conduit_core/features/hermes/models/hermes_job.dart';

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

/// Why a job editor field cannot be saved.
enum HermesJobFieldError { required, tooLong, invalidSchedule }

/// The job editor's checks, per field (trimmed): name and prompt are
/// required and bounded ([kMaxHermesJobNameCharacters],
/// [kMaxHermesJobPromptCharacters], counted in code points); the schedule is
/// required and must pass [isValidHermesSchedule].
({
  HermesJobFieldError? name,
  HermesJobFieldError? prompt,
  HermesJobFieldError? schedule,
})
validateHermesJobDraft({
  required String name,
  required String prompt,
  required String schedule,
}) {
  HermesJobFieldError? bounded(String value, int maximum) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return HermesJobFieldError.required;
    if (trimmed.runes.length > maximum) return HermesJobFieldError.tooLong;
    return null;
  }

  final trimmedSchedule = schedule.trim();
  return (
    name: bounded(name, kMaxHermesJobNameCharacters),
    prompt: bounded(prompt, kMaxHermesJobPromptCharacters),
    schedule: trimmedSchedule.isEmpty
        ? HermesJobFieldError.required
        : isValidHermesSchedule(trimmedSchedule)
        ? null
        : HermesJobFieldError.invalidSchedule,
  );
}

/// Whether [validateHermesJobDraft] found nothing wrong.
bool hermesJobDraftIsValid(
  ({
    HermesJobFieldError? name,
    HermesJobFieldError? prompt,
    HermesJobFieldError? schedule,
  })
  errors,
) => errors.name == null && errors.prompt == null && errors.schedule == null;
