import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/calendar/calendar_access.dart';
import 'package:conduit_core/features/calendar/calendar_draft.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../calendar/calendar_text.dart';
import '../../calendar/views/calendar_format.dart'
    show draftIssueText, repeatLabel, rsvpLabel;
import 'calendar_page_ids.dart';
import 'scheduled_task_settings_pages.dart' show scheduledTaskPageId;

/// The colour an item is marked in when neither it nor its calendar has one.
const _fallbackColor = 0xFF8E8E93;

NativeSheetItemConfig _note(
  String id,
  String title, [
  String symbol = 'info.circle',
  String? subtitle,
]) => NativeSheetItemConfig(
  id: id,
  title: title,
  subtitle: subtitle,
  sfSymbol: symbol,
  kind: NativeSheetItemKind.info,
);

NativeSheetItemConfig _warning(String id, String title) =>
    _note(id, title, 'exclamationmark.triangle');

/// A page that is still being read.
NativeSheetDetailConfig _loading(
  AppLocalizations l10n,
  String id,
  String title,
) => buildNativeLoadingDetail(l10n: l10n, id: id, title: title);

/// [day] as a month calendar names it.
String calendarDayKey(CalendarWallTime day) =>
    nativeSheetCalendarDay(DateTime(day.year, day.month, day.day));

/// A day a month calendar sent, as a wall-clock day.
CalendarWallTime? calendarDayFromKey(Object? value) {
  final day = parseNativeSheetCalendarDay(value);
  return day == null ? null : CalendarWallTime(day.year, day.month, day.day);
}

/// The first day of [day]'s month.
CalendarWallTime calendarMonthOf(CalendarWallTime day) =>
    CalendarWallTime(day.year, day.month, 1);

/// How many days [month]'s month has.
int calendarDaysInMonth(CalendarWallTime month) =>
    DateTime.utc(month.year, month.month + 1, 0).day;

/// The days an agenda item touches in [zone].
({CalendarWallTime first, CalendarWallTime last}) calendarItemSpan(
  CalendarAgendaItem item,
  CalendarZone zone,
) => switch (item) {
  final CalendarEventModel event => daySpan(
    startNs: event.startAtNs,
    endNs: event.endAtNs,
    zone: zone,
  ),
  final ScheduledTaskCalendarEntry entry => daySpan(
    startNs: entry.startAtNs,
    zone: zone,
  ),
};

/// The colour [item] is marked in: its own, else its calendar's.
int calendarItemColor(CalendarAgendaItem item, CalendarAgendaData data) {
  final calendar = switch (item) {
    final CalendarEventModel event =>
      data.calendars.where((c) => c.id == event.calendarId).firstOrNull,
    ScheduledTaskCalendarEntry() =>
      data.calendars.where((c) => c.isVirtual).firstOrNull,
  };
  final own = item is CalendarEventModel ? item.color : null;
  return calendarColorArgb(own) ??
      calendarColorArgb(calendar?.color) ??
      _fallbackColor;
}

/// The items on [day], by start.
List<CalendarAgendaItem> calendarItemsOn(
  CalendarAgendaData data,
  CalendarWallTime day,
  CalendarZone zone,
) {
  final items = [
    for (final item in data.items)
      if (_covers(calendarItemSpan(item, zone), day)) item,
  ]..sort((a, b) => a.startAtNs.compareTo(b.startAtNs));
  return items;
}

bool _covers(
  ({CalendarWallTime first, CalendarWallTime last}) span,
  CalendarWallTime day,
) => span.first.compareTo(day) <= 0 && span.last.compareTo(day) >= 0;

/// The days of [month] that hold something, each with up to three colours.
List<NativeSheetCalendarMark> calendarMonthMarks(
  CalendarAgendaData data,
  CalendarWallTime month,
  CalendarZone zone,
) {
  final end = month.addDays(calendarDaysInMonth(month));
  final colors = <String, List<int>>{};
  for (final item in data.items) {
    final span = calendarItemSpan(item, zone);
    final color = calendarItemColor(item, data);
    var day = span.first.compareTo(month) < 0 ? month : span.first;
    while (day.compareTo(span.last) <= 0 && day.compareTo(end) < 0) {
      final shown = colors.putIfAbsent(calendarDayKey(day), () => <int>[]);
      if (!shown.contains(color) && shown.length < 3) shown.add(color);
      day = day.addDays(1);
    }
  }
  final keys = colors.keys.toList()..sort();
  return [
    for (final key in keys)
      NativeSheetCalendarMark(day: key, colors: colors[key]!),
  ];
}

