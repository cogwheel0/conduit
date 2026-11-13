import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:meta/meta.dart';

/// How many minutes before an event Open WebUI alerts when the event carries
/// no `meta.alert_minutes`: the default of the server's
/// `CALENDAR_ALERT_LOOKAHEAD_MINUTES`.
const int calendarDefaultAlertMinutes = 10;

/// How many reminders are kept scheduled on the device at once, soonest first.
///
/// iOS keeps at most 64 pending local notifications per app and drops the rest
/// silently, so this stays well below that.
const int calendarReminderLimit = 48;

/// One reminder the device should post for a calendar event.
@immutable
final class CalendarReminder {
  const CalendarReminder({
    required this.key,
    required this.eventId,
    required this.title,
    required this.startAtNs,
    required this.fireAt,
    this.allDay = false,
    this.location,
  });

  /// The agenda key of the event or occurrence ([CalendarAgendaItem.key]), so
  /// each occurrence of a recurring event has its own reminder.
  final String key;

  /// The stored event's id.
  final String eventId;
  final String title;
  final int startAtNs;
  final bool allDay;
  final String? location;

  /// When the reminder is due, in UTC. Never earlier than the moment the plan
  /// was made: a reminder whose alert time already passed while the event has
  /// not started yet is due right away.
  final DateTime fireAt;

  @override
  bool operator ==(Object other) =>
      other is CalendarReminder &&
      other.key == key &&
      other.eventId == eventId &&
      other.title == title &&
      other.startAtNs == startAtNs &&
      other.allDay == allDay &&
      other.location == location &&
      other.fireAt == fireAt;

  @override
  int get hashCode =>
      Object.hash(key, eventId, title, startAtNs, allDay, location, fireAt);

  @override
  String toString() => 'CalendarReminder($key at $fireAt)';
}

/// How many minutes before [event] it should be alerted, or null for no alert.
///
/// Read the way Open WebUI's scheduler reads it: a numeric
/// `meta.alert_minutes`, where a negative value means no alert and anything
/// else (missing, or not a number) falls back to
/// [calendarDefaultAlertMinutes].
int? calendarAlertMinutes(CalendarEventModel event) {
  final value = event.meta?['alert_minutes'];
  if (value is! num) return calendarDefaultAlertMinutes;
  if (value < 0) return null;
  return value.floor();
}

/// The reminders to keep scheduled for [items], soonest first, at most [limit].
///
/// Mirrors when Open WebUI's server raises `calendar:alert`: only for the
/// account's own events ([userId] is the organizer), never for a cancelled
/// one, and only while the event has not started. Unlike the server, which
/// looks only at a series' stored start, every occurrence of a recurring event
/// the agenda returned gets its own reminder.
List<CalendarReminder> planCalendarReminders({
  required Iterable<CalendarAgendaItem> items,
  required String userId,
  required DateTime now,
  int limit = calendarReminderLimit,
}) {
  final nowUtc = now.toUtc();
  final nowNs = nowUtc.microsecondsSinceEpoch * nanosPerMicrosecond;
  final reminders = <String, CalendarReminder>{};
  for (final item in items) {
    if (item is! CalendarEventModel) continue;
    if (item.isCancelled || item.userId != userId) continue;
    if (item.startAtNs < nowNs) continue;
    final minutes = calendarAlertMinutes(item);
    if (minutes == null) continue;
    final alertAt = instantFromNanoseconds(
      item.startAtNs,
    ).subtract(Duration(minutes: minutes));
    reminders[item.key] = CalendarReminder(
      key: item.key,
      eventId: item.id,
      title: item.title,
      startAtNs: item.startAtNs,
      allDay: item.allDay,
      location: item.location,
      fireAt: alertAt.isBefore(nowUtc) ? nowUtc : alertAt,
    );
  }
  final sorted = reminders.values.toList()
    ..sort((a, b) {
      final byTime = a.fireAt.compareTo(b.fireAt);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
  return List<CalendarReminder>.unmodifiable(sorted.take(limit));
}
