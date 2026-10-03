/// Client-side check of a Hermes scheduled job's `schedule` field, so the
/// job editor can refuse a value the server would reject.
library;

import 'package:conduit_core/features/hermes/models/hermes_job.dart';

/// `parse_duration`: an optional count (a bare unit means one) and a unit.
final RegExp _hermesDurationPattern = RegExp(
  r'^(\d*)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$',
  caseSensitive: false,
);
final RegExp _hermesCronFieldPattern = RegExp(r'^[A-Za-z\d*,\-/]+$');
final RegExp _hermesClockTimePattern = RegExp(
  r'^(\d{1,2})(?::(\d{2}))?(am|pm)?$',
);
final RegExp _hermesIsoDateTimePattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?(?:Z|([+-])(\d{2}):?(\d{2}))?)?$',
);

/// Weekday names `_natural_every_to_cron` knows.
const Set<String> _hermesWeekdayNames = {
  'sunday', 'sun', 'monday', 'mon', 'tuesday', 'tue', 'tues', //
  'wednesday', 'wed', 'weds', 'thursday', 'thu', 'thur', 'thurs', //
  'friday', 'fri', 'saturday', 'sat',
};

/// Keyword day specs (`weekdays`, `daily`, ...) that stand for a day list.
const Set<String> _hermesDaySpecKeywords = {
  'day', 'daily', 'everyday', 'weekday', 'weekdays', 'weekend', 'weekends', //
};

/// Month and weekday names croniter accepts in the matching cron fields.
const Map<String, int> _hermesCronMonthNames = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, //
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};
const Map<String, int> _hermesCronWeekdayNames = {
  'sun': 0, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6, //
};

/// Mirrors the schedule forms accepted by Hermes's `parse_schedule`:
///
/// - recurring intervals: a bare duration (`30m`, or just `hour`) or
///   `every <duration>`;
/// - one-shot delays: `in <duration>`;
/// - natural day and time phrases, with or without `every`
///   (`every monday 9am`, `weekdays at 9am`, `monday, wednesday at noon`);
/// - ISO date/times;
/// - five- to seven-field cron expressions (seconds and year optional), with
///   month and weekday names (`JAN-MAR`, `MON-FRI`) as well as numbers.
bool isValidHermesSchedule(String value) {
  final schedule = value.trim();
  if (schedule.isEmpty) return false;
  final lower = schedule.toLowerCase();
  final isEvery = lower.startsWith('every ');
  final rest = isEvery ? schedule.substring(6).trim() : lower;
  if (_isNaturalHermesSchedule(rest)) return true;
  if (isEvery) return _hermesDurationPattern.hasMatch(rest);

  final fields = schedule.split(RegExp(r'\s+'));
  if (fields.length >= 5 &&
      fields.take(5).every(_hermesCronFieldPattern.hasMatch)) {
    return _isValidHermesCron(fields);
  }
  if (schedule.contains('T') ||
      RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(schedule)) {
    return _isValidHermesIsoDateTime(schedule);
  }
  if (lower.startsWith('in ')) {
    return _hermesDurationPattern.hasMatch(schedule.substring(3).trim());
  }
  return _hermesDurationPattern.hasMatch(schedule);
}

/// `_natural_every_to_cron`: `<days> [at] <time>`, where days is a keyword
/// spec or a list of weekday names (separated by spaces, commas or `and`).
bool _isNaturalHermesSchedule(String rest) {
  final tokens = rest
      .toLowerCase()
      .replaceAll(',', ' ')
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return false;

  var index = 1;
  if (!_hermesDaySpecKeywords.contains(tokens.first)) {
    var days = 0;
    index = tokens.length;
    for (var i = 0; i < tokens.length; i++) {
      if (tokens[i] == 'and') continue;
      if (!_hermesWeekdayNames.contains(tokens[i])) {
        index = i;
        break;
      }
      days++;
    }
    if (days == 0) return false;
  }

  var timeTokens = tokens.sublist(index);
  if (timeTokens.isNotEmpty && timeTokens.first == 'at') {
    timeTokens = timeTokens.sublist(1);
  }
  if (timeTokens.isEmpty) return false;
  return _isHermesClockTime(timeTokens.join());
}

/// `_parse_clock_time`: `9am`, `9:30pm`, `14:00`, a bare hour, `noon`, ...
bool _isHermesClockTime(String text) {
  final time = text.toLowerCase();
  if (time == 'noon' || time == 'midday' || time == 'midnight') return true;
  final match = _hermesClockTimePattern.firstMatch(time);
  if (match == null) return false;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2) ?? '0');
  if (match.group(3) != null && (hour < 1 || hour > 12)) return false;
  final hour24 = match.group(3) == null
      ? hour
      : hour % 12 + (match.group(3) == 'pm' ? 12 : 0);
  return hour24 <= 23 && minute <= 59;
}

bool _isValidHermesCron(List<String> fields) {
  if (fields.length > 7) return false;
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

  /// A number, or a name in the month and weekday fields.
  int? valueOf(String text, int field) =>
      int.tryParse(text) ??
      switch (field) {
        3 => _hermesCronMonthNames[text.toLowerCase()],
        4 => _hermesCronWeekdayNames[text.toLowerCase()],
        _ => null,
      };

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
    final start = valueOf(range.first, field);
    if (start == null || !inBounds(start, field)) return false;
    if (range.length == 1) return true;
    final end = valueOf(range.last, field);
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
