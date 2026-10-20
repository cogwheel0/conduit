import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/automations/models/automation.dart'
    show epochNanoseconds;

/// Id of the calendar the server computes from the account's scheduled tasks.
/// It is not stored: it holds no events of its own, and no ordinary calendar or
/// event route accepts it.
const String scheduledTasksCalendarId = '__scheduled_tasks__';

/// What an attendee answers, as the server's RSVP route accepts it.
enum CalendarRsvp {
  accepted('accepted'),
  declined('declined'),
  tentative('tentative'),
  pending('pending');

  const CalendarRsvp(this.wire);

  final String wire;

  static CalendarRsvp? fromWire(String? value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}

/// Anything the agenda lists: an ordinary stored event or a scheduled-task
/// entry the server projected. They are separate types so a caller has to
/// decide which one it holds before it can mutate anything.
sealed class CalendarAgendaItem {
  const CalendarAgendaItem();

  /// Epoch nanoseconds the item starts at.
  int get startAtNs;

  /// A key unique within one agenda response. A recurring event's occurrences
  /// share an event id, so the occurrence's own id is part of it.
  String get key;

  /// Reads one entry of `GET /calendars/events`, or null when it lacks the
  /// fields every entry has.
  static CalendarAgendaItem? fromJson(Map<String, dynamic> json) {
    if (json['calendar_id'] == scheduledTasksCalendarId) {
      return ScheduledTaskCalendarEntry.tryFromJson(json);
    }
    return CalendarEventModel.tryFromJson(json);
  }
}

/// One person invited to an event. Only that person changes [status].
@immutable
class CalendarAttendee {
  const CalendarAttendee({
    required this.id,
    required this.eventId,
    required this.userId,
    required this.status,
    this.meta,
    this.createdAtNs,
    this.updatedAtNs,
  });

  final String id;
  final String eventId;
  final String userId;

  /// The raw status the server holds; [rsvp] is it when it is one the client
  /// knows.
  final String status;

  /// Opaque attendee data, sent back as it came when the list is replaced.
  final Map<String, dynamic>? meta;
  final int? createdAtNs;
  final int? updatedAtNs;

  CalendarRsvp? get rsvp => CalendarRsvp.fromWire(status);

