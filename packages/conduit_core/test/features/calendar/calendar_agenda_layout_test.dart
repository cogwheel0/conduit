import 'package:checks/checks.dart';
import 'package:conduit_core/features/calendar/calendar_agenda_layout.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:test/test.dart';

/// A fixed UTC offset, so the layout does not depend on the machine's zone.
final class _Fixed implements CalendarZone {
  const _Fixed(this.offset);

  final Duration offset;

  @override
  Duration offsetAt(DateTime utcInstant) => offset;
}

const _zone = _Fixed(Duration(hours: 2));

int _at(int y, int m, int d, [int h = 0, int min = 0]) =>
    nanosecondsFromWallTime(CalendarWallTime(y, m, d, h, min), _zone);

CalendarEventModel _event(
  String id, {
  required int start,
  int? end,
  bool allDay = false,
  String calendarId = 'cal',
}) => CalendarEventModel(
  id: id,
  calendarId: calendarId,
  userId: 'u1',
  title: id,
  startAtNs: start,
  endAtNs: end,
  allDay: allDay,
);

CalendarModel _calendar(String id) =>
    CalendarModel(id: id, userId: 'u1', name: id);

void main() {
  final range = CalendarRange.days(
    const CalendarWallTime(2026, 3, 10),
    3,
    zone: _zone,
  );

  group('groupAgendaByDay', () {
    test('lists each day that has something on it, in order', () {
      final lunch = _event(
        'lunch',
        start: _at(2026, 3, 11, 12),
        end: _at(2026, 3, 11, 13),
      );
      final breakfast = _event(
        'breakfast',
        start: _at(2026, 3, 10, 8),
        end: _at(2026, 3, 10, 9),
      );
      final days = groupAgendaByDay([breakfast, lunch], range, _zone);
      check(days.map((d) => d.day)).deepEquals([
        const CalendarWallTime(2026, 3, 10),
        const CalendarWallTime(2026, 3, 11),
      ]);
      check(days.first.items.single).equals(breakfast);
    });

    test('puts a long event on each of its days inside the range', () {
      final trip = _event(
        'trip',
        start: _at(2026, 3, 9, 18),
        end: _at(2026, 3, 11, 10),
      );
      final days = groupAgendaByDay([trip], range, _zone);
      check(days.map((d) => d.day)).deepEquals([
        const CalendarWallTime(2026, 3, 10),
        const CalendarWallTime(2026, 3, 11),
      ]);
    });

    test('puts a scheduled task on the day it starts', () {
      final entry = ScheduledTaskCalendarEntry(
        id: 'auto_1',
        title: 'Digest',
        startAtNs: _at(2026, 3, 12, 9),
      );
      final days = groupAgendaByDay([entry], range, _zone);
      check(days.single.day).equals(const CalendarWallTime(2026, 3, 12));
    });
  });

  group('calendarRowTime', () {
    const day = CalendarWallTime(2026, 3, 10);

    test('an all-day event reads all day', () {
      check(
        calendarRowTime(
          startNs: _at(2026, 3, 10),
          endNs: _at(2026, 3, 10, 23, 59),
          allDay: true,
          zone: _zone,
          day: day,
        ),
      ).isA<CalendarRowAllDay>();
    });

    test('an event without an end is a moment', () {
      check(
        calendarRowTime(
          startNs: _at(2026, 3, 10, 9, 30),
          endNs: null,
          allDay: false,
          zone: _zone,
          day: day,
        ),
      ).equals(const CalendarRowAt(CalendarWallTime(2026, 3, 10, 9, 30)));
    });

    test('a same-day event is a range', () {
      check(
        calendarRowTime(
          startNs: _at(2026, 3, 10, 9),
          endNs: _at(2026, 3, 10, 10),
          allDay: false,
          zone: _zone,
          day: day,
        ),
      ).equals(
        const CalendarRowRange(
          CalendarWallTime(2026, 3, 10, 9),
          CalendarWallTime(2026, 3, 10, 10),
        ),
      );
    });

    test('a long event starts, runs all day, then ends', () {
      final start = _at(2026, 3, 10, 20);
      final end = _at(2026, 3, 12, 7);
      CalendarRowTime on(CalendarWallTime d) => calendarRowTime(
        startNs: start,
        endNs: end,
        allDay: false,
        zone: _zone,
        day: d,
      );
      check(on(day))
          .equals(const CalendarRowStartsAt(CalendarWallTime(2026, 3, 10, 20)));
      check(on(const CalendarWallTime(2026, 3, 11))).isA<CalendarRowAllDay>();
      check(on(const CalendarWallTime(2026, 3, 12)))
          .equals(const CalendarRowEndsAt(CalendarWallTime(2026, 3, 12, 7)));
    });
  });

  group('calendar visibility', () {
    final data = CalendarAgendaData(
      range: range,
      calendars: [_calendar('a'), _calendar('b'), _calendar('c')],
    );

    test('an empty filter shows every calendar', () {
      check(calendarVisibleIds(data)).deepEquals({'a', 'b', 'c'});
    });

    test('a filter naming only gone calendars shows every calendar', () {
      check(calendarVisibleIds(data, filter: {'gone'}))
          .deepEquals({'a', 'b', 'c'});
    });

    test('hiding one calendar keeps the others', () {
      check(toggledCalendarFilter(data, 'b'))
          .isNotNull()
          .deepEquals({'a', 'c'});
    });

    test('the last shown calendar cannot be hidden', () {
      check(toggledCalendarFilter(data, 'a', filter: {'a'})).isNull();
    });

    test('showing every calendar again clears the filter', () {
      check(toggledCalendarFilter(data, 'b', filter: {'a', 'c'}))
          .isNotNull()
          .isEmpty();
    });

    test('one calendar cannot be filtered', () {
      check(
        calendarsFilterable(
          CalendarAgendaData(range: range, calendars: [_calendar('a')]),
        ),
      ).isFalse();
      check(calendarsFilterable(data)).isTrue();
    });
  });
}
