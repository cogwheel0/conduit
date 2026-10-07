import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';

/// How often an event repeats, as the editor offers it.
///
/// These are the five rules Open WebUI's own editor writes. A rule the editor
/// does not write is [custom]: it is shown as it is stored and sent back
/// untouched unless the user chooses another repeat.
enum CalendarRepeat {
  none(null),
  daily('FREQ=DAILY'),
  weekdays('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR'),
  weekly('FREQ=WEEKLY'),
  monthly('FREQ=MONTHLY'),
  yearly('FREQ=YEARLY'),
  custom(null);

  const CalendarRepeat(this.rule);

  /// The `rrule` to store, or null for no repeat. A [custom] rule has no fixed
  /// text of its own.
  final String? rule;

  /// The choice that matches a stored rule. The comparison ignores case and
  /// whitespace as Open WebUI's editor does, so a rule it wrote reads back as
  /// the same choice.
  static CalendarRepeat fromRule(String? rrule) {
    final stored = rrule?.trim() ?? '';
    if (stored.isEmpty) return CalendarRepeat.none;
    final normalized = stored.toUpperCase().replaceAll(RegExp(r'\s'), '');
    for (final repeat in values) {
      if (repeat.rule == normalized) return repeat;
    }
    return CalendarRepeat.custom;
  }
}

/// Why a draft cannot be saved yet.
enum CalendarDraftIssue { titleRequired, calendarRequired, endBeforeStart }

/// An invited person, as the editor holds one.
@immutable
class CalendarDraftAttendee {
  const CalendarDraftAttendee({required this.userId, this.name, this.meta});

  final String userId;

  /// A name to show; the server does not return one with an attendee.
  final String? name;

  /// The attendee's opaque data, sent back as it came.
  final Map<String, dynamic>? meta;

  @override
  bool operator ==(Object other) =>
      other is CalendarDraftAttendee && other.userId == userId;

  @override
  int get hashCode => userId.hashCode;
}

/// An event being created or edited: what the user has typed, and the stored
/// event it started from.
///
/// An edit sends only what changed. The server leaves a field it was not sent
/// alone, so an untouched start keeps its exact nanoseconds (a date picker that
/// was opened and cancelled changes nothing), an untouched recurrence rule
/// keeps its exact text, and an untouched attendee list is not replaced.
///
/// Times are wall clocks in the zone the draft was made for, which is the
/// device's: the user chose that over the account's.
@immutable
class CalendarEventDraft {
  const CalendarEventDraft._({
    required this.original,
    required this.title,
    required this.description,
    required this.location,
    required this.calendarId,
    required this.allDay,
    required this.start,
    required this.end,
    required this.repeat,
    required this.attendees,
    required this.initialStart,
    required this.initialEnd,
  });

  /// A new event in [calendarId] starting at [start] and lasting an hour.
  factory CalendarEventDraft.create({
    required String calendarId,
    required CalendarWallTime start,
  }) {
    final end = CalendarWallTime.fromFields(
      start.fields.add(const Duration(hours: 1)),
    );
    return CalendarEventDraft._(
      original: null,
      title: '',
      description: '',
      location: '',
      calendarId: calendarId,
      allDay: false,
      start: start,
      end: end,
      repeat: CalendarRepeat.none,
      attendees: const <CalendarDraftAttendee>[],
      initialStart: start,
      initialEnd: end,
    );
  }

  /// A draft of [event], which must be the stored event (a recurring event's
  /// series, not one of its occurrences: an occurrence's start is not the
  /// series' start).
  factory CalendarEventDraft.edit(
    CalendarEventModel event, {
    required CalendarZone zone,
  }) {
    final start = wallTimeAt(event.startAtNs, zone);
    final end = _shownEnd(event, zone);
    return CalendarEventDraft._(
      original: event,
      title: event.title,
      description: event.description ?? '',
      location: event.location ?? '',
      calendarId: event.calendarId,
      allDay: event.allDay,
      start: start,
      end: end,
      repeat: CalendarRepeat.fromRule(event.rrule),
      attendees: [
        for (final attendee in event.attendees)
          CalendarDraftAttendee(userId: attendee.userId, meta: attendee.meta),
      ],
      initialStart: start,
      initialEnd: end,
    );
  }

  /// The stored event this started from, or null for a new one.
  final CalendarEventModel? original;
  final String title;
  final String description;
  final String location;
  final String calendarId;
  final bool allDay;

  /// The start's calendar day and, unless [allDay], its wall clock.
  final CalendarWallTime start;

  /// The end's calendar day and, unless [allDay], its wall clock. For an
  /// all-day event this is the last day it covers. Null when there is no end.
  final CalendarWallTime? end;
  final CalendarRepeat repeat;
  final List<CalendarDraftAttendee> attendees;

  /// The start and end as they were shown first, so a field set back to what it
  /// showed is not an edit.
  final CalendarWallTime initialStart;
  final CalendarWallTime? initialEnd;

  bool get isNew => original == null;

  /// The end the editor shows for [event]: the wall clock of a timed end, or the
  /// last day an all-day event covers.
  static CalendarWallTime? _shownEnd(
    CalendarEventModel event,
    CalendarZone zone,
  ) {
    final endNs = event.endAtNs;
    if (endNs == null) return null;
    if (event.allDay) {
      return daySpan(startNs: event.startAtNs, endNs: endNs, zone: zone).last;
    }
    return wallTimeAt(endNs, zone);
  }

