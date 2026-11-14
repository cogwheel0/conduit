import 'package:intl/intl.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/hermes/models/hermes_job.dart';

/// The cadences [describeHermesCronSchedule] puts into words, as data: a
/// client that words them in its own language reads these, and the English
/// sentence stays the fallback.
enum HermesCadenceKind {
  /// No expression at all.
  none,
  everyMinute,

  /// Every [HermesCadence.every] minutes (2 or more).
  everyMinutes,

  /// Every hour, at [HermesCadence.minute] past (0 for on the hour).
  everyHour,

  /// Every [HermesCadence.every] hours (2 or more), at
  /// [HermesCadence.minute] past.
  everyHours,

  /// Every day at [HermesCadence.hour]:[HermesCadence.minute].
  daily,

  /// Monday to Friday at the time.
  weekdays,

  /// Saturday and Sunday at the time.
  weekends,

  /// On [HermesCadence.weekday] at the time.
  weekly,

  /// On day [HermesCadence.day] of each month at the time.
  monthly,
}

/// A five-field cron expression Hermes uses, read: what
/// [describeHermesCronSchedule] says in English.
@immutable
class HermesCadence {
  const HermesCadence(
    this.kind, {
    this.every,
    this.hour,
    this.minute,
    this.weekday,
    this.day,
  });

  final HermesCadenceKind kind;

  /// The step of [HermesCadenceKind.everyMinutes] and
  /// [HermesCadenceKind.everyHours].
  final int? every;

  /// The time's hour, 0–23.
  final int? hour;

  /// The time's minute, 0–59; for the hourly kinds, the minute past the
  /// hour.
  final int? minute;

  /// [HermesCadenceKind.weekly]'s day: 0 is Sunday, 6 Saturday.
  final int? weekday;

  /// [HermesCadenceKind.monthly]'s day of the month, 1–31.
  final int? day;

  @override
  bool operator ==(Object other) =>
      other is HermesCadence &&
      other.kind == kind &&
      other.every == every &&
      other.hour == hour &&
      other.minute == minute &&
      other.weekday == weekday &&
      other.day == day;

  @override
  int get hashCode => Object.hash(kind, every, hour, minute, weekday, day);

  @override
  String toString() =>
      'HermesCadence($kind, every: $every, hour: $hour, minute: $minute, '
      'weekday: $weekday, day: $day)';
}

/// Reads the common five-field cron forms Hermes uses; null for anything
/// else, which is shown as it is written rather than guessed at.
HermesCadence? parseHermesCronSchedule(String expression) {
  final normalized = expression.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return const HermesCadence(HermesCadenceKind.none);
  final fields = normalized.split(' ');
  if (fields.length != 5) return null;

  final minute = fields[0].toUpperCase();
  final hour = fields[1].toUpperCase();
  final dayOfMonth = fields[2].toUpperCase();
  final month = fields[3].toUpperCase();
  final dayOfWeek = fields[4].toUpperCase();

  if (minute == '*' &&
      hour == '*' &&
      dayOfMonth == '*' &&
      month == '*' &&
      dayOfWeek == '*') {
    return const HermesCadence(HermesCadenceKind.everyMinute);
  }

  final minuteStep = _stepValue(minute, max: 59);
  if (minuteStep != null &&
      hour == '*' &&
      dayOfMonth == '*' &&
      month == '*' &&
      dayOfWeek == '*') {
    return minuteStep == 1
        ? const HermesCadence(HermesCadenceKind.everyMinute)
        : HermesCadence(HermesCadenceKind.everyMinutes, every: minuteStep);
  }

  final numericMinute = int.tryParse(minute);
  if (numericMinute != null &&
      numericMinute <= 59 &&
      dayOfMonth == '*' &&
      month == '*' &&
      dayOfWeek == '*') {
    if (hour == '*') {
      return HermesCadence(HermesCadenceKind.everyHour, minute: numericMinute);
    }
    final hourStep = _stepValue(hour, max: 23);
    if (hourStep != null) {
      return hourStep == 1
          ? HermesCadence(HermesCadenceKind.everyHour, minute: numericMinute)
          : HermesCadence(
              HermesCadenceKind.everyHours,
              every: hourStep,
              minute: numericMinute,
            );
    }
  }

  final numericHour = int.tryParse(hour);
  if (numericMinute == null ||
      numericHour == null ||
      numericMinute > 59 ||
      numericHour > 23) {
    return null;
  }

  HermesCadence at(HermesCadenceKind kind, {int? weekday, int? day}) =>
      HermesCadence(
        kind,
        hour: numericHour,
        minute: numericMinute,
        weekday: weekday,
        day: day,
      );
  if (dayOfMonth == '*' && month == '*') {
    if (dayOfWeek == '*') return at(HermesCadenceKind.daily);
    if (dayOfWeek == '1-5' || dayOfWeek == 'MON-FRI') {
      return at(HermesCadenceKind.weekdays);
    }
    if (dayOfWeek == '0,6' ||
        dayOfWeek == '6,0' ||
        dayOfWeek == 'SUN,SAT' ||
        dayOfWeek == 'SAT,SUN') {
      return at(HermesCadenceKind.weekends);
    }
    final weekday = _weekdays[dayOfWeek];
    if (weekday != null) return at(HermesCadenceKind.weekly, weekday: weekday);
  }

  final numericDay = int.tryParse(dayOfMonth);
  if (numericDay != null &&
      numericDay >= 1 &&
      numericDay <= 31 &&
      month == '*' &&
      dayOfWeek == '*') {
    return at(HermesCadenceKind.monthly, day: numericDay);
  }

  return null;
}

