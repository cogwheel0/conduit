import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/utils/current_localizations.dart';
import '../../../l10n/app_localizations.dart';
import 'local_notification_service.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/calendar/calendar_reminders.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show isChatStreamingProvider;
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

part 'calendar_reminder_scheduler.g.dart';

/// How far ahead reminders are scheduled. A sync happens on every app start,
/// resume and finished reply, so this only has to cover the time the app may
/// stay unopened.
const Duration calendarReminderHorizon = Duration(days: 14);

/// The signed-in account a sync schedules reminders for.
typedef CalendarReminderAccount = ({String scope, String userId});

/// What a sync needs to know about the app when it runs.
typedef CalendarReminderSettings = ({bool enabled, bool playSound});

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
/// its own ([LocalNotificationService.cancelCalendarReminders]).
class CalendarReminderScheduler {
  CalendarReminderScheduler({
    required LocalNotificationService notifications,
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

  final LocalNotificationService _notifications;
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
      );
    }
  }

  void dispose() => _disposed = true;
}

/// The title and text a reminder is shown with: the event's title, and when
/// it starts ("Starts at 14:30 · Room 1"), or that it lasts all day.
({String title, String body}) calendarReminderText(
  CalendarReminder reminder,
  AppLocalizations l10n, {
  bool? use24HourClock,
}) {
  final title = reminder.title.trim().isEmpty
      ? l10n.calendarUntitledEvent
      : reminder.title.trim();
  final String when;
  if (reminder.allDay) {
    when = l10n.calendarAllDay;
  } else {
    final start = instantFromNanoseconds(reminder.startAtNs).toLocal();
    final twentyFour =
        use24HourClock ??
        ui.PlatformDispatcher.instance.alwaysUse24HourFormat;
    final clock = (twentyFour ? DateFormat.Hm : DateFormat.jm)(
      l10n.localeName,
    ).format(start);
    when = l10n.calendarReminderStartsAt(clock);
  }
  final location = reminder.location?.trim() ?? '';
  return (
    title: title,
    body: location.isEmpty ? when : '$when · $location',
  );
}

@Riverpod(keepAlive: true)
CalendarReminderScheduler calendarReminderScheduler(Ref ref) {
  final scheduler = CalendarReminderScheduler(
    notifications: ref.read(localNotificationServiceProvider),
    settings: () {
      final app = ref.read(appSettingsProvider);
      return (
        enabled:
            app.notificationsEnabled &&
            app.notificationSystem &&
            app.notificationCalendarEnabled,
        playSound: app.notificationSound,
      );
    },
    account: () {
      final accountId = ref.read(settledActiveAccountIdProvider);
      final user = ref.read(currentUserProvider2);
      if (accountId == null || accountId.isEmpty || user == null) return null;
      return (
        scope: NotificationScope.openWebUi(accountId).value,
        userId: user.id,
      );
    },
    fetchAgenda: (start, end) async {
      final api = ref.read(apiServiceProvider);
      if (api == null || !ref.read(calendarAvailableProvider)) return null;
      const zone = DeviceCalendarZone();
      return api.getCalendarEvents(
        startIso: isoWithOffset(
          start.microsecondsSinceEpoch * nanosPerMicrosecond,
          zone,
        ),
        endIso: isoWithOffset(
          end.microsecondsSinceEpoch * nanosPerMicrosecond,
          zone,
        ),
        authSnapshot: api.captureAuthSnapshot(),
      );
    },
    text: (reminder) =>
        calendarReminderText(reminder, currentAppLocalizations()),
  );
  ref.onDispose(scheduler.dispose);

  void resync() => unawaited(scheduler.sync());

  // Turning reminders on or off, or a sound change, applies right away.
  ref.listen<CalendarReminderSettings>(
    appSettingsProvider.select(
      (app) => (
        enabled:
            app.notificationsEnabled &&
            app.notificationSystem &&
            app.notificationCalendarEnabled,
        playSound: app.notificationSound,
      ),
    ),
    (_, _) => resync(),
  );
  // Another account, or the calendar becoming available or going away.
  ref.listen<String?>(settledActiveAccountIdProvider, (_, _) => resync());
  ref.listen<String?>(
    currentUserProvider2.select((user) => user?.id),
    (_, _) => resync(),
  );
  ref.listen<bool>(calendarAvailableProvider, (_, _) => resync());
  // A reply in the open chat finished, however it arrived (socket or the HTTP
  // completion recovery): the calendar tool may have added an event.
  ref.listen<bool>(isChatStreamingProvider, (previous, next) {
    if (previous == true && !next) resync();
  }, weak: true);
  // An event created, edited or deleted in the calendar. Weak, so the agenda
  // is not loaded just for this when the calendar was never opened.
  ref.listen(calendarAgendaProvider, (previous, next) {
    if (next.hasValue && !identical(previous?.value, next.value)) resync();
  }, weak: true);

  return scheduler;
}
