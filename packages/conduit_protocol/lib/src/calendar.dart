import 'package:freezed_annotation/freezed_annotation.dart';

part 'calendar.freezed.dart';
part 'calendar.g.dart';

/// A calendar day and a wall clock in the Mac's own time zone, to the minute.
/// A day alone leaves [hour] and [minute] at zero.
@freezed
abstract class CalendarWallTime with _$CalendarWallTime {
  const factory CalendarWallTime({
    required int year,
    required int month,
    required int day,
    @Default(0) int hour,
    @Default(0) int minute,
  }) = _CalendarWallTime;

  factory CalendarWallTime.fromJson(Map<String, dynamic> json) =>
      _$CalendarWallTimeFromJson(json);
}

/// One of the account's calendars on its Open WebUI server.
@freezed
abstract class CalendarDto with _$CalendarDto {
  const factory CalendarDto({
    required String id,
    @Default('') String name,

    /// `#rrggbb` as the server stored it, or null.
    String? color,

    /// The account's own default calendar (a shared calendar's flag is its
    /// owner's and is not reported here).
    @Default(false) bool isDefault,

    /// The server's read-only calendar of scheduled-task runs.
    @Default(false) bool scheduled,

    /// The account owns it.
    @Default(false) bool owned,

    /// Events can be created in it, moved into it and edited in it.
    @Default(false) bool writable,

    /// It can be made the account's default (one of its own, not already).
    @Default(false) bool canMakeDefault,

    /// The agenda shows its events.
    @Default(true) bool visible,
  }) = _CalendarDto;

  factory CalendarDto.fromJson(Map<String, dynamic> json) =>
      _$CalendarDtoFromJson(json);
}

/// What an agenda row says about its time on its day.
@freezed
abstract class CalendarRowTimeDto with _$CalendarRowTimeDto {
  const factory CalendarRowTimeDto({
    /// `allDay`, `at` (a moment), `range` (start and end on this day),
    /// `startsAt` (the first day of a longer event) or `endsAt` (its last).
    required String kind,
    CalendarWallTime? start,
    CalendarWallTime? end,
  }) = _CalendarRowTimeDto;

  factory CalendarRowTimeDto.fromJson(Map<String, dynamic> json) =>
      _$CalendarRowTimeDtoFromJson(json);
}

/// One thing on the agenda: a stored event (or one occurrence of a recurring
/// one), or a scheduled task's coming run or past run.
@freezed
abstract class CalendarItemDto with _$CalendarItemDto {
  const factory CalendarItemDto({
    /// Unique within one agenda: every `calendar.*` call names an item by
    /// it.
    required String key,

    /// `event` or `scheduled`.
    required String kind,

    /// The stored event's id (a series' id for an occurrence), or the
    /// server's `auto_…`/`run_…` id for a scheduled entry.
    required String id,
    @Default('') String calendarId,
    @Default('') String title,
    String? location,

    /// The event's colour, else its calendar's (`#rrggbb`), or null.
    String? color,
    @Default(false) bool recurring,
    @Default(false) bool allDay,
    @Default(false) bool cancelled,
    required CalendarWallTime start,
    CalendarWallTime? end,

    /// The last day the item covers (the start's day for a moment).
    CalendarWallTime? lastDay,

    /// What its row says on the day it is listed under.
    required CalendarRowTimeDto time,

    /// The account is one of the invited people.
    @Default(false) bool invited,

    /// The account's own answer when [invited]: `accepted`, `tentative`,
    /// `declined` or `pending`.
    String? answer,

    /// The account may change or delete the event.
    @Default(false) bool editable,

    /// A scheduled entry's task, when the server named one.
    String? automationId,

    /// A past run's id, chat and channel.
    String? runId,
    String? resultChatId,
    String? resultChannelId,

    /// A scheduled entry's state: `upcoming`, `finished` or `failed`.
    String? scheduledState,
  }) = _CalendarItemDto;

  factory CalendarItemDto.fromJson(Map<String, dynamic> json) =>
      _$CalendarItemDtoFromJson(json);
}

/// One day of the agenda that has something on it.
@freezed
abstract class CalendarAgendaDay with _$CalendarAgendaDay {
  const factory CalendarAgendaDay({
    required CalendarWallTime day,
    @Default(<CalendarItemDto>[]) List<CalendarItemDto> items,
  }) = _CalendarAgendaDay;

  factory CalendarAgendaDay.fromJson(Map<String, dynamic> json) =>
      _$CalendarAgendaDayFromJson(json);
}

