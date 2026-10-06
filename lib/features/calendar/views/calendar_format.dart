import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show automationErrorDetail;
import 'package:conduit_core/features/calendar/calendar_draft.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';

import '../../../l10n/app_localizations.dart';

String _locale(BuildContext context) =>
    Localizations.localeOf(context).toString();

/// A calendar day, such as "Tue, Oct 6".
String formatCalendarDay(BuildContext context, CalendarWallTime day) =>
    DateFormat.MMMEd(_locale(context)).format(day.fields);

/// A wall clock time, in the 12 or 24 hour style the device uses.
String formatCalendarClock(BuildContext context, CalendarWallTime wall) =>
    MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay(hour: wall.hour, minute: wall.minute));

/// When an item happens, in [zone]: its days for an all-day event, otherwise
/// its start and end.
String formatCalendarWhen(
  BuildContext context,
  AppLocalizations l10n, {
  required int startNs,
  required int? endNs,
  required bool allDay,
  required CalendarZone zone,
}) {
  final span = daySpan(startNs: startNs, endNs: endNs, zone: zone);
  final firstDay = formatCalendarDay(context, span.first);
  if (allDay) {
    return span.first.sameDate(span.last)
        ? '$firstDay · ${l10n.calendarAllDay}'
        : '$firstDay – ${formatCalendarDay(context, span.last)}';
  }
  final start = wallTimeAt(startNs, zone);
  final startClock = formatCalendarClock(context, start);
  if (endNs == null || endNs <= startNs) return '$firstDay · $startClock';
  final end = wallTimeAt(endNs, zone);
  final endClock = formatCalendarClock(context, end);
  if (start.sameDate(end)) return '$firstDay · $startClock – $endClock';
  return '$firstDay $startClock – ${formatCalendarDay(context, end)} $endClock';
}

/// The time line of an agenda row, which sits under a day heading and so omits
/// the day.
String formatCalendarRowTime(
  BuildContext context,
  AppLocalizations l10n, {
  required int startNs,
  required int? endNs,
  required bool allDay,
  required CalendarZone zone,
}) {
  if (allDay) return l10n.calendarAllDay;
  final start = formatCalendarClock(context, wallTimeAt(startNs, zone));
  if (endNs == null || endNs <= startNs) return start;
  return '$start – ${formatCalendarClock(context, wallTimeAt(endNs, zone))}';
}

/// `#rrggbb` as a colour, or null when the server stored none or something
/// else.
Color? parseCalendarColor(String? value) {
  final match = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  return Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
}

String repeatLabel(AppLocalizations l10n, CalendarRepeat repeat) =>
    switch (repeat) {
      CalendarRepeat.none => l10n.calendarRepeatNone,
      CalendarRepeat.daily => l10n.calendarRepeatDaily,
      CalendarRepeat.weekdays => l10n.calendarRepeatWeekdays,
      CalendarRepeat.weekly => l10n.calendarRepeatWeekly,
      CalendarRepeat.monthly => l10n.calendarRepeatMonthly,
      CalendarRepeat.yearly => l10n.calendarRepeatYearly,
      CalendarRepeat.custom => l10n.calendarRepeatCustom,
    };

String rsvpLabel(AppLocalizations l10n, CalendarRsvp? status) =>
    switch (status) {
      CalendarRsvp.accepted => l10n.calendarRsvpAccepted,
      CalendarRsvp.tentative => l10n.calendarRsvpTentative,
      CalendarRsvp.declined => l10n.calendarRsvpDeclined,
      CalendarRsvp.pending || null => l10n.calendarRsvpPending,
    };

String draftIssueText(AppLocalizations l10n, CalendarDraftIssue issue) =>
    switch (issue) {
      CalendarDraftIssue.titleRequired => l10n.calendarTitleRequired,
      CalendarDraftIssue.calendarRequired => l10n.calendarCalendarRequired,
      CalendarDraftIssue.endBeforeStart => l10n.calendarEndBeforeStart,
    };

/// Why an operation failed, in words for the user: the server's own
/// explanation when it gave one, otherwise [fallback].
String calendarErrorText(
  AppLocalizations l10n,
  Object error, {
  required String fallback,
}) {
  if (error is CalendarOwnerChangedException) {
    return l10n.calendarAccountChanged;
  }
  if (error is CalendarUnavailableException) return l10n.calendarUnavailable;
  if (error is CalendarPermissionException) {
    return switch (error.denial) {
      CalendarDenial.notWritable ||
      CalendarDenial.destinationNotWritable => l10n.calendarWriteDenied,
      CalendarDenial.notInvited => l10n.calendarNotInvited,
      CalendarDenial.notOwnCalendar => l10n.calendarMakeDefaultFailed,
      CalendarDenial.scheduledTaskEntry => l10n.calendarScheduledEntryReadOnly,
      CalendarDenial.notLoaded => fallback,
    };
  }
  if (error is DioException) {
    switch (error.response?.statusCode) {
      case 403:
        return l10n.calendarWriteDenied;
      case 404:
        return l10n.calendarNotFound;
    }
  }
  return automationErrorDetail(error) ?? fallback;
}