  factory CalendarAttendee.fromJson(Map<String, dynamic> json) {
    return CalendarAttendee(
      id: (json['id'] ?? '').toString(),
      eventId: (json['event_id'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      status: (json['status'] ?? 'pending').toString(),
      meta: _map(json['meta']),
      createdAtNs: epochNanoseconds(json['created_at']),
      updatedAtNs: epochNanoseconds(json['updated_at']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarAttendee &&
      other.id == id &&
      other.eventId == eventId &&
      other.userId == userId &&
      other.status == status &&
      other.createdAtNs == createdAtNs &&
      other.updatedAtNs == updatedAtNs &&
      const DeepCollectionEquality().equals(other.meta, meta);

  @override
  int get hashCode => Object.hash(id, eventId, userId, status, updatedAtNs);
}

/// A calendar, as the server lists it.
///
/// The server does not say whether the account may write to a calendar, so
/// that is derived from [userId] and [accessGrants]; see `calendar_access.dart`.
@immutable
class CalendarModel {
  const CalendarModel({
    required this.id,
    required this.userId,
    required this.name,
    this.color,
    this.isDefault = false,
    this.isSystem = false,
    this.data,
    this.meta,
    this.accessGrants = const <Map<String, dynamic>>[],
    this.createdAtNs,
    this.updatedAtNs,
  });

  final String id;

  /// The owner. For a shared calendar this is not the signed-in account.
  final String userId;
  final String name;

  /// `#rrggbb` as the server stored it, or null.
  final String? color;

  /// Whether this is its owner's default. On a shared calendar that is the
  /// owner's choice, never the signed-in account's.
  final bool isDefault;

  /// True for the virtual scheduled-tasks calendar.
  final bool isSystem;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? meta;

  /// `{id, resource_type, resource_id, principal_type, principal_id,
  /// permission, created_at}` rows, verbatim.
  final List<Map<String, dynamic>> accessGrants;
  final int? createdAtNs;
  final int? updatedAtNs;

  /// Whether this is the scheduled-tasks projection rather than a stored
  /// calendar.
  bool get isVirtual => isSystem || id == scheduledTasksCalendarId;

  static CalendarModel? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final grants = json['access_grants'];
    return CalendarModel(
      id: id,
      userId: (json['user_id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      color: _string(json['color']),
      isDefault: json['is_default'] == true,
      isSystem: json['is_system'] == true,
      data: _map(json['data']),
      meta: _map(json['meta']),
      accessGrants: grants is List
          ? List<Map<String, dynamic>>.unmodifiable([
              for (final row in grants)
                if (row is Map) Map<String, dynamic>.from(row),
            ])
          : const <Map<String, dynamic>>[],
      createdAtNs: epochNanoseconds(json['created_at']),
      updatedAtNs: epochNanoseconds(json['updated_at']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarModel &&
      other.id == id &&
      other.userId == userId &&
      other.name == name &&
      other.color == color &&
      other.isDefault == isDefault &&
      other.isSystem == isSystem &&
      other.updatedAtNs == updatedAtNs &&
      const DeepCollectionEquality().equals(other.accessGrants, accessGrants);

  @override
  int get hashCode =>
      Object.hash(id, userId, name, color, isDefault, isSystem, updatedAtNs);

  @override
  String toString() => 'CalendarModel($id)';
}

/// An ordinary stored event, or one occurrence of a recurring one.
///
/// Timestamps are integer epoch **nanoseconds** and are kept as the server sent
/// them: a nanosecond epoch does not survive a double, and a field the user did
/// not edit must go back (or stay unsent) with its exact value.
@immutable
class CalendarEventModel extends CalendarAgendaItem {
  const CalendarEventModel({
    required this.id,
    required this.calendarId,
    required this.userId,
    required this.title,
    required this.startAtNs,
    this.description,
    this.endAtNs,
    this.allDay = false,
    this.rrule,
    this.color,
    this.location,
    this.data,
    this.meta,
    this.isCancelled = false,
    this.attendees = const <CalendarAttendee>[],
    this.createdAtNs,
    this.updatedAtNs,
    this.instanceId,
    this.organizerName,
  });

  /// The stored event's id. For an occurrence this is the series' id, the one
  /// every route takes.
  final String id;
  final String calendarId;

  /// The organizer, who created the event.
  final String userId;
  final String title;
  final String? description;
  @override
  final int startAtNs;
  final int? endAtNs;
  final bool allDay;

  /// The series rule, verbatim. The server expands it; the client never does.
  final String? rrule;
  final String? color;
  final String? location;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? meta;
  final bool isCancelled;
  final List<CalendarAttendee> attendees;
  final int? createdAtNs;
  final int? updatedAtNs;

  /// Set by the server on an expanded occurrence (`{id}_{startNs}`).
  final String? instanceId;

  /// The organizer's display name, when the agenda carried it.
  final String? organizerName;

  @override
  String get key => '$id|${instanceId ?? ''}';

  bool get isRecurring => (rrule ?? '').trim().isNotEmpty;

  CalendarAttendee? attendeeFor(String userId) {
    for (final attendee in attendees) {
      if (attendee.userId == userId) return attendee;
    }
    return null;
  }

  static CalendarEventModel? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final start = epochNanoseconds(json['start_at']);
    if (id is! String || id.isEmpty || start == null) return null;
    final attendees = json['attendees'];
    final user = _map(json['user']);
    return CalendarEventModel(
      id: id,
      calendarId: (json['calendar_id'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      description: _string(json['description']),
      startAtNs: start,
      endAtNs: epochNanoseconds(json['end_at']),
      allDay: json['all_day'] == true,
      rrule: _string(json['rrule']),
      color: _string(json['color']),
      location: _string(json['location']),
      data: _map(json['data']),
      meta: _map(json['meta']),
      isCancelled: json['is_cancelled'] == true,
      attendees: attendees is List
          ? List<CalendarAttendee>.unmodifiable([
              for (final row in attendees)
                if (row is Map)
                  CalendarAttendee.fromJson(row.cast<String, dynamic>()),
            ])
          : const <CalendarAttendee>[],
      createdAtNs: epochNanoseconds(json['created_at']),
      updatedAtNs: epochNanoseconds(json['updated_at']),
      instanceId: _string(json['instance_id']),
      organizerName: _string(user?['name']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarEventModel &&
      other.id == id &&
      other.instanceId == instanceId &&
      other.calendarId == calendarId &&
      other.userId == userId &&
      other.title == title &&
      other.description == description &&
      other.startAtNs == startAtNs &&
      other.endAtNs == endAtNs &&
      other.allDay == allDay &&
      other.rrule == rrule &&
      other.color == color &&
      other.location == location &&
      other.isCancelled == isCancelled &&
      other.updatedAtNs == updatedAtNs &&
      const DeepCollectionEquality().equals(other.attendees, attendees) &&
      const DeepCollectionEquality().equals(other.data, data) &&
      const DeepCollectionEquality().equals(other.meta, meta);

  @override
  int get hashCode =>
      Object.hash(id, instanceId, calendarId, title, startAtNs, updatedAtNs);

  // The title and description can hold anything the user wrote.
  @override
  String toString() => 'CalendarEventModel($id)';
}

/// A scheduled task as the calendar shows it: a future occurrence of an active
/// task (`auto_{id}`) or one past run (`run_{id}`).
///
/// This is a read-only projection of the automations feature. Its ids are not
/// stored events, so nothing here may reach an event route; the way to act on it
/// is to open the task, or the chat or channel message a run produced.
@immutable
class ScheduledTaskCalendarEntry extends CalendarAgendaItem {
  const ScheduledTaskCalendarEntry({
    required this.id,
    required this.title,
    required this.startAtNs,
    this.description,
    this.automationId,
    this.runId,
    this.chatId,
    this.status,
    this.instanceId,
  });

  /// `auto_{automationId}` or `run_{runId}`.
  final String id;
  final String title;
  @override
  final int startAtNs;

  /// The task's prompt for a future entry; the error text for a failed run.
  final String? description;

  /// The task this entry belongs to, from the server's metadata. Null only when
  /// the server sent none, and then there is nothing to open.
  final String? automationId;

  /// Set on a past run.
  final String? runId;

  /// A past run's result: a chat id, or `channel:<id>` for a channel message.
  final String? chatId;

  /// A past run's status, `success` unless it failed.
  final String? status;
  final String? instanceId;

  @override
  String get key => '$id|${instanceId ?? ''}';

  /// Whether this is a past run rather than a future occurrence.
  bool get isRun => runId != null;

  bool get failed => isRun && status != null && status != 'success';

  /// The channel a run's result was posted to, or null.
  String? get resultChannelId {
    final value = chatId;
    if (value == null || !value.startsWith(_channelPrefix)) return null;
    final channel = value.substring(_channelPrefix.length);
    return channel.isEmpty ? null : channel;
  }

  /// The chat a run produced, or null when it has none or posted to a channel.
  String? get resultChatId {
    final value = chatId;
    if (value == null || value.isEmpty || value.startsWith(_channelPrefix)) {
      return null;
    }
    return value;
  }

  static const String _channelPrefix = 'channel:';

  static ScheduledTaskCalendarEntry? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final start = epochNanoseconds(json['start_at']);
    if (id is! String || id.isEmpty || start == null) return null;
    final meta = _map(json['meta']);
    return ScheduledTaskCalendarEntry(
      id: id,
      title: (json['title'] ?? '').toString(),
      startAtNs: start,
      description: _string(json['description']),
      automationId: _string(meta?['automation_id']),
      runId: _string(meta?['run_id']),
      chatId: _string(meta?['chat_id']),
      status: _string(meta?['status']),
      instanceId: _string(json['instance_id']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduledTaskCalendarEntry &&
      other.id == id &&
      other.instanceId == instanceId &&
      other.title == title &&
      other.startAtNs == startAtNs &&
      other.automationId == automationId &&
      other.runId == runId &&
      other.chatId == chatId &&
      other.status == status;

  @override
  int get hashCode => Object.hash(id, instanceId, startAtNs, runId);

  @override
  String toString() => 'ScheduledTaskCalendarEntry($id)';
}

/// What `POST /calendars/events/create` sends.
@immutable
class CalendarEventForm {
  const CalendarEventForm({
    required this.calendarId,
    required this.title,
    required this.startAtNs,
    this.description,
    this.endAtNs,
    this.allDay = false,
    this.rrule,
    this.color,
    this.location,
    this.data,
    this.meta,
    this.attendees,
  });

  final String calendarId;
  final String title;
  final int startAtNs;
  final String? description;
  final int? endAtNs;
  final bool allDay;
  final String? rrule;
  final String? color;
  final String? location;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? meta;

  /// `{user_id, meta?}` rows. The server starts every one as pending: an
  /// organizer cannot set anyone's answer, so no status is ever sent.
  final List<Map<String, dynamic>>? attendees;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'calendar_id': calendarId,
    'title': title,
    'start_at': startAtNs,
    'all_day': allDay,
    'description': ?description,
    'end_at': ?endAtNs,
    'rrule': ?rrule,
    'color': ?color,
    'location': ?location,
    'data': ?data,
    'meta': ?meta,
    'attendees': ?attendees,
  };
}

/// The fields an edit changes, for `POST /calendars/events/{id}/update`.
///
/// The server applies exactly the keys that are present: a missing key leaves
/// the stored value alone, `data` and `meta` merge into what is stored, and an
/// `attendees` list replaces the invited people while keeping each person's
/// answer. So a form carries only what the user changed, which is also how a
/// field they did not touch keeps its exact stored value.
@immutable
class CalendarEventUpdate {
  const CalendarEventUpdate(this.fields);

  final Map<String, dynamic> fields;

  bool get isEmpty => fields.isEmpty;

  /// The calendar the event moves to, or null when it stays.
  String? get destinationCalendarId => fields['calendar_id'] as String?;

  Map<String, dynamic> toJson() => Map<String, dynamic>.of(fields);
}

/// What `POST /calendars/create` sends. Sharing is not part of it: a new
/// calendar is private to its owner.
@immutable
class CalendarForm {
  const CalendarForm({required this.name, this.color});

  final String name;
  final String? color;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'color': ?color,
  };
}

/// One page of `GET /calendars/events/search`.
@immutable
class CalendarEventSearchPage {
  const CalendarEventSearchPage({required this.items, required this.total});

  final List<CalendarEventModel> items;
  final int total;
}

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Map<String, dynamic>? _map(Object? value) => value is Map
    ? Map<String, dynamic>.unmodifiable(
        value.map((key, entry) => MapEntry(key.toString(), entry)),
      )
    : null;