/// What the month page shows.
@immutable
class CalendarMonthState {
  const CalendarMonthState({
    required this.available,
    required this.month,
    required this.selectedDay,
    required this.today,
    this.data,
    this.failure,
    this.scheduledTasksOpen = false,
  });

  /// The server and account allow the calendar.
  final bool available;

  /// The first day of the month the grid shows.
  final CalendarWallTime month;
  final CalendarWallTime selectedDay;
  final CalendarWallTime today;

  /// The month's agenda, or null while it is first read.
  final CalendarAgendaData? data;

  /// Why the month could not be read, with a row to read it again.
  final String? failure;

  /// Scheduled tasks can be opened, so their entries lead to them.
  final bool scheduledTasksOpen;
}

/// The calendar's month page: the system month grid over the chosen day's
/// agenda, a "+" in the bar adding an event, and rows going back to today
/// and listing the calendars. Returns the page and the pages it leads to.
({NativeSheetDetailConfig page, List<NativeSheetDetailConfig> leadsTo})
buildCalendarMonthPage(
  AppLocalizations l10n,
  CalendarClock clock,
  CalendarZone zone,
  CalendarMonthState state,
) {
  const pageId = calendarMonthPageId;
  if (!state.available) {
    return (
      page: NativeSheetDetailConfig(
        id: pageId,
        title: l10n.calendarTitle,
        items: [_note('$pageId-unavailable', l10n.calendarUnavailable)],
      ),
      leadsTo: const <NativeSheetDetailConfig>[],
    );
  }
  final data = state.data;
  final day = state.selectedDay;
  final leadsTo = <NativeSheetDetailConfig>[];
  final dayRows = <NativeSheetItemConfig>[];
  if (data == null) {
    if (state.failure == null) {
      dayRows.add(_note('$pageId-loading', l10n.loadingShort, 'hourglass'));
    }
  } else {
    for (final item in calendarItemsOn(data, day, zone)) {
      final row = _agendaRow(l10n, clock, zone, data, item, day, state);
      dayRows.add(row);
      if (row.id.startsWith(calendarEventPagePrefix)) {
        leadsTo.add(_loading(l10n, row.id, l10n.calendarEventDetailTitle));
      } else if (item is ScheduledTaskCalendarEntry &&
          item.automationId != null &&
          row.id == scheduledTaskPageId(item.automationId!)) {
        leadsTo.add(_loading(l10n, row.id, item.title));
      }
    }
    if (dayRows.isEmpty) {
      dayRows.add(_note('$pageId-empty', l10n.calendarDayEmpty, 'calendar'));
    }
  }
  final newEventPage = calendarEditorPageId(calendarNewEventKey);
  final writable = data?.writableCalendars.isNotEmpty ?? false;
  leadsTo
    ..add(_loading(l10n, newEventPage, l10n.calendarNewEventTitle))
    ..add(_loading(l10n, calendarCalendarsPageId, l10n.calendarCalendarsTitle));
  final atToday =
      day.sameDate(state.today) &&
      state.month.sameDate(calendarMonthOf(state.today));
  return (
    page: NativeSheetDetailConfig(
      id: pageId,
      title: l10n.calendarTitle,
      // New Event is the bar's "+", as in Calendar, pushing the editor.
      trailingActionDetailId: writable ? newEventPage : null,
      trailingActionSfSymbol: writable ? 'plus' : null,
      calendar: NativeSheetMonthCalendarConfig(
        id: calendarGridId,
        month: calendarDayKey(state.month),
        selectedDay: calendarDayKey(day),
        marks: data == null
            ? const <NativeSheetCalendarMark>[]
            : calendarMonthMarks(data, state.month, zone),
      ),
      sections: [
        if (state.failure case final failure?)
          NativeSheetSectionConfig(
            items: [
              _warning('$pageId-failure', failure),
              NativeSheetItemConfig(
                id: calendarRetryRowId,
                title: l10n.retry,
                sfSymbol: 'arrow.clockwise',
                accent: true,
                showsDisclosure: false,
              ),
            ],
          )
        else if (data?.stale ?? false)
          NativeSheetSectionConfig(
            items: [
              _note('$pageId-stale', l10n.calendarStale),
              // Read again from here, as the failure above offers.
              NativeSheetItemConfig(
                id: calendarRetryRowId,
                title: l10n.retry,
                sfSymbol: 'arrow.clockwise',
                accent: true,
                showsDisclosure: false,
              ),
            ],
          ),
        NativeSheetSectionConfig(
          title: calendarDayHeadingText(
            clock,
            l10n,
            day: day,
            today: state.today,
          ),
          items: dayRows,
        ),
        NativeSheetSectionConfig(
          footer: l10n.calendarTimezoneNote,
          items: [
            if (!atToday)
              NativeSheetItemConfig(
                id: calendarTodayRowId,
                title: l10n.calendarToday,
                sfSymbol: 'calendar.badge.clock',
                showsDisclosure: false,
              ),
            NativeSheetItemConfig(
              id: calendarCalendarsPageId,
              title: l10n.calendarManageCalendars,
              sfSymbol: 'list.bullet',
            ),
          ],
        ),
      ],
    ),
    leadsTo: leadsTo,
  );
}

