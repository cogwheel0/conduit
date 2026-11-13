import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/services/calendar_reminder_scheduler.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/calendar/calendar_reminders.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

const _scope = 'owui:acct-1';
const _otherScope = 'owui:acct-2';
const _me = 'user-me';
const _minuteNs = 60 * 1000 * 1000 * 1000;

final _now = DateTime.utc(2026, 11, 13, 12);
final _nowNs = _now.microsecondsSinceEpoch * 1000;

CalendarEventModel _event(
  String id, {
  int startInMinutes = 60,
  String title = 'Standup',
  Map<String, dynamic>? meta,
}) => CalendarEventModel(
  id: id,
  calendarId: 'cal',
  userId: _me,
  title: title,
  startAtNs: _nowNs + startInMinutes * _minuteNs,
  meta: meta,
);

/// Keeps scheduled reminders in memory, the way the plugin's pending list
/// reports them back.
class _FakeNotifications extends Fake implements LocalNotificationService {
  final scheduled = <ScheduledCalendarReminder>[];
  final scheduledAt = <String, DateTime>{};
  final cancelled = <int>[];
  int _nextId = 100;
  Completer<void>? holdSchedule;

  @override
  Future<List<ScheduledCalendarReminder>> scheduledCalendarReminders() async =>
      List.of(scheduled);

  @override
  Future<bool> scheduleCalendarReminder(
    CalendarReminder reminder, {
    required String scope,
    required String title,
    required String body,
    required bool playSound,
  }) async {
    await holdSchedule?.future;
    scheduled.add(
      ScheduledCalendarReminder(
        id: _nextId++,
        key: reminder.key,
        scope: scope,
        fingerprint: calendarReminderFingerprint(
          reminder,
          title: title,
          body: body,
        ),
      ),
    );
    scheduledAt[reminder.key] = reminder.fireAt;
    return true;
  }

  @override
  Future<void> cancelScheduled(int id) async {
    cancelled.add(id);
    scheduled.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> cancelCalendarReminders({String? scope}) async {
    scheduled.removeWhere((r) => scope == null || r.scope == scope);
  }

  Set<String> keysIn(String scope) => {
    for (final r in scheduled)
      if (r.scope == scope) r.key,
  };
}

class _Harness {
  _Harness() {
    scheduler = CalendarReminderScheduler(
      notifications: notifications,
      settings: () => (enabled: enabled, playSound: true),
      account: () => account,
      fetchAgenda: (start, end) async {
        fetches++;
        lastRange = (start, end);
        final error = fetchError;
        if (error != null) throw error;
        return agenda;
      },
      text: (reminder) => (title: reminder.title, body: 'body'),
      now: () => _now,
    );
  }

