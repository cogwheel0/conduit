import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'package:conduit_core/features/calendar/calendar_time.dart';

import '../../l10n/app_localizations.dart';

/// How the calendar's days and times read outside any widget: in the app's
/// language, and in the 12 or 24 hour style the device uses.
typedef CalendarClock = ({String locale, bool use24Hour});

/// The clock outside any widget: [l10n]'s language and the device's style.
CalendarClock calendarClockFor(AppLocalizations l10n) => (
  locale: l10n.localeName,
  use24Hour: WidgetsBinding.instance.platformDispatcher.alwaysUse24HourFormat,
);

/// The few colours a new calendar can take, with the name each is announced
/// by.
const calendarColorPalette = <({String hex, String name})>[
  (hex: '#3b82f6', name: 'blue'),
  (hex: '#22c55e', name: 'green'),
  (hex: '#f59e0b', name: 'amber'),
  (hex: '#ef4444', name: 'red'),
  (hex: '#8b5cf6', name: 'purple'),
  (hex: '#14b8a6', name: 'teal'),
];

/// `#rrggbb` as an opaque ARGB colour, or null when the server stored none or
/// something else.
int? calendarColorArgb(String? value) {
  final match = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  return 0xFF000000 | int.parse(match.group(1)!, radix: 16);
}

/// [text] with the narrow spaces some locales put before AM and PM made
/// plain, as the rest of the app writes times.
String _plain(String text) => text.replaceAll(' ', ' ');

/// A calendar day, such as "Tue, Oct 6".
String calendarDayText(CalendarClock clock, CalendarWallTime day) =>
    DateFormat.MMMEd(clock.locale).format(day.fields);

/// A wall clock time, in the device's 12 or 24 hour style: a device on the
/// 12-hour clock gets it whatever the language's own habit, as scheduled
/// tasks' times do.
String calendarClockText(CalendarClock clock, CalendarWallTime wall) => _plain(
  (clock.use24Hour
          ? DateFormat.Hm(clock.locale)
          : DateFormat('h:mm a', clock.locale))
      .format(wall.fields),
);

/// A month and its year, such as "November 2026".
String calendarMonthText(CalendarClock clock, CalendarWallTime month) =>
    DateFormat.yMMMM(clock.locale).format(month.fields);

/// The heading of a day: "Today · Tue, Oct 6" and "Tomorrow · …" for the next
/// two days, otherwise just the day.
String calendarDayHeadingText(
  CalendarClock clock,
  AppLocalizations l10n, {
  required CalendarWallTime day,
  required CalendarWallTime today,
}) {
  final date = calendarDayText(clock, day);
  if (day.sameDate(today)) return l10n.calendarDayToday(date);
  if (day.sameDate(today.addDays(1))) return l10n.calendarDayTomorrow(date);
  return date;
}

/// When an item happens, in [zone]: its days for an all-day event, otherwise
/// its start and end.
String calendarWhenText(
  CalendarClock clock,
  AppLocalizations l10n, {
  required int startNs,
  required int? endNs,
  required bool allDay,
  required CalendarZone zone,
}) {
  final span = daySpan(startNs: startNs, endNs: endNs, zone: zone);
  final firstDay = calendarDayText(clock, span.first);
  if (allDay) {
    return span.first.sameDate(span.last)
        ? '$firstDay · ${l10n.calendarAllDay}'
        : '$firstDay – ${calendarDayText(clock, span.last)}';
  }
  final start = wallTimeAt(startNs, zone);
  final startClock = calendarClockText(clock, start);
  if (endNs == null || endNs <= startNs) return '$firstDay · $startClock';
  final end = wallTimeAt(endNs, zone);
  final endClock = calendarClockText(clock, end);
  if (start.sameDate(end)) return '$firstDay · $startClock – $endClock';
  return '$firstDay $startClock – ${calendarDayText(clock, end)} $endClock';
}

/// The time line of a row on [day], which sits under that day's heading and
/// so omits the day.
///
/// A timed event that runs over several days starts on its first day ("Starts
/// 10:00 PM"), fills the days between ("All day") and ends on its last day
/// ("Ends 2:00 AM"); an end at midnight leaves its last day whole.
String calendarRowTimeText(
  CalendarClock clock,
  AppLocalizations l10n, {
  required int startNs,
  required int? endNs,
  required bool allDay,
  required CalendarZone zone,
  required CalendarWallTime day,
}) {
  if (allDay) return l10n.calendarAllDay;
  final start = wallTimeAt(startNs, zone);
  final startClock = calendarClockText(clock, start);
  if (endNs == null || endNs <= startNs) return startClock;
  final end = wallTimeAt(endNs, zone);
  final span = daySpan(startNs: startNs, endNs: endNs, zone: zone);
  if (span.first.sameDate(span.last)) {
    return '$startClock – ${calendarClockText(clock, end)}';
  }
  if (day.sameDate(span.first)) return l10n.calendarStartsAt(startClock);
  if (day.sameDate(span.last) && day.sameDate(end)) {
    return l10n.calendarEndsAt(calendarClockText(clock, end));
  }
  return l10n.calendarAllDay;
}
