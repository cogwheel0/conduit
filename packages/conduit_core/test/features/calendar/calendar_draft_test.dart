import 'package:checks/checks.dart';
import 'package:conduit_core/features/calendar/calendar_draft.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:test/test.dart';

/// UTC-4 all year, so every expected instant below is plain arithmetic.
final class _Zone implements CalendarZone {
  const _Zone();

  @override
  Duration offsetAt(DateTime utcInstant) => const Duration(hours: -4);
}

const _zone = _Zone();

// 2026-10-06 17:09:27.123456789 in UTC-4, an hour long.
const _startNs = 1791320967123456789;
const _endNs = 1791324567987654321;

CalendarEventModel _stored({
  bool allDay = false,
  int startAtNs = _startNs,
  int? endAtNs = _endNs,
  String? rrule,
  List<Map<String, dynamic>> attendees = const [],
}) => CalendarEventModel.tryFromJson({
  'id': 'event-1',
  'calendar_id': 'cal-1',
  'user_id': 'user-1',
  'title': 'Planning',
  'description': 'Quarterly',
  'location': 'Room 4',
  'start_at': startAtNs,
  'end_at': endAtNs,
  'all_day': allDay,
  'rrule': rrule,
  'attendees': attendees,
})!;

Map<String, dynamic> _attendee(String user, {Map<String, dynamic>? meta}) => {
  'id': 'att-$user',
  'event_id': 'event-1',
  'user_id': user,
  'status': 'accepted',
  'meta': meta,
};

CalendarWallTime _wall(int y, int m, int d, [int h = 0, int min = 0]) =>
    CalendarWallTime(y, m, d, h, min);

