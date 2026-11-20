import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:conduit_core/features/calendar/calendar_reminders.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:meta/meta.dart';

/// How far ahead reminders are scheduled. A sync happens on every app start,
/// resume and finished reply, so this only has to cover the time the app may
/// stay unopened.
const Duration calendarReminderHorizon = Duration(days: 14);

/// A reminder due this soon is posted at once rather than scheduled: the
/// notification plugin refuses a time that has passed by the moment it checks.
const Duration _dueMargin = Duration(seconds: 5);

/// The signed-in account a sync schedules reminders for.
typedef CalendarReminderAccount = ({String scope, String userId});

/// What a sync needs to know about the app when it runs: whether the device
/// lets reminders through ([enabled]), whether the active account's own
/// notifications are on ([accountEnabled]), and that account's sound setting.
typedef CalendarReminderSettings = ({
  bool enabled,
  bool accountEnabled,
  bool playSound,
});

/// A calendar reminder the device has scheduled, read back from its payload.
///
/// The payload is JSON with the occurrence's agenda key under
/// `calendarReminder`, its account under `scope`, when it fires under
/// `fireAt` (milliseconds since the epoch) and what it was scheduled as under
/// `fingerprint`. It carries no `kind`, so the app's notification-tap decoder
/// ignores it and a tap just opens the app.
@immutable
class ScheduledCalendarReminder {
  const ScheduledCalendarReminder({
    required this.id,
    required this.key,
    required this.scope,
    required this.fingerprint,
    this.fireAt,
  });

  /// The OS notification id it is scheduled under.
  final int id;

  /// The event occurrence's agenda key ([CalendarReminder.key]).
  final String key;

  /// The account it was scheduled for ([NotificationScope] string).
  final String scope;

  /// When it fires, in UTC; null when the payload did not say.
  final DateTime? fireAt;

  /// What it was scheduled as ([calendarReminderFingerprint]), so a resync can
  /// tell a reminder that still matches from one that has to be replaced.
  final String fingerprint;

