import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/utils/current_localizations.dart';
import '../../../l10n/app_localizations.dart';
import 'local_notification_service.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/calendar/calendar_reminder_scheduler.dart';
import 'package:conduit_core/features/calendar/calendar_reminders.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show isChatStreamingProvider;
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';

part 'calendar_reminder_scheduler.g.dart';

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

/// System Notifications and Calendar Reminders are the device's own switches;
/// the master switch and Sound are the active account's.
CalendarReminderSettings _reminderSettings(AppSettings app) => (
  enabled: app.notificationSystem && app.notificationCalendarEnabled,
  accountEnabled: app.notificationsEnabled,
  playSound: app.notificationSound,
);

@Riverpod(keepAlive: true)
CalendarReminderScheduler calendarReminderScheduler(Ref ref) {
  final scheduler = CalendarReminderScheduler(
    notifications: ref.read(localNotificationServiceProvider),
    settings: () => _reminderSettings(ref.read(appSettingsProvider)),
    account: () {
      final accountId = ref.read(settledActiveAccountIdProvider);
      final user = ref.read(currentUserProvider2);
      if (accountId == null || accountId.isEmpty || user == null) return null;
      return (
        scope: NotificationScope.openWebUi(accountId).value,
        userId: user.id,
      );
    },
    access: () => ref.read(calendarAccessProvider),
    fetchAgenda: (start, end) async {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw StateError('No Open WebUI connection');
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
    appSettingsProvider.select(_reminderSettings),
    (_, _) => resync(),
  );
  // Another account, or the calendar becoming available or going away.
  ref.listen<String?>(settledActiveAccountIdProvider, (_, _) => resync());
  ref.listen<String?>(
    currentUserProvider2.select((user) => user?.id),
    (_, _) => resync(),
  );
  ref.listen<bool?>(calendarAccessProvider, (_, _) => resync());
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
