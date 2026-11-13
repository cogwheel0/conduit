import 'package:checks/checks.dart';
import 'package:conduit_core/features/calendar/calendar_reminders.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:test/test.dart';

const _me = 'user-me';
const _minuteNs = 60 * 1000 * 1000 * 1000;

final _now = DateTime.utc(2026, 11, 13, 12);
final _nowNs = _now.microsecondsSinceEpoch * 1000;

CalendarEventModel _event(
  String id, {
  required int startInMinutes,
  String userId = _me,
  Map<String, dynamic>? meta,
  bool cancelled = false,
  String? instanceId,
  bool allDay = false,
}) => CalendarEventModel(
  id: id,
  calendarId: 'cal',
  userId: userId,
  title: 'Event $id',
  startAtNs: _nowNs + startInMinutes * _minuteNs,
  meta: meta,
  isCancelled: cancelled,
  instanceId: instanceId,
  allDay: allDay,
  location: 'Room 1',
);

List<CalendarReminder> _plan(
  List<CalendarAgendaItem> items, {
  int limit = calendarReminderLimit,
}) => planCalendarReminders(
  items: items,
  userId: _me,
  now: _now,
  limit: limit,
);

void main() {
  group('calendarAlertMinutes', () {
    test('reads alert_minutes from meta', () {
      check(
        calendarAlertMinutes(
          _event('a', startInMinutes: 60, meta: {'alert_minutes': 30}),
        ),
      ).equals(30);
    });

    test('falls back to the server default when missing or not a number', () {
      check(
        calendarAlertMinutes(_event('a', startInMinutes: 60)),
      ).equals(calendarDefaultAlertMinutes);
      check(
        calendarAlertMinutes(
          _event('a', startInMinutes: 60, meta: {'alert_minutes': '15'}),
        ),
      ).equals(calendarDefaultAlertMinutes);
    });

    test('a negative value means no alert', () {
      check(
        calendarAlertMinutes(
          _event('a', startInMinutes: 60, meta: {'alert_minutes': -1}),
        ),
      ).isNull();
    });

    test('zero alerts at the start and fractions round down', () {
      check(
        calendarAlertMinutes(
          _event('a', startInMinutes: 60, meta: {'alert_minutes': 0}),
        ),
      ).equals(0);
      check(
        calendarAlertMinutes(
          _event('a', startInMinutes: 60, meta: {'alert_minutes': 7.9}),
        ),
      ).equals(7);
    });
  });

  group('planCalendarReminders', () {
    test('alerts alert_minutes before the start', () {
      final plan = _plan([
        _event('a', startInMinutes: 60, meta: {'alert_minutes': 15}),
      ]);

      check(plan).length.equals(1);
      check(plan.single.fireAt).equals(_now.add(const Duration(minutes: 45)));
      check(plan.single.eventId).equals('a');
      check(plan.single.title).equals('Event a');
      check(plan.single.location).equals('Room 1');
    });

    test('uses the default lead time when the event has none', () {
      final plan = _plan([_event('a', startInMinutes: 60)]);

      check(
        plan.single.fireAt,
      ).equals(_now.add(const Duration(minutes: 60 - calendarDefaultAlertMinutes)));
    });

    test('an alert time that already passed is due now', () {
      final plan = _plan([
        _event('a', startInMinutes: 5, meta: {'alert_minutes': 30}),
      ]);

      check(plan.single.fireAt).equals(_now);
    });

    test('skips events that started, were cancelled or have no alert', () {
      final plan = _plan([
        _event('started', startInMinutes: -1),
        _event('cancelled', startInMinutes: 60, cancelled: true),
        _event('silent', startInMinutes: 60, meta: {'alert_minutes': -1}),
      ]);

      check(plan).isEmpty();
    });

    test('an event starting right now is still alerted', () {
      final plan = _plan([
        _event('a', startInMinutes: 0, meta: {'alert_minutes': 0}),
      ]);

      check(plan.single.fireAt).equals(_now);
    });

    test('only the account\'s own events, as the server alerts the organizer', () {
      final plan = _plan([
        _event('mine', startInMinutes: 60),
        _event('invited', startInMinutes: 60, userId: 'someone-else'),
      ]);

      check(plan.map((r) => r.eventId)).deepEquals(['mine']);
    });

    test('scheduled-task entries are not events and get no reminder', () {
      final plan = _plan([
        ScheduledTaskCalendarEntry(
          id: 'task',
          title: 'Task',
          startAtNs: _nowNs + 60 * _minuteNs,
        ),
      ]);

      check(plan).isEmpty();
    });

    test('each occurrence of a recurring event gets its own reminder', () {
      final plan = _plan([
        _event('series', startInMinutes: 60, instanceId: 'series_1'),
        _event('series', startInMinutes: 60 * 25, instanceId: 'series_2'),
      ]);

      check(plan.map((r) => r.key)).deepEquals([
        'series|series_1',
        'series|series_2',
      ]);
    });

    test('a duplicate agenda entry is planned once', () {
      final plan = _plan([
        _event('a', startInMinutes: 60),
        _event('a', startInMinutes: 60),
      ]);

      check(plan).length.equals(1);
    });

    test('keeps the soonest reminders up to the limit', () {
      final plan = _plan([
        _event('late', startInMinutes: 300),
        _event('soon', startInMinutes: 30),
        _event('middle', startInMinutes: 120),
      ], limit: 2);

      check(plan.map((r) => r.eventId)).deepEquals(['soon', 'middle']);
    });

    test('carries all-day events through', () {
      final plan = _plan([_event('a', startInMinutes: 600, allDay: true)]);

      check(plan.single.allDay).isTrue();
    });
  });
}
