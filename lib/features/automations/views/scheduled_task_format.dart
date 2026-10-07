import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';

import '../../../l10n/app_localizations.dart';

String _locale(BuildContext context) =>
    Localizations.localeOf(context).toString();

/// A server nanosecond timestamp as a local date and time, or null when the
/// server sent none.
String? formatServerTime(BuildContext context, int? nanoseconds) {
  final time = dateTimeFromEpochNanoseconds(nanoseconds);
  if (time == null) return null;
  return DateFormat.yMMMd(_locale(context)).add_jm().format(time);
}

String formatWallClockTime(BuildContext context, int hour, int minute) =>
    MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay(hour: hour, minute: minute));

/// Short weekday name for a rule code such as `MO`, in the app's language.
String weekdayLabel(BuildContext context, String code) {
  final index = AutomationSchedule.weekdayCodes.indexOf(code);
  // 1 January 2024 was a Monday.
  return DateFormat.E(_locale(context)).format(DateTime(2024, 1, 1 + index));
}

/// One line describing a schedule. A rule the controls cannot edit is shown as
/// stored, since a guess at its meaning could be wrong.
String scheduleSummary(
  BuildContext context,
  AppLocalizations l10n,
  AutomationSchedule schedule,
) {
  return switch (schedule) {
    OnceAutomationSchedule() => l10n.scheduledTaskScheduleOnceSummary(
      DateFormat.yMMMd(_locale(context)).add_jm().format(schedule.wallClock),
    ),
    DailyAutomationSchedule() => l10n.scheduledTaskScheduleDailySummary(
      formatWallClockTime(context, schedule.hour, schedule.minute),
    ),
    WeeklyAutomationSchedule() => l10n.scheduledTaskScheduleWeeklySummary(
      [
        for (final code in AutomationSchedule.weekdayCodes)
          if (schedule.days.contains(code)) weekdayLabel(context, code),
      ].join(', '),
      formatWallClockTime(context, schedule.hour, schedule.minute),
    ),
    RawAutomationSchedule() =>
      schedule.rrule.trim().isEmpty
          ? l10n.scheduledTaskScheduleCustom
          : '${l10n.scheduledTaskScheduleCustom}: ${schedule.rrule.trim().replaceAll(RegExp(r'\s+'), ' ')}',
  };
}

/// Why an operation failed, in words for the user: the server's own
/// explanation when it gave one, otherwise [fallback].
String scheduledTaskErrorText(
  AppLocalizations l10n,
  Object error, {
  required String fallback,
}) {
  if (error is AutomationsOwnerChangedException) {
    return l10n.scheduledTasksAccountChanged;
  }
  if (error is AutomationsUnavailableException) {
    return l10n.scheduledTasksUnavailable;
  }
  if (error is DioException && error.response?.statusCode == 404) {
    return l10n.scheduledTasksNotFound;
  }
  return automationErrorDetail(error) ?? fallback;
}

String automationIssueText(AppLocalizations l10n, AutomationDraftIssue issue) =>
    switch (issue) {
      AutomationDraftIssue.nameRequired => l10n.scheduledTaskNameRequired,
      AutomationDraftIssue.promptRequired => l10n.scheduledTaskPromptRequired,
      AutomationDraftIssue.modelRequired => l10n.scheduledTaskModelRequired,
      AutomationDraftIssue.modelUnavailable =>
        l10n.scheduledTaskModelUnavailableIssue,
      AutomationDraftIssue.channelRequired => l10n.scheduledTaskChannelRequired,
      AutomationDraftIssue.channelUnavailable =>
        l10n.scheduledTaskChannelUnavailableIssue,
      AutomationDraftIssue.folderUnavailable =>
        l10n.scheduledTaskFolderUnavailableIssue,
      AutomationDraftIssue.scheduleIncomplete =>
        l10n.scheduledTaskScheduleIncomplete,
    };