NativeSheetItemConfig _agendaRow(
  AppLocalizations l10n,
  CalendarClock clock,
  CalendarZone zone,
  CalendarAgendaData data,
  CalendarAgendaItem item,
  CalendarWallTime day,
  CalendarMonthState state,
) {
  final color = calendarItemColor(item, data);
  switch (item) {
    case final CalendarEventModel event:
      final time = calendarRowTimeText(
        clock,
        l10n,
        startNs: event.startAtNs,
        endNs: event.endAtNs,
        allDay: event.allDay,
        zone: zone,
        day: day,
      );
      final access = data.access;
      final invited = access?.canRsvp(event) ?? false;
      return NativeSheetItemConfig(
        id: calendarEventPageId(event.key),
        title: event.title.isEmpty ? l10n.calendarUntitledEvent : event.title,
        subtitle: [
          time,
          ?event.location,
          if (event.isRecurring) l10n.calendarRepeatsMarker,
          if (invited) rsvpLabel(l10n, access?.ownAnswer(event)),
        ].join(' · '),
        sfSymbol: 'circle.fill',
        symbolColor: color,
      );
    case final ScheduledTaskCalendarEntry entry:
      final time = calendarRowTimeText(
        clock,
        l10n,
        startNs: entry.startAtNs,
        endNs: null,
        allDay: false,
        zone: zone,
        day: day,
      );
      final label = !entry.isRun
          ? l10n.calendarScheduledUpcoming
          : entry.failed
          ? l10n.calendarScheduledRunFailed
          : l10n.calendarScheduledRunFinished;
      final automationId = entry.automationId;
      final opens = automationId != null && state.scheduledTasksOpen;
      // What a past run made opens over the app; anything else is the task's
      // own page, in Settings.
      final result =
          entry.resultChatId != null || entry.resultChannelId != null;
      return NativeSheetItemConfig(
        id: opens && !result
            ? scheduledTaskPageId(automationId)
            : calendarScheduledRowId(entry.key),
        title: entry.title,
        subtitle: '$time · $label',
        sfSymbol: 'clock.arrow.circlepath',
        symbolColor: color,
        kind: opens ? NativeSheetItemKind.navigation : NativeSheetItemKind.info,
        showsDisclosure: opens,
      );
  }
}

/// How reading an event's own record went.
enum CalendarEventDetail {
  /// Not asked: the calendar is not one the account can read, so the record
  /// would be refused and the agenda copy is all there is.
  skipped,
  loading,
  fresh,

  /// The server refused the read: access to the calendar is gone.
  denied,

  /// The event no longer exists.
  gone,

  /// The read failed for another reason; the agenda copy stands.
  failed,
}

/// What an event's page shows.
@immutable
class CalendarEventState {
  const CalendarEventState({
    required this.event,
    this.fresh,
    this.detail = CalendarEventDetail.skipped,
    this.data,
    this.answer,
    this.responding = false,
    this.deleting = false,
    this.error,
  });

  /// The agenda's copy, which is what is shown and answered from.
  final CalendarEventModel event;

  /// The event's own record, when it was read.
  final CalendarEventModel? fresh;
  final CalendarEventDetail detail;
  final CalendarAgendaData? data;

  /// The answer just chosen, shown while it is sent.
  final CalendarRsvp? answer;
  final bool responding;
  final bool deleting;
  final String? error;
}