/// Reply to `calendar.agenda` and the calls that change it: the calendars
/// and the agenda for a bounded stretch of days, in the Mac's time zone.
@freezed
abstract class CalendarAgenda with _$CalendarAgenda {
  const factory CalendarAgenda({
    /// The server and account allow the calendar.
    @Default(false) bool available,

    /// Nothing could be read: `unavailable`, `accountChanged` or `failed`.
    /// Null when there is an agenda.
    String? failure,

    /// A change went through but reading the agenda back failed: it may
    /// not show it yet.
    @Default(false) bool stale,

    /// The first day of the range, and the day after its last.
    CalendarWallTime? firstDay,
    CalendarWallTime? endDay,
    @Default(14) int dayCount,
    CalendarWallTime? today,
    @Default(<CalendarDto>[]) List<CalendarDto> calendars,

    /// More than one calendar: each can be shown or hidden.
    @Default(false) bool filterable,

    /// The scheduled-task entries are listed (the account may use
    /// scheduled tasks).
    @Default(false) bool scheduledTasks,

    /// Some calendar takes new events.
    @Default(false) bool canCreate,
    @Default(<CalendarAgendaDay>[]) List<CalendarAgendaDay> days,
  }) = _CalendarAgenda;

  factory CalendarAgenda.fromJson(Map<String, dynamic> json) =>
      _$CalendarAgendaFromJson(json);
}

/// Params for `calendar.agenda`. With nothing set it answers with the
/// agenda as it stands (loading it the first time).
@freezed
abstract class CalendarAgendaQuery with _$CalendarAgendaQuery {
  const factory CalendarAgendaQuery({
    /// Moves the range to start on this day.
    CalendarWallTime? firstDay,

    /// Moves the range by this many pages (−1 earlier, 1 later).
    @Default(0) int shift,

    /// Moves the range to start today.
    @Default(false) bool today,

    /// Reads the server again even when the range stays.
    @Default(false) bool refresh,
  }) = _CalendarAgendaQuery;

  factory CalendarAgendaQuery.fromJson(Map<String, dynamic> json) =>
      _$CalendarAgendaQueryFromJson(json);
}

/// Params for `calendar.setVisible`. The last shown calendar stays shown.
@freezed
abstract class CalendarVisibility with _$CalendarVisibility {
  const factory CalendarVisibility({
    required String calendarId,
    required bool visible,
  }) = _CalendarVisibility;

  factory CalendarVisibility.fromJson(Map<String, dynamic> json) =>
      _$CalendarVisibilityFromJson(json);
}

/// Params for `calendar.makeDefault`.
@freezed
abstract class CalendarRef with _$CalendarRef {
  const factory CalendarRef({required String calendarId}) = _CalendarRef;

  factory CalendarRef.fromJson(Map<String, dynamic> json) =>
      _$CalendarRefFromJson(json);
}

/// Params for `calendar.createCalendar`: a private calendar of the
/// account's own.
@freezed
abstract class CalendarCreate with _$CalendarCreate {
  const factory CalendarCreate({required String name, String? color}) =
      _CalendarCreate;

  factory CalendarCreate.fromJson(Map<String, dynamic> json) =>
      _$CalendarCreateFromJson(json);
}

/// Params for `calendar.event` and `calendar.deleteEvent`: an agenda item.
@freezed
abstract class CalendarItemRef with _$CalendarItemRef {
  const factory CalendarItemRef({required String key}) = _CalendarItemRef;

  factory CalendarItemRef.fromJson(Map<String, dynamic> json) =>
      _$CalendarItemRefFromJson(json);
}

/// Reply to `calendar.event` and `calendar.respond`: what the event sheet
/// shows of an agenda item, read again from the server when the account can
/// read its calendar.
@freezed
abstract class CalendarEventDetail with _$CalendarEventDetail {
  const factory CalendarEventDetail({
    required CalendarItemDto item,
    String? description,
    String? calendarName,
    String? calendarColor,

    /// `none`, `daily`, `weekdays`, `weekly`, `monthly`, `yearly` or
    /// `custom` (a rule the editor does not write, kept as stored).
    @Default('none') String repeat,

    /// The organizer's name, when the agenda carried it.
    String? organizer,
    @Default(0) int attendeeCount,

    /// The event may be changed or deleted (a recurring event as a whole
    /// series: the server cannot change one occurrence).
    @Default(false) bool canEdit,

    /// How reading it again went: `fresh`, `skipped` (its calendar is not
    /// one the account can read), `denied`, `gone` or `failed`.
    @Default('skipped') String status,
  }) = _CalendarEventDetail;

