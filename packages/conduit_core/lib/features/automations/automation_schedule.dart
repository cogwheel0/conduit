import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// A task's recurrence rule, as Open WebUI's schedule control writes it.
///
/// Only the shapes this client can reproduce are typed. Every other rule,
/// `FREQ=MONTHLY`, an `INTERVAL`, an `UNTIL`, a time zone on `DTSTART`, is a
/// [RawAutomationSchedule] that is carried exactly as stored, so an edit that
/// does not touch the schedule cannot rewrite it.
///
/// Times are wall-clock values with no zone: the server reads them in the
/// account's time zone, which this client cannot read, so it never converts
/// them. When the next run happens is the server's answer, not this class's.
@immutable
sealed class AutomationSchedule {
  const AutomationSchedule();

  /// The rule to send to the server.
  String toRrule();

  /// Reads [rrule] as one of the typed shapes, or keeps it verbatim as a
  /// [RawAutomationSchedule] when it is anything else.
  factory AutomationSchedule.parse(String rrule) =>
      _parse(rrule) ?? RawAutomationSchedule(rrule);

  /// Weekday codes in the order the server's rule uses, Monday first.
  static const List<String> weekdayCodes = <String>[
    'MO',
    'TU',
    'WE',
    'TH',
    'FR',
    'SA',
    'SU',
  ];
}

/// Runs once, at a wall-clock moment.
final class OnceAutomationSchedule extends AutomationSchedule {
  const OnceAutomationSchedule({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
  });

  /// The wall-clock fields of [dateTime], dropping its zone and seconds.
  factory OnceAutomationSchedule.fromDateTime(DateTime dateTime) =>
      OnceAutomationSchedule(
        year: dateTime.year,
        month: dateTime.month,
        day: dateTime.day,
        hour: dateTime.hour,
        minute: dateTime.minute,
      );

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;

  /// The wall-clock moment as a zone-less [DateTime], for a date/time picker.
  DateTime get wallClock => DateTime(year, month, day, hour, minute);

  @override
  String toRrule() =>
      'DTSTART:${_pad(year, 4)}${_pad(month)}${_pad(day)}'
      'T${_pad(hour)}${_pad(minute)}00\nRRULE:FREQ=DAILY;COUNT=1';

  @override
  bool operator ==(Object other) =>
      other is OnceAutomationSchedule &&
      other.year == year &&
      other.month == month &&
      other.day == day &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(year, month, day, hour, minute);
}

/// Runs every day at a wall-clock time.
final class DailyAutomationSchedule extends AutomationSchedule {
  const DailyAutomationSchedule({required this.hour, required this.minute});

  final int hour;
  final int minute;

  @override
  String toRrule() => 'RRULE:FREQ=DAILY;BYHOUR=$hour;BYMINUTE=$minute';

  @override
  bool operator ==(Object other) =>
      other is DailyAutomationSchedule &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);
}

/// Runs on chosen weekdays at a wall-clock time.
final class WeeklyAutomationSchedule extends AutomationSchedule {
  const WeeklyAutomationSchedule({
    required this.hour,
    required this.minute,
    required this.days,
  });

  final int hour;
  final int minute;

  /// Codes from [AutomationSchedule.weekdayCodes]. A rule needs at least one.
  final Set<String> days;

  @override
  String toRrule() {
    // Monday first, whatever order the user tapped them in.
    final ordered = AutomationSchedule.weekdayCodes.where(days.contains);
    return 'RRULE:FREQ=WEEKLY;BYDAY=${ordered.join(',')};'
        'BYHOUR=$hour;BYMINUTE=$minute';
  }

  @override
  bool operator ==(Object other) =>
      other is WeeklyAutomationSchedule &&
      other.hour == hour &&
      other.minute == minute &&
      const SetEquality<String>().equals(other.days, days);

  @override
  int get hashCode =>
      Object.hash(hour, minute, const SetEquality<String>().hash(days));
}

/// A rule this client does not edit with controls, kept exactly as stored.
final class RawAutomationSchedule extends AutomationSchedule {
  const RawAutomationSchedule(this.rrule);

  final String rrule;

  @override
  String toRrule() => rrule;

  @override
  bool operator ==(Object other) =>
      other is RawAutomationSchedule && other.rrule == rrule;

  @override
  int get hashCode => rrule.hashCode;
}

String _pad(int value, [int width = 2]) => value.toString().padLeft(width, '0');

final RegExp _dtstart = RegExp(
  r'^DTSTART:(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})00$',
);
final RegExp _digits = RegExp(r'^\d{1,2}$');

AutomationSchedule? _parse(String rrule) {
  final lines = rrule
      .trim()
      .split(RegExp(r'\s+'))
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) return null;

  String? dtstartLine;
  final ruleLines = <String>[];
  for (final line in lines) {
    if (line.toUpperCase().startsWith('DTSTART')) {
      if (dtstartLine != null) return null;
      dtstartLine = line.toUpperCase();
    } else {
      ruleLines.add(line);
    }
  }
  if (ruleLines.length != 1) return null;

  var body = ruleLines.single.toUpperCase();
  if (body.startsWith('RRULE:')) body = body.substring('RRULE:'.length);
  final parts = <String, String>{};
  for (final part in body.split(';')) {
    final separator = part.indexOf('=');
    if (separator <= 0 || separator == part.length - 1) return null;
    final key = part.substring(0, separator);
    // A repeated key is a rule this client cannot reproduce.
    if (parts.containsKey(key)) return null;
    parts[key] = part.substring(separator + 1);
  }

  final frequency = parts['FREQ'];
  final keys = parts.keys.toSet();

  if (frequency == 'DAILY' && keys.length == 2 && parts['COUNT'] == '1') {
    final match = dtstartLine == null ? null : _dtstart.firstMatch(dtstartLine);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final wall = DateTime(year, month, day, hour, minute);
    // DateTime rolls an impossible date over; such a rule is not one this
    // client wrote, so it stays raw.
    if (wall.year != year ||
        wall.month != month ||
        wall.day != day ||
        wall.hour != hour ||
        wall.minute != minute) {
      return null;
    }
    return OnceAutomationSchedule(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
    );
  }

  // Recurring rules written by the controls carry no DTSTART.
  if (dtstartLine != null) return null;

  final hour = _bounded(parts['BYHOUR'], 23);
  final minute = _bounded(parts['BYMINUTE'], 59);
  if (hour == null || minute == null) return null;

  if (frequency == 'DAILY' &&
      keys.length == 3 &&
      keys.containsAll(const ['BYHOUR', 'BYMINUTE'])) {
    return DailyAutomationSchedule(hour: hour, minute: minute);
  }

  if (frequency == 'WEEKLY' &&
      keys.length == 4 &&
      keys.containsAll(const ['BYDAY', 'BYHOUR', 'BYMINUTE'])) {
    final days = parts['BYDAY']!.split(',');
    final unique = days.toSet();
    if (unique.length != days.length ||
        !AutomationSchedule.weekdayCodes.toSet().containsAll(unique)) {
      return null;
    }
    return WeeklyAutomationSchedule(hour: hour, minute: minute, days: unique);
  }
  return null;
}

int? _bounded(String? value, int max) {
  if (value == null || !_digits.hasMatch(value)) return null;
  final parsed = int.parse(value);
  return parsed <= max ? parsed : null;
}
