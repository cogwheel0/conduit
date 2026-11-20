import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/services/calendar_reminder_scheduler.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/calendar/calendar_reminder_scheduler.dart';
import 'package:conduit_core/features/calendar/calendar_reminders.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

final _now = DateTime.utc(2026, 11, 13, 12);

void main() {
  group('calendarReminderText', () {
    setUpAll(() => initializeDateFormatting('en'));

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

  test('a reminder\'s payload opens the app without deep-linking', () {
    final payload = ScheduledCalendarReminder.encode(
      key: 'a|',
      scope: 'owui:acct-1',
      fireAt: _now,
      fingerprint: 'f',
    );

    check(NotificationTap.tryDecode(payload)).isNull();
  });
}
