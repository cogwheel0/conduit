import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/features/calendar/calendar_reminders.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:meta/meta.dart';

/// How far ahead reminders are scheduled. A sync happens on every app start,
/// resume and finished reply, so this only has to cover the time the app may
/// stay unopened.
const Duration calendarReminderHorizon = Duration(days: 14);

/// The signed-in account a sync schedules reminders for.
typedef CalendarReminderAccount = ({String scope, String userId});

/// What a sync needs to know about the app when it runs.
typedef CalendarReminderSettings = ({bool enabled, bool playSound});

/// A calendar reminder the device has scheduled, read back from its payload.
///
/// The payload is JSON with the occurrence's agenda key under
/// `calendarReminder`, its account under `scope` and what it was scheduled as
/// under `fingerprint`. It carries no `kind`, so the app's notification-tap
/// decoder ignores it and a tap just opens the app.
@immutable
class ScheduledCalendarReminder {
  const ScheduledCalendarReminder({
    required this.id,
    required this.key,
    required this.scope,
    required this.fingerprint,
  });

  /// The OS notification id it is scheduled under.
  final int id;

  /// The event occurrence's agenda key ([CalendarReminder.key]).
  final String key;

  /// The account it was scheduled for ([NotificationScope] string).
  final String scope;

  /// What it was scheduled as ([calendarReminderFingerprint]), so a resync can
  /// tell a reminder that still matches from one that has to be replaced.
  final String fingerprint;

  static String encode({
    required String key,
    required String scope,
    required String fingerprint,
  }) => jsonEncode({
    'calendarReminder': key,
    'scope': scope,
    'fingerprint': fingerprint,
  });

