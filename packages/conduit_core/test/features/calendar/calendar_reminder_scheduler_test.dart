import 'dart:async';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:conduit_core/features/calendar/calendar_reminder_scheduler.dart';
import 'package:conduit_core/features/calendar/calendar_reminders.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:test/test.dart';

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
/// reports them back, and refuses a time that is not in the future, as
/// flutter_local_notifications does.
class _FakeNotifications implements CalendarReminderPort {
  final scheduled = <ScheduledCalendarReminder>[];
  final scheduledAt = <String, DateTime>{};
  final cancelled = <int>[];

  /// Reminders the user saw: posted at once, or fired from the schedule.
  final delivered = <String>[];

  /// The posted reminders still in the notification list, by account.
  final onScreen = <({String scope, String key})>{};

  /// Reminders handed to the plugin with a time that had passed.
  final rejected = <String>[];
  int _nextId = 100;
  /// Holds the next schedule or post call until completed.
  Completer<void>? holdSchedule;
  final enteredSchedule = Completer<void>();
  bool exactAllowed = false;
  final exactByKey = <String, bool>{};
  final soundByKey = <String, bool>{};

  @override
  Future<bool> canScheduleExactReminders() async => exactAllowed;

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
    required bool exact,
  }) async {
    if (!enteredSchedule.isCompleted) enteredSchedule.complete();
    await holdSchedule?.future;
    if (!reminder.fireAt.isAfter(clock.now())) {
      rejected.add(reminder.key);
      return false;
    }
    scheduled.add(
      ScheduledCalendarReminder(
        id: _nextId++,
        key: reminder.key,
        scope: scope,
        fireAt: reminder.fireAt,
        fingerprint: calendarReminderFingerprint(
          reminder,
          title: title,
          body: body,
          exact: exact,
          playSound: playSound,
        ),
      ),
    );
    scheduledAt[reminder.key] = reminder.fireAt;
    exactByKey[reminder.key] = exact;
    soundByKey[reminder.key] = playSound;
    return true;
  }

  @override
  Future<bool> postCalendarReminder(
    CalendarReminder reminder, {
    required String scope,
    required String title,
    required String body,
    required bool playSound,
  }) async {
    if (!enteredSchedule.isCompleted) enteredSchedule.complete();
    await holdSchedule?.future;
    delivered.add(reminder.key);
    onScreen.add((scope: scope, key: reminder.key));
    return true;
  }

  @override
  Future<void> cancelScope(String scope) async {
    onScreen.removeWhere((posted) => posted.scope == scope);
  }

  /// What the OS does once a scheduled reminder is due at [now]: posts it and
  /// drops it from the pending list.
  void fireDue(DateTime now) {
    scheduled.removeWhere((r) {
      if (scheduledAt[r.key]!.isAfter(now)) return false;
      delivered.add(r.key);
      return true;
    });
  }

  @override
  Future<void> cancelScheduled(int id) async {
    cancelled.add(id);
    scheduled.removeWhere((r) => r.id == id);
  }

  Set<String> keysIn(String scope) => {
    for (final r in scheduled)
      if (r.scope == scope) r.key,
  };
}

class _Harness {
  _Harness() {
    restart();
  }

  /// A new scheduler over the same device, as after the app restarts.
  void restart() {
    scheduler = CalendarReminderScheduler(
      notifications: notifications,
      settings: () => (
        enabled: enabled,
        accountEnabled: accountEnabled,
        playSound: playSound,
      ),
      account: () => account,
      access: () => access,
      fetchAgenda: (start, end) async {
        fetches++;
        lastRange = (start, end);
        onFetch?.call();
        final error = fetchError;
        if (error != null) throw error;
        return agenda;
      },
      text: (reminder) => (title: reminder.title, body: 'body'),
    );
  }

  Future<void> sync() => withClock(Clock(() => now), scheduler.sync);

  final notifications = _FakeNotifications();
  late CalendarReminderScheduler scheduler;
  DateTime now = _now;
  void Function()? onFetch;

  /// The device's switches: System Notifications and Calendar Reminders.
  bool enabled = true;

  /// The active account's own notifications switch.
  bool accountEnabled = true;
  bool playSound = true;
  CalendarReminderAccount? account = (scope: _scope, userId: _me);
  bool? access = true;
  List<CalendarAgendaItem> agenda = const [];
  Object? fetchError;
  int fetches = 0;
  (DateTime, DateTime)? lastRange;
}

