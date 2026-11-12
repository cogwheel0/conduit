import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';

import '../../l10n/app_localizations.dart';

/// How a scheduled task's times read: in the app's language, and in the 12
/// or 24 hour style the device uses.
typedef TaskClock = ({String locale, bool use24Hour});

/// The clock outside any widget: [l10n]'s language and the device's style.
TaskClock taskClockFor(AppLocalizations l10n) => (
  locale: l10n.localeName,
  use24Hour: WidgetsBinding.instance.platformDispatcher.alwaysUse24HourFormat,
);

/// A date with its time of day.
DateFormat _dateAndTime(TaskClock clock) {
  final date = DateFormat.yMMMd(clock.locale);
  return clock.use24Hour ? date.add_Hm() : date.add_jm();
}

/// A server nanosecond timestamp as a local date and time, or null when the
/// server sent none.
String? formatServerTime(TaskClock clock, int? nanoseconds) {
  final time = dateTimeFromEpochNanoseconds(nanoseconds);
  if (time == null) return null;
  return _plain(_dateAndTime(clock).format(time));
}

/// [text] with the narrow spaces some locales put before AM and PM made
/// plain, as the rest of the app writes times.
String _plain(String text) => text.replaceAll('\u202f', ' ');

/// A wall clock time.
String formatWallClockTime(TaskClock clock, int hour, int minute) => _plain(
  (clock.use24Hour ? DateFormat.Hm(clock.locale) : DateFormat.jm(clock.locale))
      .format(DateTime(2000, 1, 1, hour, minute)),
);

/// Short weekday name for a rule code such as `MO`, in the app's language.
String weekdayLabel(TaskClock clock, String code) {
  final index = AutomationSchedule.weekdayCodes.indexOf(code);
  // 1 January 2024 was a Monday.
  return DateFormat.E(clock.locale).format(DateTime(2024, 1, 1 + index));
}

/// Full weekday name for a rule code such as `MO`, in the app's language.
String weekdayName(TaskClock clock, String code) {
  final index = AutomationSchedule.weekdayCodes.indexOf(code);
  return DateFormat.EEEE(clock.locale).format(DateTime(2024, 1, 1 + index));
}

/// One line describing a schedule. A rule the controls cannot edit is shown as
/// stored, since a guess at its meaning could be wrong.
String scheduleSummary(
  TaskClock clock,
  AppLocalizations l10n,
  AutomationSchedule schedule,
) {
  return switch (schedule) {
    OnceAutomationSchedule() => l10n.scheduledTaskScheduleOnceSummary(
      _plain(_dateAndTime(clock).format(schedule.wallClock)),
    ),
    DailyAutomationSchedule() => l10n.scheduledTaskScheduleDailySummary(
      formatWallClockTime(clock, schedule.hour, schedule.minute),
    ),
    WeeklyAutomationSchedule() => l10n.scheduledTaskScheduleWeeklySummary(
      [
        for (final code in AutomationSchedule.weekdayCodes)
          if (schedule.days.contains(code)) weekdayLabel(clock, code),
      ].join(', '),
      formatWallClockTime(clock, schedule.hour, schedule.minute),
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
      AutomationDraftIssue.terminalRequired =>
        l10n.scheduledTaskTerminalRequired,
      AutomationDraftIssue.agentNeedsChat => l10n.scheduledTaskAgentNeedsChat,
    };