/// Human-readable cadence for the common five-field cron forms Hermes uses.
/// Unknown expressions remain visible instead of being guessed at.
String describeHermesCronSchedule(String expression) {
  final cadence = parseHermesCronSchedule(expression);
  if (cadence == null) {
    return expression.trim().replaceAll(RegExp(r'\s+'), ' ');
  }
  String pastTheHour(int? minute) => minute == null || minute == 0
      ? ''
      : ' at :${minute.toString().padLeft(2, '0')}';
  String time() => _formatTime(cadence.hour ?? 0, cadence.minute ?? 0);
  return switch (cadence.kind) {
    HermesCadenceKind.none => 'No schedule',
    HermesCadenceKind.everyMinute => 'Every minute',
    HermesCadenceKind.everyMinutes => 'Every ${cadence.every} minutes',
    HermesCadenceKind.everyHour => 'Every hour${pastTheHour(cadence.minute)}',
    HermesCadenceKind.everyHours =>
      'Every ${cadence.every} hours${pastTheHour(cadence.minute)}',
    HermesCadenceKind.daily => 'Every day at ${time()}',
    HermesCadenceKind.weekdays => 'Weekdays at ${time()}',
    HermesCadenceKind.weekends => 'Weekends at ${time()}',
    HermesCadenceKind.weekly =>
      'Every ${_weekdayNames[cadence.weekday ?? 0]} at ${time()}',
    HermesCadenceKind.monthly =>
      'Monthly on the ${_ordinal(cadence.day ?? 1)} at ${time()}',
  };
}

/// Whether [schedule] benefits from showing its raw cron expression alongside
/// the human-readable cadence.
bool hermesScheduleNeedsRawDisplay(String schedule) {
  final normalized = schedule.trim().replaceAll(RegExp(r'\s+'), ' ');
  return normalized.isNotEmpty &&
      describeHermesCronSchedule(schedule) != normalized;
}

String hermesJobTimingDetail(HermesJob job, {String? locale}) {
  final nextRun = job.nextRun;
  if (nextRun != null) {
    final formatter = DateFormat.MMMEd(locale).add_jm();
    return 'Next ${formatter.format(nextRun.toLocal())}';
  }
  final lastRun = job.lastRun;
  if (lastRun != null) {
    final formatter = DateFormat.MMMEd(locale).add_jm();
    return 'Last ran ${formatter.format(lastRun.toLocal())}';
  }
  return 'Next run not reported';
}

int? _stepValue(String field, {required int max}) {
  if (!field.startsWith('*/')) return null;
  final value = int.tryParse(field.substring(2));
  return value != null && value > 0 && value <= max ? value : null;
}

String _formatTime(int hour, int minute) {
  final period = hour >= 12 ? 'PM' : 'AM';
  final displayHour = hour % 12 == 0 ? 12 : hour % 12;
  return '$displayHour:${minute.toString().padLeft(2, '0')} $period';
}

/// A cron day-of-week field naming one day, by its number (0 is Sunday).
const Map<String, int> _weekdays = <String, int>{
  '0': 0,
  '7': 0,
  'SUN': 0,
  '1': 1,
  'MON': 1,
  '2': 2,
  'TUE': 2,
  '3': 3,
  'WED': 3,
  '4': 4,
  'THU': 4,
  '5': 5,
  'FRI': 5,
  '6': 6,
  'SAT': 6,
};

const List<String> _weekdayNames = <String>[
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

String _ordinal(int value) {
  if (value >= 11 && value <= 13) return '${value}th';
  return switch (value % 10) {
    1 => '${value}st',
    2 => '${value}nd',
    3 => '${value}rd',
    _ => '${value}th',
  };
}