void main() {
  group('an edit sends only what changed', () {
    test('an untouched draft sends nothing', () {
      final draft = CalendarEventDraft.edit(_stored(), zone: _zone);

      check(draft.toUpdate(zone: _zone).isEmpty).isTrue();
      check(draft.isChanged(zone: _zone)).isFalse();
    });

    test('a title edit leaves the start and end nanoseconds unsent', () {
      final draft = CalendarEventDraft.edit(
        _stored(),
        zone: _zone,
      ).copyWith(title: ' Renamed ');

      check(draft.toUpdate(zone: _zone).toJson())
          .deepEquals({'title': 'Renamed'});
    });

    test('a date picker opened and cancelled is not an edit', () {
      final draft = CalendarEventDraft.edit(_stored(), zone: _zone);
      // The picker hands back the wall clock the field already showed.
      final reopened = draft.copyWith(
        start: wallTimeAt(_startNs, _zone),
        end: wallTimeAt(_endNs, _zone),
      );

      check(reopened.toUpdate(zone: _zone).isEmpty).isTrue();
    });

    test('an edited start is the minute chosen and the end stays exact', () {
      final draft = CalendarEventDraft.edit(
        _stored(),
        zone: _zone,
      ).copyWith(start: _wall(2026, 10, 6, 16, 30));

      // 16:30 at UTC-4 is 20:30Z.
      check(draft.toUpdate(zone: _zone).toJson())
          .deepEquals({'start_at': 1791318600000000000});
    });

    test('moving the event names only the destination calendar', () {
      final draft = CalendarEventDraft.edit(
        _stored(),
        zone: _zone,
      ).copyWith(calendarId: 'cal-2');

      check(draft.toUpdate(zone: _zone).toJson())
          .deepEquals({'calendar_id': 'cal-2'});
      check(draft.toUpdate(zone: _zone).destinationCalendarId).equals('cal-2');
    });

    test('clearing the description or location sends null', () {
      final draft = CalendarEventDraft.edit(
        _stored(),
        zone: _zone,
      ).copyWith(description: '  ', location: '');

      check(draft.toUpdate(zone: _zone).toJson())
          .deepEquals({'description': null, 'location': null});
    });
  });

  group('recurrence', () {
    test('a rule the editor does not write is kept until another repeat is '
        'chosen', () {
      const rule = 'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU';
      final draft = CalendarEventDraft.edit(_stored(rrule: rule), zone: _zone);

      check(draft.repeat).equals(CalendarRepeat.custom);
      check(draft.copyWith(title: 'x').toUpdate(zone: _zone).toJson())
          .deepEquals({'title': 'x'});
      check(
        draft
            .copyWith(repeat: CalendarRepeat.daily)
            .toUpdate(zone: _zone)
            .toJson(),
      ).deepEquals({'rrule': 'FREQ=DAILY'});
      check(
        draft
            .copyWith(repeat: CalendarRepeat.none)
            .toUpdate(zone: _zone)
            .toJson(),
      ).deepEquals({'rrule': null});
    });

    test('a rule the editor wrote reads back as the same choice and is not '
        'resent', () {
      final draft = CalendarEventDraft.edit(
        _stored(rrule: ' freq=weekly;byday=mo,tu,we,th,fr '),
        zone: _zone,
      );

      check(draft.repeat).equals(CalendarRepeat.weekdays);
      check(draft.toUpdate(zone: _zone).isEmpty).isTrue();
    });
  });

  group('attendees', () {
    final stored = _stored(
      attendees: [
        _attendee('user-2', meta: {'role': 'optional'}),
        _attendee('user-3'),
      ],
    );

    test('an unchanged list is left out of the update', () {
      final draft = CalendarEventDraft.edit(stored, zone: _zone);

      check(draft.copyWith(title: 'x').toUpdate(zone: _zone).toJson())
          .deepEquals({'title': 'x'});
    });

    test('a changed list replaces the people, keeps their data and sends no '
        'status', () {
      final draft = CalendarEventDraft.edit(stored, zone: _zone);

      final edited = draft.copyWith(
        attendees: [
          draft.attendees.first,
          const CalendarDraftAttendee(userId: 'user-4'),
        ],
      );

      check(edited.toUpdate(zone: _zone).toJson()).deepEquals({
        'attendees': [
          {
            'user_id': 'user-2',
            'meta': {'role': 'optional'},
          },
          {'user_id': 'user-4'},
        ],
      });
    });

    test('reordering the same people changes nothing', () {
      final draft = CalendarEventDraft.edit(stored, zone: _zone);

      check(
        draft
            .copyWith(attendees: draft.attendees.reversed.toList())
            .toUpdate(zone: _zone)
            .isEmpty,
      ).isTrue();
    });
  });

  group('all-day events', () {
    // 2026-10-12 00:00 to 2026-10-14 23:59 at UTC-4.
    final allDay = _stored(
      allDay: true,
      startAtNs: 1791777600000000000,
      endAtNs: 1792036740000000000,
    );

    test('show the last day they cover', () {
      final draft = CalendarEventDraft.edit(allDay, zone: _zone);

      check(draft.start).equals(_wall(2026, 10, 12));
      check(draft.end).equals(_wall(2026, 10, 14, 23, 59).dateOnly);
    });

    test('changing the last day writes 23:59 of that day', () {
      final draft = CalendarEventDraft.edit(
        allDay,
        zone: _zone,
      ).copyWith(end: _wall(2026, 10, 16));

      // 2026-10-16 23:59 at UTC-4.
      check(draft.toUpdate(zone: _zone).toJson())
          .deepEquals({'end_at': 1792209540000000000});
    });

    test(
      'turning a timed event all-day sends midnight and the last minute',
      () {
        final draft = CalendarEventDraft.edit(
          _stored(),
          zone: _zone,
        ).copyWith(allDay: true);

        check(draft.toUpdate(zone: _zone).toJson()).deepEquals({
          'all_day': true,
          // 2026-10-06 00:00 and 23:59 at UTC-4.
          'start_at': 1791259200000000000,
          'end_at': 1791345540000000000,
        });
      },
    );
  });

  group('a new event', () {
    test('sends the trimmed fields it has and leaves the rest out', () {
      final draft = CalendarEventDraft.create(
        calendarId: 'cal-1',
        start: _wall(2026, 10, 6, 9, 30),
      ).copyWith(title: '  Standup ', location: ' ');

      // 09:30 and 10:30 at UTC-4.
      check(draft.toCreateForm(zone: _zone).toJson()).deepEquals({
        'calendar_id': 'cal-1',
        'title': 'Standup',
        'start_at': 1791293400000000000,
        'end_at': 1791297000000000000,
        'all_day': false,
      });
    });

    test('carries chosen people without a status', () {
      final draft =
          CalendarEventDraft.create(
            calendarId: 'cal-1',
            start: _wall(2026, 10, 6, 9, 30),
          ).copyWith(
            title: 'x',
            repeat: CalendarRepeat.weekly,
            attendees: const [CalendarDraftAttendee(userId: 'user-2')],
          );

      final json = draft.toCreateForm(zone: _zone).toJson();
      check(json['rrule']).equals('FREQ=WEEKLY');
      check(json['attendees']).isA<List<Map<String, dynamic>>>().deepEquals([
        {'user_id': 'user-2'},
      ]);
    });
  });

  group('issues', () {
    final base = CalendarEventDraft.create(
      calendarId: 'cal-1',
      start: _wall(2026, 10, 6, 9, 30),
    );

    test('a blank title, no calendar, and an end before the start', () {
      check(base.issues).deepEquals([CalendarDraftIssue.titleRequired]);
      check(base.copyWith(title: 'x').issues).isEmpty();
      check(base.copyWith(title: 'x', calendarId: '').issues)
          .deepEquals([CalendarDraftIssue.calendarRequired]);
      check(base.copyWith(title: 'x', end: _wall(2026, 10, 6, 9, 0)).issues)
          .deepEquals([CalendarDraftIssue.endBeforeStart]);
    });

    test('an all-day event may end on its start day', () {
      check(
        base.copyWith(title: 'x', allDay: true, end: _wall(2026, 10, 6)).issues,
      ).isEmpty();
    });
  });
}