  /// The reminder scheduled under [id] with [payload]; null for any other
  /// notification.
  static ScheduledCalendarReminder? tryDecode(int id, String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final map = jsonDecode(payload);
      if (map is! Map) return null;
      final key = map['calendarReminder'];
      final scope = map['scope'];
      final fingerprint = map['fingerprint'];
      if (key is! String || key.isEmpty) return null;
      if (scope is! String || NotificationScope.tryParse(scope) == null) {
        return null;
      }
      return ScheduledCalendarReminder(
        id: id,
        key: key,
        scope: scope,
        fingerprint: fingerprint is String ? fingerprint : '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Everything a scheduled reminder shows or fires on, so a change to any of it
/// schedules the reminder again. That includes whether it fires on the minute,
/// so allowing exact alarms later moves the pending reminders onto them.
String calendarReminderFingerprint(
  CalendarReminder reminder, {
  required String title,
  required String body,
  required bool exact,
}) => [
  reminder.fireAt.millisecondsSinceEpoch,
  title,
  body,
  exact ? 'exact' : 'inexact',
].join('|');

/// The device's local notifications, as calendar reminders use them. The app
/// implements it on flutter_local_notifications.
abstract interface class CalendarReminderPort {
  /// Whether calendar reminders can fire on the minute: on Android only with
  /// the "Alarms & reminders" permission.
  Future<bool> canScheduleExactReminders();

  /// The calendar reminders scheduled and not yet posted, for every account.
  Future<List<ScheduledCalendarReminder>> scheduledCalendarReminders();

  /// Schedules [reminder] for [scope] to be posted at its
  /// [CalendarReminder.fireAt], also while the app is not running. Returns
  /// false when it could not be scheduled.
  ///
  /// [exact] is whether it may fire on the minute
  /// ([canScheduleExactReminders]); otherwise it is posted at roughly that
  /// time.
  Future<bool> scheduleCalendarReminder(
    CalendarReminder reminder, {
    required String scope,
    required String title,
    required String body,
    required bool playSound,
    required bool exact,
  });

  /// Unschedules the reminder scheduled under [id].
  Future<void> cancelScheduled(int id);

  /// Unschedules the calendar reminders of [scope], or of every account when
  /// [scope] is null. Reminders already posted stay.
  Future<void> cancelCalendarReminders({String? scope});
}

/// Keeps the device's scheduled calendar reminders in line with the active
/// Open WebUI account's calendar.
///
/// Open WebUI raises `calendar:alert` over the socket only, so nothing reaches
/// a phone whose app is in the background. Instead, every [sync] reads the
/// next [calendarReminderHorizon] of the agenda and schedules each upcoming
/// alert as a local notification, which the OS posts on time even when the
/// app is not running. A sync keeps the reminders that still match, replaces
/// the changed ones and drops those whose event moved away, was deleted or
/// lost its alert.
///
/// Reminders belong to the account they were scheduled for: a sync only
/// touches the active account's, and signing out of an account unschedules
/// its own ([CalendarReminderPort.cancelCalendarReminders]).
class CalendarReminderScheduler {
  CalendarReminderScheduler({
    required CalendarReminderPort notifications,
    required CalendarReminderSettings Function() settings,
    required CalendarReminderAccount? Function() account,
    required Future<List<CalendarAgendaItem>?> Function(
      DateTime start,
      DateTime end,
    )
    fetchAgenda,
    required ({String title, String body}) Function(CalendarReminder reminder)
    text,
    DateTime Function() now = DateTime.now,
  }) : _notifications = notifications,
       _settings = settings,
       _account = account,
       _fetchAgenda = fetchAgenda,
       _text = text,
       _now = now;

  final CalendarReminderPort _notifications;
  final CalendarReminderSettings Function() _settings;
  final CalendarReminderAccount? Function() _account;

  /// The agenda between two instants; null when the account cannot use the
  /// calendar. Throws when it could not be read, which leaves the reminders
  /// scheduled so far in place.
  final Future<List<CalendarAgendaItem>?> Function(DateTime start, DateTime end)
  _fetchAgenda;
  final ({String title, String body}) Function(CalendarReminder reminder)
  _text;
  final DateTime Function() _now;

  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  /// Brings the scheduled reminders up to date. Calls made while one runs are
  /// folded into a single follow-up run.
  Future<void> sync() {
    if (_disposed) return Future<void>.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _runUntilSettled().whenComplete(() => _running = null);
  }

  Future<void> _runUntilSettled() async {
    do {
      _again = false;
      try {
        await _syncOnce();
      } catch (error, stackTrace) {
        DebugLogger.error(
          'calendar-reminder-sync-failed',
          scope: 'notifications/calendar',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } while (_again && !_disposed);
  }

  Future<void> _syncOnce() async {
    final settings = _settings();
    if (!settings.enabled) {
      await _notifications.cancelCalendarReminders();
      return;
    }
    final account = _account();
    if (account == null) return;

    final now = _now().toUtc();
    final items = await _fetchAgenda(now, now.add(calendarReminderHorizon));
    // The account may have changed while the agenda was read.
    if (_disposed || _account() != account) return;

    final plan = items == null
        ? const <CalendarReminder>[]
        : planCalendarReminders(items: items, userId: account.userId, now: now);
    // Checked on every sync, so reminders move onto exact alarms once the
    // user allows them (and Settings knows whether to offer it).
    final exact = await _notifications.canScheduleExactReminders();
    final wanted = <String, (CalendarReminder, String, String, String)>{};
    for (final reminder in plan) {
      final text = _text(reminder);
      wanted[reminder.key] = (
        reminder,
        text.title,
        text.body,
        calendarReminderFingerprint(
          reminder,
          title: text.title,
          body: text.body,
          exact: exact,
        ),
      );
    }

    final scheduled = await _notifications.scheduledCalendarReminders();
    for (final existing in scheduled) {
      if (existing.scope != account.scope) continue;
      final match = wanted[existing.key];
      if (match != null && match.$4 == existing.fingerprint) {
        wanted.remove(existing.key);
      } else {
        await _notifications.cancelScheduled(existing.id);
      }
    }

    for (final (reminder, title, body, _) in wanted.values) {
      if (_disposed) return;
      await _notifications.scheduleCalendarReminder(
        reminder,
        scope: account.scope,
        title: title,
        body: body,
        playSound: settings.playSound,
        exact: exact,
      );
    }
  }

  void dispose() => _disposed = true;
}