  final notifications = _FakeNotifications();
  late final CalendarReminderScheduler scheduler;
  bool enabled = true;
  CalendarReminderAccount? account = (scope: _scope, userId: _me);
  List<CalendarAgendaItem>? agenda = const [];
  Object? fetchError;
  int fetches = 0;
  (DateTime, DateTime)? lastRange;
}

void main() {
  group('CalendarReminderScheduler', () {
    test('schedules the upcoming alerts of the agenda', () async {
      final h = _Harness()
        ..agenda = [
          _event('a', meta: {'alert_minutes': 15}),
          _event('b', startInMinutes: 120),
        ];

      await h.scheduler.sync();

      check(h.notifications.keysIn(_scope)).deepEquals({'a|', 'b|'});
      check(
        h.notifications.scheduledAt['a|'],
      ).equals(_now.add(const Duration(minutes: 45)));
      check(h.lastRange).isNotNull().has((r) => r.$2.difference(r.$1), 'span')
          .equals(calendarReminderHorizon);
    });

    test('keeps a reminder that still matches', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.scheduler.sync();
      final id = h.notifications.scheduled.single.id;

      await h.scheduler.sync();

      check(h.notifications.scheduled.single.id).equals(id);
      check(h.notifications.cancelled).isEmpty();
    });

    test('replaces a reminder whose event moved or was renamed', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.scheduler.sync();
      final id = h.notifications.scheduled.single.id;

      h.agenda = [_event('a', startInMinutes: 90, title: 'Moved')];
      await h.scheduler.sync();

      check(h.notifications.cancelled).deepEquals([id]);
      check(h.notifications.scheduled.single.id).not((it) => it.equals(id));
      check(
        h.notifications.scheduledAt['a|'],
      ).equals(_now.add(const Duration(minutes: 80)));
    });

    test('drops reminders of deleted events and of alerts turned off', () async {
      final h = _Harness()..agenda = [_event('a'), _event('b')];
      await h.scheduler.sync();

      h.agenda = [
        _event('b', meta: {'alert_minutes': -1}),
      ];
      await h.scheduler.sync();

      check(h.notifications.keysIn(_scope)).isEmpty();
    });

    test('leaves the reminders of other accounts alone', () async {
      final h = _Harness()..agenda = [_event('a')];
      h.notifications.scheduled.add(
        const ScheduledCalendarReminder(
          id: 1,
          key: 'other|',
          scope: _otherScope,
          fingerprint: 'x',
        ),
      );

      await h.scheduler.sync();

      check(h.notifications.keysIn(_otherScope)).deepEquals({'other|'});
      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});
    });

    test('turned off, it unschedules every reminder', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.scheduler.sync();

      h.enabled = false;
      await h.scheduler.sync();

      check(h.notifications.scheduled).isEmpty();
      check(h.fetches).equals(1);
    });

    test('without a calendar, the account\'s reminders go', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.scheduler.sync();

      h.agenda = null;
      await h.scheduler.sync();

      check(h.notifications.keysIn(_scope)).isEmpty();
    });

    test('a failed read keeps what is scheduled', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.scheduler.sync();

      h.fetchError = StateError('offline');
      await h.scheduler.sync();

      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});
    });

    test('does nothing before an account is signed in', () async {
      final h = _Harness()
        ..account = null
        ..agenda = [_event('a')];

      await h.scheduler.sync();

      check(h.fetches).equals(0);
      check(h.notifications.scheduled).isEmpty();
    });

    test('an agenda read for an account that switched away is dropped', () async {
      final h = _Harness();
      h.agenda = [_event('a')];
      final scheduler = CalendarReminderScheduler(
        notifications: h.notifications,
        settings: () => (enabled: true, playSound: true),
        account: () => h.account,
        fetchAgenda: (start, end) async {
          h.account = (scope: _otherScope, userId: 'someone-else');
          return h.agenda;
        },
        text: (reminder) => (title: reminder.title, body: 'body'),
        now: () => _now,
      );

      await scheduler.sync();

      check(h.notifications.scheduled).isEmpty();
    });

    test('calls during a sync fold into one more run', () async {
      final h = _Harness()..agenda = [_event('a')];
      final hold = Completer<void>();
      h.notifications.holdSchedule = hold;

      final first = h.scheduler.sync();
      await Future<void>.delayed(Duration.zero);
      final second = h.scheduler.sync();
      final third = h.scheduler.sync();
      hold.complete();
      await Future.wait([first, second, third]);

      check(h.fetches).equals(2);
      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});
    });
  });

  group('calendarReminderText', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final start = DateTime(2026, 11, 13, 14, 30);
    final startNs = start.toUtc().microsecondsSinceEpoch * 1000;

    CalendarReminder reminder({
      String title = 'Standup',
      bool allDay = false,
      String? location,
    }) => CalendarReminder(
      key: 'a|',
      eventId: 'a',
      title: title,
      startAtNs: startNs,
      fireAt: _now,
      allDay: allDay,
      location: location,
    );

    test('says when the event starts, in the device\'s clock style', () {
      check(
        calendarReminderText(reminder(), l10n, use24HourClock: true),
      ).equals((title: 'Standup', body: 'Starts at 14:30'));
      check(
        calendarReminderText(reminder(), l10n, use24HourClock: false).body,
      )
        ..startsWith('Starts at 2:30')
        ..endsWith('PM');
    });

    test('adds the location', () {
      check(
        calendarReminderText(
          reminder(location: ' Room 1 '),
          l10n,
          use24HourClock: true,
        ).body,
      ).equals('Starts at 14:30 · Room 1');
    });

    test('an all-day event says so, an untitled one gets a title', () {
      check(
        calendarReminderText(reminder(title: ' ', allDay: true), l10n),
      ).equals((title: l10n.calendarUntitledEvent, body: l10n.calendarAllDay));
    });
  });

  group('ScheduledCalendarReminder', () {
    test('round-trips through its payload', () {
      final payload = ScheduledCalendarReminder.encode(
        key: 'a|a_1',
        scope: _scope,
        fingerprint: 'f',
      );

      final decoded = ScheduledCalendarReminder.tryDecode(7, payload);

      check(decoded).isNotNull()
        ..has((r) => r.id, 'id').equals(7)
        ..has((r) => r.key, 'key').equals('a|a_1')
        ..has((r) => r.scope, 'scope').equals(_scope)
        ..has((r) => r.fingerprint, 'fingerprint').equals('f');
      // A tap on it opens the app without deep-linking anywhere.
      check(NotificationTap.tryDecode(payload)).isNull();
    });

    test('ignores message notifications and garbage', () {
      check(
        ScheduledCalendarReminder.tryDecode(
          1,
          '{"v":2,"kind":"chat_completion","sourceId":"c","scope":"$_scope"}',
        ),
      ).isNull();
      check(ScheduledCalendarReminder.tryDecode(1, 'not json')).isNull();
      check(
        ScheduledCalendarReminder.tryDecode(
          1,
          '{"calendarReminder":"a|","scope":"nope"}',
        ),
      ).isNull();
    });
  });
}
