import 'package:meta/meta.dart';

/// Calendar time arithmetic.
///
/// The server stores every instant as integer epoch **nanoseconds**, and a
/// nanosecond epoch is larger than a double holds exactly. Everything here
/// converts with integer arithmetic, and only reaches for [DateTime] at
/// microsecond precision to read calendar fields.
///
/// The user chose the device's time zone for showing and editing events, so a
/// [CalendarZone] is the device by default. The server's own recurrence
/// expansion is separate and runs in the account's time zone; nothing here
/// expands a recurrence.

const int nanosPerMicrosecond = 1000;
const int nanosPerMillisecond = 1000000;
const int nanosPerSecond = 1000000000;
const int nanosPerMinute = 60 * nanosPerSecond;

/// A time zone, as far as the calendar needs one: how far local time is from
/// UTC at an instant.
abstract interface class CalendarZone {
  /// Local time minus UTC at [utcInstant].
  Duration offsetAt(DateTime utcInstant);
}

/// The device's own zone.
final class DeviceCalendarZone implements CalendarZone {
  const DeviceCalendarZone();

  @override
  Duration offsetAt(DateTime utcInstant) =>
      utcInstant.toUtc().toLocal().timeZoneOffset;
}

/// A calendar date and a minute-resolution wall clock, with no zone attached.
///
/// This is what a date and time picker holds. Seconds and finer are not part of
/// it, which is why an unedited instant is kept as its original nanoseconds
/// rather than being rebuilt from one of these.
@immutable
class CalendarWallTime implements Comparable<CalendarWallTime> {
  const CalendarWallTime(
    this.year,
    this.month,
    this.day, [
    this.hour = 0,
    this.minute = 0,
  ]);

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;

  /// The same fields as a UTC [DateTime], which only carries them: the zone is
  /// not UTC.
  DateTime get fields => DateTime.utc(year, month, day, hour, minute);

  factory CalendarWallTime.fromFields(DateTime fields) => CalendarWallTime(
    fields.year,
    fields.month,
    fields.day,
    fields.hour,
    fields.minute,
  );

  CalendarWallTime get dateOnly => CalendarWallTime(year, month, day);

  /// This date [days] later (or earlier), at the same wall clock.
  CalendarWallTime addDays(int days) {
    final shifted = DateTime.utc(year, month, day + days, hour, minute);
    return CalendarWallTime.fromFields(shifted);
  }

  bool sameDate(CalendarWallTime other) =>
      year == other.year && month == other.month && day == other.day;

  bool get isMidnight => hour == 0 && minute == 0;

  @override
  int compareTo(CalendarWallTime other) => fields.compareTo(other.fields);

  @override
  bool operator ==(Object other) =>
      other is CalendarWallTime &&
      other.year == year &&
      other.month == month &&
      other.day == day &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(year, month, day, hour, minute);

  @override
  String toString() =>
      '$year-${_two(month)}-${_two(day)}T${_two(hour)}:${_two(minute)}';
}

/// Floor division, so an instant before 1970 rounds toward the past.
int floorDiv(int value, int divisor) {
  final quotient = value ~/ divisor;
  return (value % divisor != 0 && (value < 0) != (divisor < 0))
      ? quotient - 1
      : quotient;
}

/// [nanoseconds] as a UTC [DateTime], at the microsecond precision it holds.
DateTime instantFromNanoseconds(int nanoseconds) =>
    DateTime.fromMicrosecondsSinceEpoch(
      floorDiv(nanoseconds, nanosPerMicrosecond),
      isUtc: true,
    );

/// The wall clock [zone] shows at [nanoseconds], to the minute.
CalendarWallTime wallTimeAt(int nanoseconds, CalendarZone zone) {
  final instant = instantFromNanoseconds(nanoseconds);
  return CalendarWallTime.fromFields(instant.add(zone.offsetAt(instant)));
}

/// The instant [wall] is in [zone], as epoch nanoseconds, with whole seconds.
///
/// A wall clock can name two instants (the hour that repeats when clocks go
/// back) or none (the hour that is skipped when they go forward). The first
/// occurrence wins in the first case. In the second the clock is read with the
/// offset that was in force before the change, so 02:30 on a spring-forward
/// night is 03:30, as a phone's own calendar shows it.
int nanosecondsFromWallTime(CalendarWallTime wall, CalendarZone zone) {
  final fieldsMs = wall.fields.millisecondsSinceEpoch;
  const day = Duration(days: 1);
  final before = zone.offsetAt(wall.fields.subtract(day));
  final after = zone.offsetAt(wall.fields.add(day));

  bool holds(Duration offset) {
    final instant = DateTime.fromMillisecondsSinceEpoch(
      fieldsMs - offset.inMilliseconds,
      isUtc: true,
    );
    return zone.offsetAt(instant) == offset;
  }

  final candidates = <Duration>[
    if (holds(before)) before,
    if (after != before && holds(after)) after,
  ];
  final int offsetMs;
  if (candidates.isEmpty) {
    offsetMs = before.inMilliseconds;
  } else {
    // The larger offset is the earlier instant.
    candidates.sort((a, b) => b.compareTo(a));
    offsetMs = candidates.first.inMilliseconds;
  }
  return (fieldsMs - offsetMs) * nanosPerMillisecond;
}

