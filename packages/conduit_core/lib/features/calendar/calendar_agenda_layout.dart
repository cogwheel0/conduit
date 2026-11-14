import 'package:meta/meta.dart';

import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';

/// How an agenda is laid out, shared by every host: which days have
/// something on them, what a row's time says on a given day, and which
/// calendars the agenda shows.

/// One day of the agenda and what is on it, in the agenda's order.
@immutable
final class CalendarAgendaDay {
  const CalendarAgendaDay(this.day, this.items);

  /// The calendar day, with no wall clock.
  final CalendarWallTime day;
  final List<CalendarAgendaItem> items;
}

/// The days of [range] that have something on them, in order, each with the
/// items that touch it. An item spanning several days is listed on each of
/// them that falls inside [range]; a scheduled-task entry is a moment, so it
/// sits on the day it starts.
List<CalendarAgendaDay> groupAgendaByDay(
  Iterable<CalendarAgendaItem> items,
  CalendarRange range,
  CalendarZone zone,
) {
  final byDay = <CalendarWallTime, List<CalendarAgendaItem>>{};
  for (final item in items) {
    final span = switch (item) {
      CalendarEventModel() => daySpan(
        startNs: item.startAtNs,
        endNs: item.endAtNs,
        zone: zone,
      ),
      ScheduledTaskCalendarEntry() => daySpan(
        startNs: item.startAtNs,
        zone: zone,
      ),
    };
    for (final day in daysInRange(span, range)) {
      byDay.putIfAbsent(day, () => <CalendarAgendaItem>[]).add(item);
    }
  }
  final days = byDay.keys.toList()..sort();
  return [
    for (final day in days)
      CalendarAgendaDay(
        day,
        List<CalendarAgendaItem>.unmodifiable(byDay[day]!),
      ),
  ];
}

/// What an agenda row says about its time on one day.
sealed class CalendarRowTime {
  const CalendarRowTime();
}

/// All day: an all-day event, or a day in the middle of a longer one.
final class CalendarRowAllDay extends CalendarRowTime {
  const CalendarRowAllDay();

  @override
  bool operator ==(Object other) => other is CalendarRowAllDay;

  @override
  int get hashCode => 0;
}

/// A moment with no end: a scheduled task, or an event without one.
final class CalendarRowAt extends CalendarRowTime {
  const CalendarRowAt(this.start);

  final CalendarWallTime start;

  @override
  bool operator ==(Object other) =>
      other is CalendarRowAt && other.start == start;

  @override
  int get hashCode => start.hashCode;
}

/// A start and an end on the same day.
final class CalendarRowRange extends CalendarRowTime {
  const CalendarRowRange(this.start, this.end);

  final CalendarWallTime start;
  final CalendarWallTime end;

  @override
  bool operator ==(Object other) =>
      other is CalendarRowRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// The first day of an event that runs past midnight.
final class CalendarRowStartsAt extends CalendarRowTime {
  const CalendarRowStartsAt(this.start);

  final CalendarWallTime start;

  @override
  bool operator ==(Object other) =>
      other is CalendarRowStartsAt && other.start == start;

  @override
  int get hashCode => start.hashCode;
}

/// The last day of an event that began on an earlier day.
final class CalendarRowEndsAt extends CalendarRowTime {
  const CalendarRowEndsAt(this.end);

  final CalendarWallTime end;

  @override
  bool operator ==(Object other) =>
      other is CalendarRowEndsAt && other.end == end;

  @override
  int get hashCode => end.hashCode;
}

/// What a row on [day] says about an item's time: the clock for a short
/// event, where a long one starts or ends on its first or last day, and "all
/// day" for the days between and for an all-day event.
CalendarRowTime calendarRowTime({
  required int startNs,
  required int? endNs,
  required bool allDay,
  required CalendarZone zone,
  required CalendarWallTime day,
}) {
  if (allDay) return const CalendarRowAllDay();
  final start = wallTimeAt(startNs, zone);
  if (endNs == null || endNs <= startNs) return CalendarRowAt(start);
  final end = wallTimeAt(endNs, zone);
  final span = daySpan(startNs: startNs, endNs: endNs, zone: zone);
  if (span.first.sameDate(span.last)) return CalendarRowRange(start, end);
  if (day.sameDate(span.first)) return CalendarRowStartsAt(start);
  if (day.sameDate(span.last) && day.sameDate(end)) {
    return CalendarRowEndsAt(end);
  }
  return const CalendarRowAllDay();
}

/// The calendars the agenda shows: the ones [filter] names that still exist,
/// or every calendar when it names none of them. [filter] is the agenda's own
/// filter unless a host is showing a newer choice while the agenda reloads.
Set<String> calendarVisibleIds(CalendarAgendaData data, {Set<String>? filter}) {
  final all = {for (final calendar in data.calendars) calendar.id};
  final chosen = (filter ?? data.filter).intersection(all);
  return chosen.isEmpty ? all : chosen;
}

/// The filter that shows or hides [calendarId]'s events, or null when the
/// change is refused: at least one calendar stays shown. Showing every
/// calendar clears the filter, so a calendar added later shows too.
Set<String>? toggledCalendarFilter(
  CalendarAgendaData data,
  String calendarId, {
  Set<String>? filter,
}) {
  final all = {for (final calendar in data.calendars) calendar.id};
  final next = {...calendarVisibleIds(data, filter: filter)};
  if (!next.remove(calendarId)) next.add(calendarId);
  if (next.isEmpty) return null;
  return next.containsAll(all) ? <String>{} : next;
}

/// Whether the agenda's calendars can be shown and hidden at all: there has
/// to be more than one.
bool calendarsFilterable(CalendarAgendaData data) => data.calendars.length > 1;

/// The calendar a new event starts in: the account's default, else the first
/// it can write to, or null when it can write to none.
String? calendarDefaultCalendarId(CalendarAgendaData? data) {
  final access = data?.access;
  if (data == null || access == null) return null;
  final writable = data.writableCalendars;
  final preferred = access.defaultCalendar(writable);
  return (preferred ?? (writable.isEmpty ? null : writable.first))?.id;
}

/// When a new event starts: the next whole hour when it is made for today
/// (or for no day in particular), 9:00 on any other [day]. [now] is the wall
/// clock now, in the zone the event is edited in.
CalendarWallTime calendarDefaultStart({
  CalendarWallTime? day,
  required CalendarWallTime now,
}) {
  if (day == null || day.sameDate(now)) {
    return CalendarWallTime.fromFields(
      DateTime.utc(now.year, now.month, now.day, now.hour + 1),
    );
  }
  return CalendarWallTime(day.year, day.month, day.day, 9);
}