  static String encode({
    required String key,
    required String scope,
    required DateTime fireAt,
    required String fingerprint,
  }) => jsonEncode({
    'calendarReminder': key,
    'scope': scope,
    'fireAt': fireAt.millisecondsSinceEpoch,
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
      final fireAt = map['fireAt'];
      if (key is! String || key.isEmpty) return null;
      if (scope is! String || NotificationScope.tryParse(scope) == null) {
        return null;
      }
      return ScheduledCalendarReminder(
        id: id,
        key: key,
        scope: scope,
        fireAt: fireAt is int
            ? DateTime.fromMillisecondsSinceEpoch(fireAt, isUtc: true)
            : null,
        fingerprint: fingerprint is String ? fingerprint : '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Everything a scheduled reminder shows or fires on, so a change to any of it
/// schedules the reminder again. That includes whether it fires on the minute,
/// so allowing exact alarms later moves the pending reminders onto them, and
/// its sound, which iOS fixes when a reminder is scheduled.
String calendarReminderFingerprint(
  CalendarReminder reminder, {
  required String title,
  required String body,
  required bool exact,
  required bool playSound,
}) => [
  reminder.fireAt.millisecondsSinceEpoch,
  title,
  body,
  exact ? 'exact' : 'inexact',
  playSound ? 'sound' : 'silent',
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

  /// Posts [reminder] for [scope] now. Returns false when it could not be
  /// posted.
  Future<bool> postCalendarReminder(
    CalendarReminder reminder, {
    required String scope,
    required String title,
    required String body,
    required bool playSound,
  });

  /// Unschedules the reminder scheduled under [id].
  Future<void> cancelScheduled(int id);

  /// Removes the notifications posted for [scope].
  Future<void> cancelScope(String scope);
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
/// lost its alert. An alert whose time has passed while its event has not
/// started yet is posted at once. What was handed to the OS is remembered, so
/// no occurrence is posted twice.
///
/// Reminders belong to the account they were scheduled for: a sync only
/// touches the active account's, and signing out of an account takes back its
/// own ([signedOut]).
class CalendarReminderScheduler {
  CalendarReminderScheduler({
    required CalendarReminderPort notifications,
    required CalendarReminderSettings Function() settings,
    required CalendarReminderAccount? Function() account,
    required bool? Function() access,
    required Future<List<CalendarAgendaItem>> Function(
      DateTime start,
      DateTime end,
    )
    fetchAgenda,
    required ({String title, String body}) Function(CalendarReminder reminder)
    text,
  }) : _notifications = notifications,
       _settings = settings,
       _account = account,
       _access = access,
       _fetchAgenda = fetchAgenda,
       _text = text;

  final CalendarReminderPort _notifications;
  final CalendarReminderSettings Function() _settings;
  final CalendarReminderAccount? Function() _account;

  /// Whether the active account can use the calendar; null while that is not
  /// known, which leaves the reminders scheduled so far in place.
  final bool? Function() _access;

  /// The agenda between two instants. Throws when it could not be read, which
  /// leaves the reminders scheduled so far in place.
  final Future<List<CalendarAgendaItem>> Function(DateTime start, DateTime end)
  _fetchAgenda;
  final ({String title, String body}) Function(CalendarReminder reminder) _text;

  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  /// Accounts signed out since the current sync began; null stands for all.
  final _signedOut = <String?>{};

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
    _signedOut.clear();
    final settings = _settings();
    if (!settings.enabled) {
      await _cancelScheduled();
      return;
    }
    final account = _account();
    if (account == null) return;
    if (!settings.accountEnabled) {
      await _cancelScheduled(account.scope);
      return;
    }
    final access = _access();
    if (access == null) return;
    if (!access) {
      await _cancelScheduled(account.scope);
      return;
    }
    // The last check before each handover, with no await after it, so nothing
    // reaches the OS under settings the user has changed since; the sync that
    // change starts applies the new ones.
    bool stale() =>
        _disposed ||
        _signedOut.contains(null) ||
        _signedOut.contains(account.scope) ||
        _account() != account ||
        _settings() != settings;

    final start = clock.now().toUtc();
    final items = await _fetchAgenda(start, start.add(calendarReminderHorizon));
    if (stale()) return;

    // Planned after the read, so an event that started meanwhile gets none.
    final plan = planCalendarReminders(
      items: items,
      userId: account.userId,
      now: clock.now(),
    );
    // Checked on every sync, so reminders move onto exact alarms once the
    // user allows them (and Settings knows whether to offer it).
    final exact = await _notifications.canScheduleExactReminders();
    if (stale()) return;
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
          playSound: settings.playSound,
        ),
      );
    }

    final scheduled = await _notifications.scheduledCalendarReminders();
    if (stale()) return;
    // iOS keeps 64 pending notifications per app, not per account, so the
    // limit covers every account's reminders, soonest first. Each one left
    // pending counts, including a kept one about to fire; one posted at once
    // takes no place.
    final kept = {
      for (final existing in scheduled)
        if (existing.scope == account.scope &&
            wanted[existing.key]?.$4 == existing.fingerprint)
          existing.key,
    };
    final dueBy = clock.now().toUtc().add(_dueMargin);
    final queued = [
      for (final reminder in plan)
        if (reminder.fireAt.isAfter(dueBy) || kept.contains(reminder.key))
          (fireAt: reminder.fireAt, key: reminder.key, other: null),
      for (final other in scheduled)
        if (other.scope != account.scope)
          (fireAt: other.fireAt, key: other.key, other: other),
    ]..sort((a, b) => _compareFireAt(a.fireAt, b.fireAt));
    for (final left in queued.skip(calendarReminderLimit)) {
      final other = left.other;
      if (other == null) {
        wanted.remove(left.key);
        continue;
      }
      await _notifications.cancelScheduled(other.id);
      await _forgetDelivered(other.scope, other.key);
      if (stale()) return;
    }

    final planned = {for (final reminder in plan) reminder.key};
    for (final existing in scheduled) {
      if (existing.scope != account.scope) continue;
      final match = wanted[existing.key];
      if (match != null && match.$4 == existing.fingerprint) {
        wanted.remove(existing.key);
      } else {
        planned.remove(existing.key);
        await _notifications.cancelScheduled(existing.id);
        if (stale()) break;
      }
    }
    await _updateDelivered(
      (delivered) => delivered[account.scope]?.removeWhere(
        (key, _) => !planned.contains(key),
      ),
    );
    if (stale()) return;

    for (final (reminder, title, body, _) in wanted.values) {
      if (stale()) return;
      final now = clock.now().toUtc();
      if (reminder.startAtNs <
          now.microsecondsSinceEpoch * nanosPerMicrosecond) {
        continue;
      }
      final alertAt = reminder.fireAt.millisecondsSinceEpoch;
      final due = !reminder.fireAt.isAfter(now.add(_dueMargin));
      // Fired from its schedule, or posted by an earlier sync.
      if (due && _readDelivered()[account.scope]?[reminder.key] == alertAt) {
        continue;
      }
      // Recorded before it is handed over, so a sync cut short in between
      // cannot post it twice.
      await _updateDelivered(
        (delivered) =>
            (delivered[account.scope] ??= {})[reminder.key] = alertAt,
      );
      if (stale()) {
        await _forgetDelivered(account.scope, reminder.key);
        return;
      }
      final handedOver = due
          ? await _notifications.postCalendarReminder(
              reminder,
              scope: account.scope,
              title: title,
              body: body,
              playSound: settings.playSound,
            )
          : await _notifications.scheduleCalendarReminder(
              reminder,
              scope: account.scope,
              title: title,
              body: body,
              playSound: settings.playSound,
              exact: exact,
            );
      if (!handedOver) await _forgetDelivered(account.scope, reminder.key);
      if (_signedOut.contains(null) || _signedOut.contains(account.scope)) {
        // The sign-out's own cleanup may have run before this landed.
        await _takeBack(account.scope);
        return;
      }
    }
  }

  /// Takes back the reminders of [scope], or of every account when null,
  /// because it signed out: scheduled and posted ones, and the record of what
  /// was handed over. A sync still running for it stops, and takes back what
  /// it handed over meanwhile.
  Future<void> signedOut(String? scope) async {
    _signedOut.add(scope);
    await _cancelScheduled(scope);
    await _updateDelivered((delivered) {
      if (scope == null) {
        delivered.clear();
      } else {
        delivered.remove(scope);
      }
    });
  }

  Future<void> _takeBack(String scope) async {
    await _cancelScheduled(scope);
    await _notifications.cancelScope(scope);
    await _updateDelivered((delivered) => delivered.remove(scope));
  }

  /// Unschedules the reminders of [scope], or of every account when null, and
  /// forgets them, so ones that come due later can still be posted.
  Future<void> _cancelScheduled([String? scope]) async {
    for (final reminder in await _notifications.scheduledCalendarReminders()) {
      if (scope != null && reminder.scope != scope) continue;
      await _notifications.cancelScheduled(reminder.id);
      await _forgetDelivered(reminder.scope, reminder.key);
    }
  }

  /// The reminders handed to the OS, scheduled or posted: for each account,
  /// each occurrence's key with the alert time it was handed over for.
  static Map<String, Map<String, int>> _readDelivered() {
    final raw = PreferencesStore.getString(
      PreferenceKeys.calendarRemindersDelivered,
    );
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (key is String && value is Map)
            key: {
              for (final MapEntry(key: occurrence, value: alertAt)
                  in value.entries)
                if (occurrence is String && alertAt is int) occurrence: alertAt,
            },
      };
    } catch (_) {
      return {};
    }
  }

  /// Applies [change] to the stored record. Read and written without a gap,
  /// so a sign-out running beside a sync cannot be overwritten by it.
  static Future<void> _updateDelivered(
    void Function(Map<String, Map<String, int>> delivered) change,
  ) {
    final delivered = _readDelivered();
    change(delivered);
    final kept = {
      for (final MapEntry(:key, :value) in delivered.entries)
        if (value.isNotEmpty) key: value,
    };
    final raw = kept.isEmpty ? null : jsonEncode(kept);
    const key = PreferenceKeys.calendarRemindersDelivered;
    if (raw == PreferencesStore.getString(key)) return Future<void>.value();
    return PreferencesStore.put(key, raw);
  }

  /// Soonest first; a reminder whose time is not known goes last.
  static int _compareFireAt(DateTime? a, DateTime? b) {
    if (a != null && b != null) return a.compareTo(b);
    return (a == null ? 1 : 0) - (b == null ? 1 : 0);
  }

  static Future<void> _forgetDelivered(String scope, String key) =>
      _updateDelivered((delivered) => delivered[scope]?.remove(key));

  void dispose() => _disposed = true;
}
