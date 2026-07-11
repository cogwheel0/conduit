import 'package:intl/intl.dart';

import '../models/hermes_job.dart';

/// Human-readable cadence for the common five-field cron forms Hermes uses.
/// Unknown expressions remain visible instead of being guessed at.
String describeHermesCronSchedule(String expression) {
  final normalized = expression.trim().replaceAll(RegExp(r'\s+'), ' ');
  final fields = normalized.split(' ');
  if (fields.length != 5) {
    return normalized.isEmpty ? 'No schedule' : normalized;
  }

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
    return 'Every minute';
  }

  final minuteStep = _stepValue(minute, max: 59);
  if (minuteStep != null &&
      hour == '*' &&
      dayOfMonth == '*' &&
      month == '*' &&
      dayOfWeek == '*') {
    return minuteStep == 1 ? 'Every minute' : 'Every $minuteStep minutes';
  }

  final numericMinute = int.tryParse(minute);
  if (numericMinute != null &&
      numericMinute <= 59 &&
      dayOfMonth == '*' &&
      month == '*' &&
      dayOfWeek == '*') {
    if (hour == '*') {
      return numericMinute == 0
          ? 'Every hour'
          : 'Every hour at :${numericMinute.toString().padLeft(2, '0')}';
    }
    final hourStep = _stepValue(hour, max: 23);
    if (hourStep != null) {
      final suffix = numericMinute == 0
          ? ''
          : ' at :${numericMinute.toString().padLeft(2, '0')}';
      return hourStep == 1
          ? 'Every hour$suffix'
          : 'Every $hourStep hours$suffix';
    }
  }

  final numericHour = int.tryParse(hour);
  if (numericMinute == null ||
      numericHour == null ||
      numericMinute > 59 ||
      numericHour > 23) {
    return normalized;
  }

  final time = _formatTime(numericHour, numericMinute);
  if (dayOfMonth == '*' && month == '*') {
    if (dayOfWeek == '*') return 'Every day at $time';
    if (dayOfWeek == '1-5' || dayOfWeek == 'MON-FRI') {
      return 'Weekdays at $time';
    }
    if (dayOfWeek == '0,6' ||
        dayOfWeek == '6,0' ||
        dayOfWeek == 'SUN,SAT' ||
        dayOfWeek == 'SAT,SUN') {
      return 'Weekends at $time';
    }
    final weekday = _weekdayLabel(dayOfWeek);
    if (weekday != null) return 'Every $weekday at $time';
  }

  final numericDay = int.tryParse(dayOfMonth);
  if (numericDay != null &&
      numericDay >= 1 &&
      numericDay <= 31 &&
      month == '*' &&
      dayOfWeek == '*') {
    return 'Monthly on the ${_ordinal(numericDay)} at $time';
  }

  return normalized;
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

String? _weekdayLabel(String value) {
  const labels = <String, String>{
    '0': 'Sunday',
    '7': 'Sunday',
    'SUN': 'Sunday',
    '1': 'Monday',
    'MON': 'Monday',
    '2': 'Tuesday',
    'TUE': 'Tuesday',
    '3': 'Wednesday',
    'WED': 'Wednesday',
    '4': 'Thursday',
    'THU': 'Thursday',
    '5': 'Friday',
    'FRI': 'Friday',
    '6': 'Saturday',
    'SAT': 'Saturday',
  };
  return labels[value];
}

String _ordinal(int value) {
  if (value >= 11 && value <= 13) return '${value}th';
  return switch (value % 10) {
    1 => '${value}st',
    2 => '${value}nd',
    3 => '${value}rd',
    _ => '${value}th',
  };
}