/// The page of one event: when and where, its calendar, repeat, organizer
/// and people, its description, the account's answer when it is invited,
/// and Edit and Delete when the account may change it. Returns the page and
/// the editor its Edit row leads to.
({NativeSheetDetailConfig page, List<NativeSheetDetailConfig> leadsTo})
buildCalendarEventPage(
  AppLocalizations l10n,
  CalendarClock clock,
  CalendarZone zone,
  CalendarEventState state,
) {
  final event = state.event;
  final key = event.key;
  final pageId = calendarEventPageId(key);
  final data = state.data;
  final access = data?.access;
  final calendars = data?.calendars ?? const <CalendarModel>[];
  final calendar = calendars.where((c) => c.id == event.calendarId).firstOrNull;
  final shown = state.fresh ?? event;
  final loading = state.detail == CalendarEventDetail.loading;
  final canEdit =
      access != null &&
      access.canEdit(event, calendars) &&
      state.detail != CalendarEventDetail.denied &&
      state.detail != CalendarEventDetail.gone &&
      !loading;
  final invited = access?.canRsvp(shown) ?? false;
  final answer = state.answer ?? access?.ownAnswer(shown);
  final answered = answer != null && answer != CalendarRsvp.pending;
  final title = event.title.isEmpty ? l10n.calendarUntitledEvent : event.title;
  final color = data == null ? _fallbackColor : calendarItemColor(event, data);
  final busy = state.responding || state.deleting;
  final editorPage = calendarEditorPageId(calendarEditorKey(event.id));
  final description = (shown.description ?? '').trim();
  final page = NativeSheetDetailConfig(
    id: pageId,
    title: l10n.calendarEventDetailTitle,
    sections: [
      if (state.error case final error?)
        NativeSheetSectionConfig(items: [_warning('$pageId-error', error)]),
      if (state.detail == CalendarEventDetail.gone)
        NativeSheetSectionConfig(
          items: [_warning('$pageId-gone', l10n.calendarEventGone)],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: '$pageId-title',
            title: title,
            subtitle: calendarWhenText(
              clock,
              l10n,
              startNs: event.startAtNs,
              endNs: event.endAtNs,
              allDay: event.allDay,
              zone: zone,
            ),
            sfSymbol: 'circle.fill',
            symbolColor: color,
            kind: NativeSheetItemKind.info,
          ),
          if (event.location case final location?)
            _note(
              '$pageId-location',
              l10n.calendarFieldLocation,
              'mappin.and.ellipse',
              location,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        footer: event.isRecurring ? l10n.calendarEventSeriesNote : null,
        items: [
          if (calendar != null)
            NativeSheetItemConfig(
              id: '$pageId-calendar',
              title: l10n.calendarFieldCalendar,
              subtitle: calendar.name,
              sfSymbol: 'circle.fill',
              symbolColor: calendarColorArgb(calendar.color) ?? _fallbackColor,
              kind: NativeSheetItemKind.info,
            ),
          if (event.isRecurring)
            _note(
              '$pageId-repeat',
              l10n.calendarFieldRepeat,
              'repeat',
              repeatLabel(l10n, CalendarRepeat.fromRule(event.rrule)),
            ),
          if (event.organizerName case final organizer?)
            _note(
              '$pageId-organizer',
              l10n.calendarFieldOrganizer,
              'person',
              organizer,
            ),
          if (shown.attendees.isNotEmpty)
            _note(
              '$pageId-people',
              l10n.calendarFieldAttendees,
              'person.2',
              '${shown.attendees.length}',
            ),
        ],
      ),
      if (description.isNotEmpty)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$pageId-description',
              title: l10n.calendarFieldDescription,
              sfSymbol: 'text.alignleft',
              kind: NativeSheetItemKind.readOnlyText,
              value: description,
            ),
          ],
        ),
      if (invited)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: calendarEventRowId('rsvp', key),
              title: l10n.calendarRsvpPrompt,
              subtitle: answered ? null : rsvpLabel(l10n, CalendarRsvp.pending),
              sfSymbol: 'envelope.open',
              kind: NativeSheetItemKind.segment,
              value: answered ? answer.name : '',
              pending: state.responding ? true : null,
              disabled: busy,
              options: [
                for (final status in const [
                  CalendarRsvp.accepted,
                  CalendarRsvp.tentative,
                  CalendarRsvp.declined,
                ])
                  NativeSheetOptionConfig(
                    id: status.name,
                    label: rsvpLabel(l10n, status),
                  ),
              ],
            ),
          ],
        ),
      if (loading)
        NativeSheetSectionConfig(
          items: [_note('$pageId-loading', l10n.loadingShort, 'hourglass')],
        )
      else if (canEdit)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: editorPage,
              title: event.isRecurring
                  ? l10n.calendarEventEditSeries
                  : l10n.calendarEventEdit,
              sfSymbol: 'pencil',
              accent: true,
              disabled: busy,
            ),
            NativeSheetItemConfig(
              id: calendarEventRowId('delete', key),
              title: event.isRecurring
                  ? l10n.calendarEventDeleteSeries
                  : l10n.calendarEventDelete,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              pending: state.deleting ? true : null,
              disabled: busy,
              confirmMessage: event.isRecurring
                  ? l10n.calendarEventDeleteSeriesConfirm(title)
                  : l10n.calendarEventDeleteConfirm(title),
            ),
          ],
        )
      else if (state.detail != CalendarEventDetail.gone)
        NativeSheetSectionConfig(
          items: [
            _note(
              '$pageId-read-only',
              invited
                  ? l10n.calendarEventReadOnly
                  : l10n.calendarEventReadOnlyNotInvited,
              'lock',
            ),
          ],
        ),
    ],
  );
  return (
    page: page,
    leadsTo: [
      if (canEdit)
        _loading(
          l10n,
          editorPage,
          event.isRecurring
              ? l10n.calendarEditSeriesTitle
              : l10n.calendarEditEventTitle,
        ),
    ],
  );
}