/// The instant to send for an edited field.
///
/// An unedited field keeps [originalNanoseconds] exactly. A date picker that
/// was opened and cancelled, or a wall clock set back to what it showed, is not
/// an edit, so it must not round the stored instant to the minute.
int resolveEditedNanoseconds({
  required int originalNanoseconds,
  required CalendarWallTime edited,
  required CalendarZone zone,
}) {
  if (wallTimeAt(originalNanoseconds, zone) == edited) {
    return originalNanoseconds;
  }
  return nanosecondsFromWallTime(edited, zone);
}

/// `yyyy-MM-ddTHH:mm:ss+HH:MM` for [nanoseconds] as [zone] shows it, the form
/// the agenda route accepts for a range bound.
String isoWithOffset(int nanoseconds, CalendarZone zone) {
  final instant = instantFromNanoseconds(nanoseconds);
  final offset = zone.offsetAt(instant);
  final local = instant.add(offset);
  final totalMinutes = offset.inMinutes;
  final sign = totalMinutes < 0 ? '-' : '+';
  final absolute = totalMinutes.abs();
  return '${local.year.toString().padLeft(4, '0')}-${_two(local.month)}-'
      '${_two(local.day)}T${_two(local.hour)}:${_two(local.minute)}:'
      '${_two(local.second)}$sign${_two(absolute ~/ 60)}:${_two(absolute % 60)}';
}

/// A bounded stretch of whole days, as [zone] counts them.
@immutable
class CalendarRange {
  CalendarRange.days(
    CalendarWallTime firstDay,
    this.dayCount, {
    required CalendarZone zone,
  }) : assert(dayCount > 0),
       firstDay = firstDay.dateOnly,
       startNs = nanosecondsFromWallTime(firstDay.dateOnly, zone),
       endNs = nanosecondsFromWallTime(
         firstDay.dateOnly.addDays(dayCount),
         zone,
       ),
       startIso = isoWithOffset(
         nanosecondsFromWallTime(firstDay.dateOnly, zone),
         zone,
       ),
       endIso = isoWithOffset(
         nanosecondsFromWallTime(firstDay.dateOnly.addDays(dayCount), zone),
         zone,
       );

  final CalendarWallTime firstDay;
  final int dayCount;

  /// The range as nanoseconds, start inclusive and end exclusive.
  final int startNs;
  final int endNs;

  /// The same bounds as the route's `start` and `end` query values.
  final String startIso;
  final String endIso;

  /// The day after the last one in the range.
  CalendarWallTime get endDay => firstDay.addDays(dayCount);

  CalendarRange shifted(int days, {required CalendarZone zone}) =>
      CalendarRange.days(firstDay.addDays(days), dayCount, zone: zone);

  @override
  bool operator ==(Object other) =>
      other is CalendarRange &&
      other.firstDay == firstDay &&
      other.dayCount == dayCount &&
      other.startNs == startNs &&
      other.endNs == endNs;

  @override
  int get hashCode => Object.hash(firstDay, dayCount, startNs, endNs);
}

/// The first and last calendar day an item touches in [zone].
///
/// An end that falls exactly on midnight of a later day ends the day before it,
/// so a span written as `[start, next midnight)` does not spill onto an extra
/// day. Open WebUI's own editor ends an all-day event at 23:59 of its last day,
/// which lands on that day either way.
({CalendarWallTime first, CalendarWallTime last}) daySpan({
  required int startNs,
  int? endNs,
  required CalendarZone zone,
}) {
  final first = wallTimeAt(startNs, zone);
  final firstDay = first.dateOnly;
  if (endNs == null || endNs <= startNs) {
    return (first: firstDay, last: firstDay);
  }
  final end = wallTimeAt(endNs, zone);
  var last = end.dateOnly;
  if (end.isMidnight &&
      endNs % nanosPerMinute == 0 &&
      last.compareTo(firstDay) > 0) {
    last = last.addDays(-1);
  }
  return (first: firstDay, last: last);
}

/// Every day of [span] that falls inside [range], in order.
List<CalendarWallTime> daysInRange(
  ({CalendarWallTime first, CalendarWallTime last}) span,
  CalendarRange range,
) {
  final days = <CalendarWallTime>[];
  // A long event can start long before the range; begin where it enters.
  var day = span.first.compareTo(range.firstDay) < 0
      ? range.firstDay
      : span.first;
  final limit = range.endDay;
  while (day.compareTo(span.last) <= 0 && day.compareTo(limit) < 0) {
    days.add(day);
    day = day.addDays(1);
  }
  return days;
}

String _two(int value) => value.toString().padLeft(2, '0');