void main() {
  setUp(() {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    addTearDown(PreferencesStore.debugReset);
  });

  group('CalendarReminderScheduler', () {
    test('schedules the upcoming alerts of the agenda', () async {
      final h = _Harness()
        ..agenda = [
          _event('a', meta: {'alert_minutes': 15}),
          _event('b', startInMinutes: 120),
        ];

      await h.sync();

      check(h.notifications.keysIn(_scope)).deepEquals({'a|', 'b|'});
      check(
        h.notifications.scheduledAt['a|'],
      ).equals(_now.add(const Duration(minutes: 45)));
      check(h.lastRange).isNotNull().has((r) => r.$2.difference(r.$1), 'span')
          .equals(calendarReminderHorizon);
    });

    test('keeps a reminder that still matches', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.sync();
      final id = h.notifications.scheduled.single.id;

      await h.sync();

      check(h.notifications.scheduled.single.id).equals(id);
      check(h.notifications.cancelled).isEmpty();
    });

    test('posts an alert that is already due at once, and once only', () async {
      // "Remind me in 5 minutes": the default 10-minute alert has passed. The
      // other event starts while the agenda is being read.
      final h = _Harness()
        ..agenda = [
          _event('due', startInMinutes: 5),
          _event('starting', startInMinutes: 1),
        ];
      h.onFetch = () => h.now = _now.add(const Duration(minutes: 2));

      await h.sync();
      h.restart();
      await h.sync();

      check(h.notifications.delivered).deepEquals(['due|']);
      check(h.notifications.rejected).isEmpty();
      check(h.notifications.scheduled).isEmpty();
    });

    test('a reminder that fired on schedule is not posted again', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.sync();

      h.now = _now.add(const Duration(minutes: 52));
      h.notifications.fireDue(h.now);
      h.restart();
      await h.sync();

      check(h.notifications.delivered).deepEquals(['a|']);
      check(h.notifications.rejected).isEmpty();
    });

    test('only reminders still waiting to fire count toward the '
        'limit', () async {
      // Day-ahead alerts that have gone off, and more upcoming alerts than
      // the limit.
      final h = _Harness()
        ..agenda = [
          for (var i = 0; i < calendarReminderLimit; i++) ...[
            _event(
              'fired$i',
              startInMinutes: 60 + i,
              meta: {'alert_minutes': 24 * 60},
            ),
            _event('later$i', startInMinutes: 600 + i),
          ],
        ];
      await h.sync();

      check(h.notifications.delivered).length.equals(calendarReminderLimit);
      check(h.notifications.scheduled).length.equals(calendarReminderLimit);

      h.agenda = [...h.agenda, _event('new', startInMinutes: 30)];
      await h.sync();

      check(h.notifications.keysIn(_scope)).contains('new|');
      check(h.notifications.scheduled).length.equals(calendarReminderLimit);
      check(h.notifications.delivered).length.equals(calendarReminderLimit);
    });

    test('replaces a reminder whose event moved or was renamed', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.sync();
      final id = h.notifications.scheduled.single.id;

      h.agenda = [_event('a', startInMinutes: 90, title: 'Moved')];
      await h.sync();

      check(h.notifications.cancelled).deepEquals([id]);
      check(h.notifications.scheduled.single.id).not((it) => it.equals(id));
      check(
        h.notifications.scheduledAt['a|'],
      ).equals(_now.add(const Duration(minutes: 80)));
    });

    test('moves reminders onto exact alarms once they are allowed, and '
        'follows the sound setting', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.sync();
      final id = h.notifications.scheduled.single.id;
      check(h.notifications.exactByKey['a|']).equals(false);

      h.notifications.exactAllowed = true;
      await h.sync();

      check(h.notifications.cancelled).deepEquals([id]);
      check(h.notifications.exactByKey['a|']).equals(true);
      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});

      h.playSound = false;
      await h.sync();

      check(h.notifications.cancelled).length.equals(2);
      check(h.notifications.soundByKey['a|']).equals(false);
      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});
    });

    test('drops reminders of deleted events and of alerts turned off', () async {
      final h = _Harness()..agenda = [_event('a'), _event('b')];
      await h.sync();

      h.agenda = [
        _event('b', meta: {'alert_minutes': -1}),
      ];
      await h.sync();

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

      await h.sync();

      check(h.notifications.keysIn(_otherScope)).deepEquals({'other|'});
      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});
    });

    test('shares the limit with other accounts\' reminders, soonest first, '
        'counting those about to fire', () async {
      // Alerts at 12:01, and after 13:00.
      const soon = 17;
      final first = [
        for (var i = 0; i < soon; i++) _event('soon$i', startInMinutes: 11),
        for (var i = soon; i < calendarReminderLimit; i++)
          _event('late$i', startInMinutes: 70 + i),
      ];
      final h = _Harness()..agenda = first;
      await h.sync();

      // Another account's alerts at 12:30 take the places of the later ones.
      h
        ..now = _now.add(const Duration(seconds: 30))
        ..account = (scope: _otherScope, userId: _me)
        ..agenda = [
          for (var i = 0; i < calendarReminderLimit; i++)
            _event('other$i', startInMinutes: 40),
        ];
      await h.sync();

      check(h.notifications.scheduled).length.equals(calendarReminderLimit);
      check(h.notifications.keysIn(_scope))
          .deepEquals({for (var i = 0; i < soon; i++) 'soon$i|'});

      // Back on the first account, its 12:01 alerts are about to fire and
      // still pending.
      h
        ..now = _now.add(const Duration(seconds: 56))
        ..account = (scope: _scope, userId: _me)
        ..agenda = first;
      await h.sync();

      check(h.notifications.scheduled).length.equals(calendarReminderLimit);
    });

    test('turned off, it unschedules every reminder', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.sync();

      h.enabled = false;
      await h.sync();

      check(h.notifications.scheduled).isEmpty();
      check(h.fetches).equals(1);
    });

    test('an account with notifications off unschedules only its own '
        'reminders', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.sync();

      h
        ..account = (scope: _otherScope, userId: _me)
        ..accountEnabled = false;
      await h.sync();

      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});

      h.account = (scope: _scope, userId: _me);
      await h.sync();

      check(h.notifications.keysIn(_scope)).isEmpty();
      check(h.fetches).equals(1);
    });

    test('reminders turned off while the agenda is read are not handed '
        'over', () async {
      final h = _Harness()
        ..agenda = [_event('due', startInMinutes: 5), _event('later')];
      h.onFetch = () => h.enabled = false;

      await h.sync();

      check(h.notifications.delivered).isEmpty();
      check(h.notifications.scheduled).isEmpty();
    });

    test('keeps the reminders while calendar access is unknown, and drops '
        'them once it is off', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.sync();

      h.access = null;
      await h.sync();

      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});
      check(h.fetches).equals(1);

      h.access = false;
      await h.sync();

      check(h.notifications.keysIn(_scope)).isEmpty();
    });

    test('a failed read keeps what is scheduled', () async {
      final h = _Harness()..agenda = [_event('a')];
      await h.sync();

      h.fetchError = StateError('offline');
      await h.sync();

      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});
    });

    test('does nothing before an account is signed in', () async {
      final h = _Harness()
        ..account = null
        ..agenda = [_event('a')];

      await h.sync();

      check(h.fetches).equals(0);
      check(h.notifications.scheduled).isEmpty();
    });

    test('an agenda read for an account that switched away is dropped', () async {
      final h = _Harness();
      h.agenda = [_event('a')];
      final scheduler = CalendarReminderScheduler(
        notifications: h.notifications,
        settings: () => (enabled: true, accountEnabled: true, playSound: true),
        account: () => h.account,
        access: () => true,
        fetchAgenda: (start, end) async {
          h.account = (scope: _otherScope, userId: 'someone-else');
          return h.agenda;
        },
        text: (reminder) => (title: reminder.title, body: 'body'),
      );

      await withClock(Clock.fixed(_now), scheduler.sync);

      check(h.notifications.scheduled).isEmpty();
    });

    test('a sign-out during a sync leaves none of that account\'s reminders '
        'behind', () async {
      final h = _Harness()
        ..agenda = [_event('due', startInMinutes: 5), _event('later')];
      final hold = Completer<void>();
      h.notifications.holdSchedule = hold;

      final syncing = h.sync();
      await h.notifications.enteredSchedule.future;
      h.account = null;
      await h.scheduler.signedOut(_scope);
      hold.complete();
      await syncing;

      check(h.notifications.keysIn(_scope)).isEmpty();
      check(h.notifications.onScreen).isEmpty();
    });

    test('an account switch during a sync keeps that account\'s reminders',
        () async {
      final h = _Harness()..agenda = [_event('a'), _event('b')];
      final hold = Completer<void>();
      h.notifications.holdSchedule = hold;

      final syncing = h.sync();
      await h.notifications.enteredSchedule.future;
      h.account = (scope: _otherScope, userId: 'someone-else');
      hold.complete();
      await syncing;

      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});
    });

    test('calls during a sync fold into one more run', () async {
      final h = _Harness()..agenda = [_event('a')];
      final hold = Completer<void>();
      h.notifications.holdSchedule = hold;

      final first = h.sync();
      await h.notifications.enteredSchedule.future;
      final second = h.sync();
      final third = h.sync();
      hold.complete();
      await Future.wait([first, second, third]);

      check(h.fetches).equals(2);
      check(h.notifications.keysIn(_scope)).deepEquals({'a|'});
    });
  });

  group('ScheduledCalendarReminder', () {
    test('round-trips through its payload', () {
      final payload = ScheduledCalendarReminder.encode(
        key: 'a|a_1',
        scope: _scope,
        fireAt: _now,
        fingerprint: 'f',
      );

      final decoded = ScheduledCalendarReminder.tryDecode(7, payload);

      check(decoded).isNotNull()
        ..has((r) => r.id, 'id').equals(7)
        ..has((r) => r.key, 'key').equals('a|a_1')
        ..has((r) => r.scope, 'scope').equals(_scope)
        ..has((r) => r.fireAt, 'fireAt').equals(_now)
        ..has((r) => r.fingerprint, 'fingerprint').equals('f');
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