  CalendarEventDraft copyWith({
    String? title,
    String? description,
    String? location,
    String? calendarId,
    bool? allDay,
    CalendarWallTime? start,
    CalendarWallTime? end,
    bool clearEnd = false,
    CalendarRepeat? repeat,
    List<CalendarDraftAttendee>? attendees,
  }) {
    return CalendarEventDraft._(
      original: original,
      title: title ?? this.title,
      description: description ?? this.description,
      location: location ?? this.location,
      calendarId: calendarId ?? this.calendarId,
      allDay: allDay ?? this.allDay,
      start: start ?? this.start,
      end: clearEnd ? null : (end ?? this.end),
      repeat: repeat ?? this.repeat,
      attendees: attendees ?? this.attendees,
      initialStart: initialStart,
      initialEnd: initialEnd,
    );
  }

  /// What keeps this draft from being saved, in the order to show it.
  List<CalendarDraftIssue> get issues {
    final found = <CalendarDraftIssue>[];
    if (title.trim().isEmpty) found.add(CalendarDraftIssue.titleRequired);
    if (calendarId.isEmpty) found.add(CalendarDraftIssue.calendarRequired);
    final end = this.end;
    if (end != null) {
      final before = allDay
          ? end.dateOnly.compareTo(start.dateOnly) < 0
          : end.compareTo(start) < 0;
      if (before) found.add(CalendarDraftIssue.endBeforeStart);
    }
    return found;
  }

  /// Whether the user changed anything.
  bool isChanged({required CalendarZone zone}) {
    final stored = original;
    if (stored == null) return true;
    return _changedFields(stored, zone).isNotEmpty;
  }

  /// The form for a new event.
  CalendarEventForm toCreateForm({required CalendarZone zone}) {
    final trimmedDescription = description.trim();
    final trimmedLocation = location.trim();
    final people = _attendeeRows(attendees);
    return CalendarEventForm(
      calendarId: calendarId,
      title: title.trim(),
      startAtNs: _startNs(zone),
      endAtNs: end == null ? null : _endNs(zone),
      allDay: allDay,
      description: trimmedDescription.isEmpty ? null : trimmedDescription,
      location: trimmedLocation.isEmpty ? null : trimmedLocation,
      rrule: repeat.rule,
      attendees: people.isEmpty ? null : people,
    );
  }

  /// What changed against the stored event, ready to send. Empty when nothing
  /// did.
  CalendarEventUpdate toUpdate({required CalendarZone zone}) {
    final stored = original;
    if (stored == null) {
      throw StateError('A new event is created, not updated');
    }
    return CalendarEventUpdate(_changedFields(stored, zone));
  }

  Map<String, dynamic> _changedFields(
    CalendarEventModel stored,
    CalendarZone zone,
  ) {
    final fields = <String, dynamic>{};
    final trimmedTitle = title.trim();
    if (trimmedTitle != stored.title) fields['title'] = trimmedTitle;
    final trimmedDescription = description.trim();
    if (trimmedDescription != (stored.description ?? '').trim()) {
      fields['description'] = trimmedDescription.isEmpty
          ? null
          : trimmedDescription;
    }
    final trimmedLocation = location.trim();
    if (trimmedLocation != (stored.location ?? '').trim()) {
      fields['location'] = trimmedLocation.isEmpty ? null : trimmedLocation;
    }
    if (calendarId != stored.calendarId) fields['calendar_id'] = calendarId;
    if (allDay != stored.allDay) fields['all_day'] = allDay;

    final startChanged = allDay != stored.allDay || _startEdited;
    if (startChanged) fields['start_at'] = _startNs(zone);

    final endChanged =
        allDay != stored.allDay ||
        (end == null) != (initialEnd == null) ||
        _endEdited;
    if (endChanged) fields['end_at'] = end == null ? null : _endNs(zone);

    // An unrecognised rule stays as stored until another repeat is chosen.
    final storedRepeat = CalendarRepeat.fromRule(stored.rrule);
    if (repeat != storedRepeat) fields['rrule'] = repeat.rule;

    final storedIds = {for (final a in stored.attendees) a.userId};
    final draftIds = {for (final a in attendees) a.userId};
    if (!const SetEquality<String>().equals(storedIds, draftIds)) {
      fields['attendees'] = _attendeeRows(attendees);
    }
    return fields;
  }

  bool get _startEdited =>
      allDay ? !start.sameDate(initialStart) : start != initialStart;

  bool get _endEdited {
    final end = this.end;
    final initial = initialEnd;
    if (end == null || initial == null) return false;
    return allDay ? !end.sameDate(initial) : end != initial;
  }

  /// The start to send. A start the user did not edit keeps the stored value
  /// exactly; an edited one is the minute chosen, or midnight of the day chosen
  /// for an all-day event, as Open WebUI's editor writes it.
  int _startNs(CalendarZone zone) {
    final stored = original;
    if (stored != null && stored.allDay == allDay && !_startEdited) {
      return stored.startAtNs;
    }
    return nanosecondsFromWallTime(allDay ? start.dateOnly : start, zone);
  }

  /// The end to send, by the same rule as [_startNs]. An edited all-day end is
  /// 23:59 of its last day, as Open WebUI's editor writes it.
  int _endNs(CalendarZone zone) {
    final end = this.end!;
    final stored = original;
    if (stored != null &&
        stored.allDay == allDay &&
        stored.endAtNs != null &&
        !_endEdited) {
      return stored.endAtNs!;
    }
    final wall = allDay
        ? CalendarWallTime(end.year, end.month, end.day, 23, 59)
        : end;
    return nanosecondsFromWallTime(wall, zone);
  }

  /// `{user_id, meta?}` rows. No status is sent: the server keeps an existing
  /// attendee's answer and starts a new one pending, and nobody but the
  /// attendee can set it.
  static List<Map<String, dynamic>> _attendeeRows(
    List<CalendarDraftAttendee> people,
  ) => [
    for (final person in people)
      <String, dynamic>{'user_id': person.userId, 'meta': ?person.meta},
  ];
}
