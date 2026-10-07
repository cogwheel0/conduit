import 'package:conduit_core/features/calendar/models/calendar_models.dart';

/// What the signed-in account may do with calendars and events, derived the way
/// Open WebUI's `_check_calendar_access` decides it.
///
/// The calendar list and detail routes do not report a `write_access` flag, so
/// write access is read from the calendar's owner and grants, and the three
/// permissions an event can involve stay separate: writing a calendar (create,
/// edit, delete, and both ends of a move), reading it, and answering an
/// invitation, which needs no calendar access at all.
final class CalendarAccess {
  const CalendarAccess({
    required this.userId,
    required this.isAdmin,
    this.groupIds = const <String>{},
  });

  /// The signed-in account.
  final String userId;
  final bool isAdmin;

  /// The groups the account belongs to. Only the account's own groups are
  /// listed for a non-admin; an admin needs none, since an admin may write
  /// everywhere.
  final Set<String> groupIds;

  /// Whether the account may write to [calendar]: it owns it, is an admin, or
  /// holds a `write` grant as itself, as the public (`user` `*`), or through a
  /// group. The scheduled-tasks calendar is never writable.
  bool canWrite(CalendarModel calendar) {
    if (calendar.isVirtual) return false;
    if (calendar.userId == userId || isAdmin) return true;
    for (final grant in calendar.accessGrants) {
      if (grant['permission'] != 'write') continue;
      final principal = grant['principal_id'];
      switch (grant['principal_type']) {
        case 'user':
          if (principal == '*' || principal == userId) return true;
        case 'group':
          if (principal is String && groupIds.contains(principal)) return true;
      }
    }
    return false;
  }

  /// Whether the account owns [calendar] as a stored calendar of its own.
  bool owns(CalendarModel calendar) =>
      !calendar.isVirtual && calendar.userId == userId;

  /// Whether choosing [calendar] as the default is allowed. The server sets
  /// the default among the caller's own calendars only, and clears the current
  /// default before it looks, so a shared or virtual calendar must never be
  /// submitted.
  bool canMakeDefault(CalendarModel calendar) => owns(calendar);

  /// The account's own default calendar. A shared calendar can carry
  /// `is_default` too, but that is its owner's default, not this account's.
  CalendarModel? defaultCalendar(Iterable<CalendarModel> calendars) {
    for (final calendar in calendars) {
      if (owns(calendar) && calendar.isDefault) return calendar;
    }
    return null;
  }

  /// The calendars an event may be created in or moved to.
  List<CalendarModel> writable(Iterable<CalendarModel> calendars) => [
    for (final calendar in calendars)
      if (canWrite(calendar)) calendar,
  ];

  /// Whether the account may change or delete [event], given the calendars it
  /// can see. An invitation in a calendar the account cannot read has no
  /// calendar in [calendars], so it is not editable however it arrived.
  bool canEdit(CalendarEventModel event, Iterable<CalendarModel> calendars) {
    if (event.isCancelled) return false;
    for (final calendar in calendars) {
      if (calendar.id == event.calendarId) return canWrite(calendar);
    }
    return false;
  }

  /// Whether the account may answer [event]'s invitation: it is one of the
  /// invited people. This does not depend on any calendar permission.
  bool canRsvp(CalendarEventModel event) => event.attendeeFor(userId) != null;

  /// The account's own answer to [event], or null when it is not invited.
  CalendarRsvp? ownAnswer(CalendarEventModel event) =>
      event.attendeeFor(userId)?.rsvp;
}