  factory CalendarEventDetail.fromJson(Map<String, dynamic> json) =>
      _$CalendarEventDetailFromJson(json);
}

/// Params for `calendar.respond`: the account's own answer to an
/// invitation (`accepted`, `tentative` or `declined`).
@freezed
abstract class CalendarRsvpEdit with _$CalendarRsvpEdit {
  const factory CalendarRsvpEdit({
    required String key,
    required String answer,
  }) = _CalendarRsvpEdit;

  factory CalendarRsvpEdit.fromJson(Map<String, dynamic> json) =>
      _$CalendarRsvpEditFromJson(json);
}

/// An invited person, as the editor holds one.
@freezed
abstract class CalendarAttendeeDto with _$CalendarAttendeeDto {
  const factory CalendarAttendeeDto({
    required String userId,

    /// A name to show; the server does not return one with an attendee.
    String? name,
  }) = _CalendarAttendeeDto;

  factory CalendarAttendeeDto.fromJson(Map<String, dynamic> json) =>
      _$CalendarAttendeeDtoFromJson(json);
}

/// What the event editor holds.
@freezed
abstract class CalendarEventFields with _$CalendarEventFields {
  const factory CalendarEventFields({
    @Default('') String title,
    @Default('') String description,
    @Default('') String location,
    @Default('') String calendarId,
    @Default(false) bool allDay,

    /// The start's day and, unless [allDay], its wall clock.
    required CalendarWallTime start,

    /// The end's day and wall clock (an all-day event's last day), or null
    /// for none.
    CalendarWallTime? end,

    /// As [CalendarEventDetail.repeat].
    @Default('none') String repeat,
    @Default(<CalendarAttendeeDto>[]) List<CalendarAttendeeDto> attendees,
  }) = _CalendarEventFields;

  factory CalendarEventFields.fromJson(Map<String, dynamic> json) =>
      _$CalendarEventFieldsFromJson(json);
}

/// Params for `calendar.editor`: a new event ([key] null, starting on
/// [day]), or the stored event behind an agenda item.
@freezed
abstract class CalendarEditorOpen with _$CalendarEditorOpen {
  const factory CalendarEditorOpen({String? key, CalendarWallTime? day}) =
      _CalendarEditorOpen;

  factory CalendarEditorOpen.fromJson(Map<String, dynamic> json) =>
      _$CalendarEditorOpenFromJson(json);
}

/// Reply to `calendar.editor`: the draft to edit, held by the daemon for
/// the account it was opened for under [token].
@freezed
abstract class CalendarEditor with _$CalendarEditor {
  const factory CalendarEditor({
    required String token,
    @Default(true) bool isNew,

    /// A recurring event: Save changes the whole series.
    @Default(false) bool series,

    /// The stored rule a `custom` repeat keeps.
    String? rule,
    required CalendarEventFields fields,

    /// The calendars the event can go in.
    @Default(<CalendarDto>[]) List<CalendarDto> calendars,
  }) = _CalendarEditor;

  factory CalendarEditor.fromJson(Map<String, dynamic> json) =>
      _$CalendarEditorFromJson(json);
}

/// Params for `calendar.checkDraft` and `calendar.save`.
@freezed
abstract class CalendarDraftEdit with _$CalendarDraftEdit {
  const factory CalendarDraftEdit({
    required String token,
    required CalendarEventFields fields,

    /// The start just moved here: an end that would fall before it moves
    /// along, keeping the event's length.
    CalendarWallTime? movedStart,
  }) = _CalendarDraftEdit;

  factory CalendarDraftEdit.fromJson(Map<String, dynamic> json) =>
      _$CalendarDraftEditFromJson(json);
}

/// Reply to `calendar.checkDraft` and `calendar.save`.
@freezed
abstract class CalendarDraftState with _$CalendarDraftState {
  const factory CalendarDraftState({
    required CalendarEventFields fields,

    /// What stops it being saved, in the order to show it:
    /// `titleRequired`, `calendarRequired`, `endBeforeStart`.
    @Default(<String>[]) List<String> issues,

    /// The user changed something (against the stored event, or the new
    /// event's first draft).
    @Default(false) bool changed,

    /// `calendar.save` went through.
    @Default(false) bool saved,
  }) = _CalendarDraftState;

  factory CalendarDraftState.fromJson(Map<String, dynamic> json) =>
      _$CalendarDraftStateFromJson(json);
}