/// What an event editor shows.
@immutable
class CalendarEditorState {
  const CalendarEditorState({
    required this.key,
    this.draft,
    this.loadFailure,
    this.data,
    this.names = const <String, String>{},
    this.titleTouched = false,
    this.saveAttempted = false,
    this.saving = false,
    this.dirty = false,
    this.error,
  });

  final String key;

  /// The event being edited, or null while the stored event is read.
  final CalendarEventDraft? draft;

  /// Why the stored event could not be read for editing.
  final String? loadFailure;
  final CalendarAgendaData? data;

  /// Names for people picked in this editor; the server returns none.
  final Map<String, String> names;
  final bool titleTouched;
  final bool saveAttempted;
  final bool saving;

  /// Something was changed that leaving would lose.
  final bool dirty;
  final String? error;
}

/// A wall time as a date or time row holds it.
String calendarRowDateValue(CalendarWallTime wall) => nativeSheetDateValue(
  DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute),
);

/// The editor of a new event or of a stored one (a recurring event's whole
/// series). Done saves; leaving with changes asks first. Returns the page
/// and the page adding people.
({NativeSheetDetailConfig page, List<NativeSheetDetailConfig> leadsTo})
buildCalendarEditorPage(AppLocalizations l10n, CalendarEditorState state) {
  final key = state.key;
  final pageId = calendarEditorPageId(key);
  final draft = state.draft;
  String row(String field) => calendarEditorRowId(field, key);
  if (draft == null) {
    final failure = state.loadFailure;
    return (
      page: NativeSheetDetailConfig(
        id: pageId,
        title: l10n.calendarEditEventTitle,
        items: [
          if (failure != null) ...[
            _warning('$pageId-failure', failure),
            NativeSheetItemConfig(
              id: row('retry'),
              title: l10n.retry,
              sfSymbol: 'arrow.clockwise',
              accent: true,
              showsDisclosure: false,
            ),
          ] else
            _note('$pageId-loading', l10n.loadingShort, 'hourglass'),
        ],
      ),
      leadsTo: const <NativeSheetDetailConfig>[],
    );
  }
  final data = state.data;
  final issues = draft.issues;
  final recurring = draft.original?.isRecurring ?? false;
  final noWritableCalendar =
      data != null && data.writableCalendars.isEmpty && draft.isNew;
  final shownIssues = [
    for (final issue in issues)
      if (switch (issue) {
        CalendarDraftIssue.titleRequired =>
          state.titleTouched || state.saveAttempted,
        CalendarDraftIssue.calendarRequired =>
          !noWritableCalendar && state.saveAttempted,
        CalendarDraftIssue.endBeforeStart => true,
      })
        issue,
  ];
  final writable = data?.writableCalendars ?? const <CalendarModel>[];
  final current = data?.calendars
      .where((c) => c.id == draft.calendarId)
      .firstOrNull;
  // The event's calendar stays on offer while it is the event's, even when
  // the account can no longer write to it.
  final calendarChoices = [
    ...writable,
    if (current != null && !writable.any((c) => c.id == current.id)) current,
  ];
  final repeats = [
    for (final repeat in CalendarRepeat.values)
      if (repeat != CalendarRepeat.custom ||
          draft.repeat == CalendarRepeat.custom)
        repeat,
  ];
  final end = draft.end;
  final whenNotes = [
    if (draft.repeat == CalendarRepeat.custom) l10n.calendarRepeatKept,
    if (draft.repeat != CalendarRepeat.none)
      l10n.calendarRecurrenceTimezoneNote,
  ];
  final peoplePage = calendarPeoplePageId(key);
  final page = NativeSheetDetailConfig(
    id: pageId,
    title: draft.isNew
        ? l10n.calendarNewEventTitle
        : recurring
        ? l10n.calendarEditSeriesTitle
        : l10n.calendarEditEventTitle,
    confirmActionId: row('save'),
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: state.saving,
    edited: state.dirty,
    sections: [
      if (state.error != null || shownIssues.isNotEmpty)
        NativeSheetSectionConfig(
          items: [
            if (state.error case final error?) _warning('$pageId-error', error),
            for (final issue in shownIssues)
              _warning(
                '$pageId-issue-${issue.name}',
                draftIssueText(l10n, issue),
              ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: row('title'),
            title: l10n.calendarFieldTitle,
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: draft.title,
            placeholder: l10n.calendarFieldTitle,
          ),
          NativeSheetItemConfig(
            id: row('location'),
            title: l10n.calendarFieldLocation,
            sfSymbol: 'mappin.and.ellipse',
            kind: NativeSheetItemKind.textField,
            value: draft.location,
            placeholder: l10n.calendarFieldLocation,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        footer: whenNotes.isEmpty ? null : whenNotes.join('\n\n'),
        items: [
          NativeSheetItemConfig(
            id: row('all-day'),
            title: l10n.calendarFieldAllDay,
            sfSymbol: 'sun.max',
            kind: NativeSheetItemKind.toggle,
            value: draft.allDay,
          ),
          NativeSheetItemConfig(
            id: row('start-date'),
            title: l10n.calendarFieldStarts,
            sfSymbol: 'calendar',
            kind: NativeSheetItemKind.date,
            value: calendarRowDateValue(draft.start),
          ),
          if (!draft.allDay)
            NativeSheetItemConfig(
              id: row('start-time'),
              title: l10n.calendarFieldStartTime,
              sfSymbol: 'clock',
              kind: NativeSheetItemKind.time,
              value: calendarRowDateValue(draft.start),
            ),
          if (end != null) ...[
            NativeSheetItemConfig(
              id: row('end-date'),
              title: l10n.calendarFieldEnds,
              sfSymbol: 'calendar',
              kind: NativeSheetItemKind.date,
              value: calendarRowDateValue(end),
            ),
            if (!draft.allDay)
              NativeSheetItemConfig(
                id: row('end-time'),
                title: l10n.calendarFieldEndTime,
                sfSymbol: 'clock',
                kind: NativeSheetItemKind.time,
                value: calendarRowDateValue(end),
              ),
            NativeSheetItemConfig(
              id: row('remove-end'),
              title: l10n.calendarRemoveEnd,
              sfSymbol: 'minus.circle',
              showsDisclosure: false,
            ),
          ] else
            NativeSheetItemConfig(
              id: row('add-end'),
              title: l10n.calendarAddEnd,
              sfSymbol: 'plus.circle',
              accent: true,
              showsDisclosure: false,
            ),
          NativeSheetItemConfig(
            id: row('repeat'),
            title: l10n.calendarFieldRepeat,
            sfSymbol: 'repeat',
            kind: NativeSheetItemKind.segment,
            value: draft.repeat.name,
            options: [
              for (final repeat in repeats)
                NativeSheetOptionConfig(
                  id: repeat.name,
                  label: repeatLabel(l10n, repeat),
                ),
            ],
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          if (noWritableCalendar)
            _note('$pageId-no-calendar', l10n.calendarNoWritableCalendar)
          else
            NativeSheetItemConfig(
              id: row('calendar'),
              title: l10n.calendarFieldCalendar,
              subtitle: current == null ? l10n.calendarChooseCalendar : null,
              sfSymbol: 'circle.fill',
              symbolColor: calendarColorArgb(current?.color) ?? _fallbackColor,
              kind: NativeSheetItemKind.segment,
              value: draft.calendarId,
              options: [
                for (final calendar in calendarChoices)
                  NativeSheetOptionConfig(
                    id: calendar.id,
                    label: calendar.name,
                  ),
              ],
            ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.calendarFieldAttendees,
        footer: draft.attendees.isEmpty ? null : l10n.calendarAttendeesNote,
        items: [
          for (final person in draft.attendees)
            _personRow(l10n, key, person, state.names),
          NativeSheetItemConfig(
            id: peoplePage,
            title: l10n.calendarAddPeople,
            sfSymbol: 'person.badge.plus',
            accent: true,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: row('description'),
            title: l10n.calendarFieldDescription,
            sfSymbol: 'text.alignleft',
            kind: NativeSheetItemKind.multilineTextField,
            value: draft.description,
            placeholder: l10n.calendarFieldDescription,
          ),
        ],
      ),
    ],
  );
  return (
    page: page,
    leadsTo: [_loading(l10n, peoplePage, l10n.calendarAddPeople)],
  );
}

NativeSheetItemConfig _personRow(
  AppLocalizations l10n,
  String key,
  CalendarDraftAttendee person,
  Map<String, String> names,
) {
  final name =
      person.name ?? names[person.userId] ?? l10n.calendarInvitedPerson;
  return NativeSheetItemConfig(
    id:
        '${calendarEditorRowId('person', key)}:'
        '${Uri.encodeComponent(person.userId)}',
    title: name,
    avatarName: name,
    kind: NativeSheetItemKind.info,
    rowActions: [
      NativeSheetRowAction(
        id: calendarEditorPersonRemoveId(key, person.userId),
        label: l10n.calendarRemovePerson(name),
        sfSymbol: 'minus.circle',
        destructive: true,
      ),
    ],
  );
}

/// What the page adding people shows.
@immutable
class CalendarPeopleState {
  const CalendarPeopleState({
    required this.key,
    this.query = '',
    this.results,
    this.failed = false,
    this.invited = const <String>{},
  });

  /// The editor the people are added to.
  final String key;
  final String query;

  /// The people found for [query], or null while they are searched for.
  final List<WorkspacePrincipalPreview>? results;
  final bool failed;

  /// Who the event already has.
  final Set<String> invited;
}

/// The page adding people to an event: a search field over the people
/// found; tapping one adds them and goes back to the editor.
NativeSheetDetailConfig buildCalendarPeoplePage(
  AppLocalizations l10n,
  CalendarPeopleState state,
) {
  final key = state.key;
  final pageId = calendarPeoplePageId(key);
  final results = state.results;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.calendarAddPeople,
    search: NativeSheetSearchConfig(
      id: calendarPeopleSearchId(key),
      placeholder: l10n.workspacePrincipalSearchHint,
      value: state.query,
    ),
    items: [
      if (state.failed)
        _warning('$pageId-failed', l10n.workspacePrincipalLoadFailed)
      else if (results == null)
        _note('$pageId-loading', l10n.loadingShort, 'hourglass')
      else if (results.isEmpty)
        _note('$pageId-none', l10n.workspacePrincipalNoResults, 'person')
      else
        for (final person in results)
          NativeSheetItemConfig(
            id: calendarPeopleAddId(key, person.id),
            title: person.name,
            subtitle: person.email,
            avatarName: person.name,
            showsDisclosure: false,
            checked: state.invited.contains(person.id),
            disabled: state.invited.contains(person.id),
          ),
    ],
  );
}

/// What the calendars page shows.
@immutable
class CalendarCalendarsState {
  const CalendarCalendarsState({
    this.data,
    this.busy = false,
    this.error,
    this.failure,
  });

  final CalendarAgendaData? data;
  final bool busy;
  final String? error;

  /// Why the agenda, and with it the calendars, could not be read.
  final String? failure;
}

/// The calendars the agenda shows: all of them when the filter is empty.
Set<String> calendarVisibleIds(CalendarAgendaData data) {
  final all = {for (final c in data.calendars) c.id};
  final chosen = data.filter.intersection(all);
  return chosen.isEmpty ? all : chosen;
}

List<String> _badges(
  AppLocalizations l10n,
  CalendarModel calendar,
  CalendarAccess? access,
) {
  if (access == null || calendar.isVirtual) return const [];
  final owned = access.owns(calendar);
  return [
    if (owned && calendar.isDefault) l10n.calendarDefaultBadge,
    if (!owned) l10n.calendarSharedBadge,
    if (!access.canWrite(calendar)) l10n.calendarReadOnlyBadge,
  ];
}

/// The account's calendars: each checked while its events show (tap to
/// show or hide them), its menu making it the default; and a row making a
/// new one. Returns the page and the new calendar form.
({NativeSheetDetailConfig page, List<NativeSheetDetailConfig> leadsTo})
buildCalendarCalendarsPage(
  AppLocalizations l10n,
  CalendarCalendarsState state,
) {
  const pageId = calendarCalendarsPageId;
  final data = state.data;
  if (data == null) {
    final failure = state.failure;
    return (
      // Not read: the page says why, with Retry, as the month does.
      page: failure == null
          ? _loading(l10n, pageId, l10n.calendarCalendarsTitle)
          : NativeSheetDetailConfig(
              id: pageId,
              title: l10n.calendarCalendarsTitle,
              items: [
                _warning('$pageId-failure', failure),
                NativeSheetItemConfig(
                  id: calendarRetryRowId,
                  title: l10n.retry,
                  sfSymbol: 'arrow.clockwise',
                  accent: true,
                  showsDisclosure: false,
                ),
              ],
            ),
      leadsTo: const <NativeSheetDetailConfig>[],
    );
  }
  final access = data.access;
  final calendars = [
    for (final calendar in data.calendars)
      if (!calendar.isVirtual || data.calendars.length > 1) calendar,
  ];
  final filterable = data.calendars.length > 1;
  final visible = calendarVisibleIds(data);
  return (
    page: NativeSheetDetailConfig(
      id: pageId,
      title: l10n.calendarCalendarsTitle,
      sections: [
        if (state.error case final error?)
          NativeSheetSectionConfig(items: [_warning('$pageId-error', error)]),
        NativeSheetSectionConfig(
          footer: filterable ? l10n.calendarVisibilityFooter : null,
          items: [
            if (calendars.isEmpty)
              _note('$pageId-empty', l10n.calendarEmptyCalendars, 'calendar'),
            for (final calendar in calendars)
              _calendarRow(
                l10n,
                calendar,
                access,
                filterable: filterable,
                shown: visible.contains(calendar.id),
                busy: state.busy,
              ),
          ],
        ),
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: calendarNewCalendarPageId,
              title: l10n.calendarNewCalendar,
              sfSymbol: 'plus.circle',
              accent: true,
              disabled: state.busy,
            ),
          ],
        ),
      ],
    ),
    leadsTo: [
      _loading(l10n, calendarNewCalendarPageId, l10n.calendarNewCalendar),
    ],
  );
}

NativeSheetItemConfig _calendarRow(
  AppLocalizations l10n,
  CalendarModel calendar,
  CalendarAccess? access, {
  required bool filterable,
  required bool shown,
  required bool busy,
}) {
  final badges = _badges(l10n, calendar, access);
  // Only the account's own calendars can be its default; another owner's
  // default flag is theirs.
  final canMakeDefault =
      access != null &&
      !calendar.isVirtual &&
      access.canMakeDefault(calendar) &&
      !calendar.isDefault;
  return NativeSheetItemConfig(
    id: calendarToggleRowId(calendar.id),
    title: calendar.name,
    subtitle: badges.isEmpty ? null : badges.join(' · '),
    sfSymbol: 'circle.fill',
    symbolColor: calendarColorArgb(calendar.color) ?? _fallbackColor,
    kind: filterable
        ? NativeSheetItemKind.navigation
        : NativeSheetItemKind.info,
    showsDisclosure: false,
    checked: filterable && shown,
    // The last calendar shown stays shown: tapping it does nothing (see
    // the module), while its menu, Make Default, stays reachable.
    disabled: busy,
    rowActions: [
      if (canMakeDefault)
        NativeSheetRowAction(
          id: calendarMakeDefaultId(calendar.id),
          label: l10n.calendarMakeDefault,
          sfSymbol: 'star',
        ),
    ],
  );
}

/// What the new calendar form holds.
@immutable
class CalendarNewState {
  const CalendarNewState({
    this.name = '',
    this.color = '#3b82f6',
    this.nameMissing = false,
    this.creating = false,
    this.error,
  });

  final String name;

  /// `#rrggbb`.
  final String color;
  final bool nameMissing;
  final bool creating;
  final String? error;

  bool get dirty =>
      name.trim().isNotEmpty || color != calendarColorPalette.first.hex;
}

/// The form making a new calendar: its name and colour; Create makes it.
NativeSheetDetailConfig buildCalendarNewPage(
  AppLocalizations l10n,
  CalendarNewState state,
) {
  const pageId = calendarNewCalendarPageId;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.calendarNewCalendar,
    confirmActionId: calendarNewCreateId,
    confirmActionLabel: l10n.calendarCreateCalendar,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: state.creating,
    edited: state.dirty,
    items: [
      if (state.error case final error?) _warning('$pageId-error', error),
      if (state.nameMissing && state.name.trim().isEmpty)
        _warning('$pageId-name-missing', l10n.calendarNameRequired),
      NativeSheetItemConfig(
        id: calendarNewNameRowId,
        title: l10n.calendarNewCalendarHint,
        sfSymbol: 'textformat',
        kind: NativeSheetItemKind.textField,
        value: state.name,
        placeholder: l10n.calendarNewCalendarHint,
      ),
      NativeSheetItemConfig(
        id: calendarNewColorRowId,
        title: l10n.calendarColorName('other'),
        sfSymbol: 'circle.fill',
        symbolColor: calendarColorArgb(state.color) ?? _fallbackColor,
        kind: NativeSheetItemKind.segment,
        value: state.color,
        options: [
          for (final color in calendarColorPalette)
            NativeSheetOptionConfig(
              id: color.hex,
              label: l10n.calendarColorName(color.name),
            ),
        ],
      ),
    ],
  );
}
