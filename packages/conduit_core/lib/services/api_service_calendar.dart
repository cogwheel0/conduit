part of 'api_service.dart';

/// Open WebUI calendars under `/api/v1/calendars`.
///
/// Every call requires the [ApiAuthSnapshot] of the account that asked for it,
/// so a request admitted for one account can never be sent with the
/// credentials of the account that signed in afterwards on this same
/// [ApiService].
///
/// The server owns calendars, events and the expansion of recurring events.
/// Nothing here stores or expands anything on the device.
mixin _CalendarApi on _ApiServiceBase {
  static const String _base = '/api/v1/calendars';

  String _calendarEventPath(String id) =>
      '$_base/events/${Uri.encodeComponent(id)}';

  /// The account's own and shared calendars, plus the virtual scheduled-tasks
  /// calendar when the server offers it. The route creates a default calendar
  /// for an account that has none.
  Future<List<CalendarModel>> getCalendars({
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Fetching calendars');
    final response = await _dio.get(
      '$_base/',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = response.data;
    if (body is! List) {
      throw const FormatException('calendars: expected a list');
    }
    return List<CalendarModel>.unmodifiable([
      for (final entry in body)
        if (entry is Map)
          ?CalendarModel.tryFromJson(entry.cast<String, dynamic>()),
    ]);
  }

  /// The ids of the groups the account belongs to. A non-admin's group list is
  /// its own groups; an admin's is every group, which is why a caller needs it
  /// only to read a non-admin's grants.
  Future<Set<String>> getCalendarMemberGroupIds({
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Fetching group memberships');
    final response = await _dio.get(
      '/api/v1/groups/',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = response.data;
    if (body is! List) {
      throw const FormatException('groups: expected a list');
    }
    return Set<String>.unmodifiable({
      for (final entry in body)
        if (entry is Map && entry['id'] is String) entry['id'] as String,
    });
  }

  Future<CalendarModel> createCalendar(
    CalendarForm form, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Creating calendar');
    final response = await _dio.post(
      '$_base/create',
      data: form.toJson(),
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _requireCalendar(response.data, 'calendar create');
  }

  /// Makes [calendarId] the account's default. The server clears every default
  /// the account has before it looks the calendar up, so only an owned,
  /// stored calendar may be passed.
  Future<CalendarModel> setDefaultCalendar(
    String calendarId, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Setting default calendar');
    final response = await _dio.post(
      '$_base/${Uri.encodeComponent(calendarId)}/default',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _requireCalendar(response.data, 'calendar default');
  }

  /// What the agenda shows between [startIso] and [endIso] (ISO 8601 with an
  /// offset), optionally limited to [calendarIds]. The server has already
  /// expanded recurring events into occurrences and added the scheduled-task
  /// entries; an event the account only attends is included even when its
  /// calendar is not readable.
  Future<List<CalendarAgendaItem>> getCalendarEvents({
    required String startIso,
    required String endIso,
    Iterable<String>? calendarIds,
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Fetching calendar events');
    final ids = <String>{...?calendarIds}.toList()..sort();
    final response = await _dio.get(
      '$_base/events',
      queryParameters: <String, dynamic>{
        'start': startIso,
        'end': endIso,
        if (ids.isNotEmpty) 'calendar_ids': ids.join(','),
      },
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = response.data;
    if (body is! List) {
      throw const FormatException('calendar events: expected a list');
    }
    return List<CalendarAgendaItem>.unmodifiable([
      for (final entry in body)
        if (entry is Map)
          ?CalendarAgendaItem.fromJson(entry.cast<String, dynamic>()),
    ]);
  }

  /// One stored event. This needs read access to its calendar, so an invitation
  /// in a calendar the account cannot read is a 403 here even though the agenda
  /// lists it.
  Future<CalendarEventModel> getCalendarEvent(
    String eventId, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Fetching calendar event');
    final response = await _dio.get(
      _calendarEventPath(eventId),
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _requireEvent(response.data, 'calendar event');
  }

  Future<CalendarEventModel> createCalendarEvent(
    CalendarEventForm form, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Creating calendar event');
    final response = await _dio.post(
      '$_base/events/create',
      data: form.toJson(),
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _requireEvent(response.data, 'calendar event create');
  }

  /// Applies [update] to the event: only the keys it carries change.
  Future<CalendarEventModel> updateCalendarEvent(
    String eventId,
    CalendarEventUpdate update, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Updating calendar event');
    final response = await _dio.post(
      '${_calendarEventPath(eventId)}/update',
      data: update.toJson(),
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _requireEvent(response.data, 'calendar event update');
  }

  /// Deletes the whole event, a recurring event's every occurrence included.
  Future<void> deleteCalendarEvent(
    String eventId, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Deleting calendar event');
    final response = await _dio.delete(
      '${_calendarEventPath(eventId)}/delete',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = response.data;
    if (body is! Map || body['status'] != true) {
      throw const FormatException(
        'calendar event delete: server did not confirm',
      );
    }
  }

  /// Records the account's own answer to an invitation and returns the answer
  /// the server stored. The account only needs to be invited, not to have any
  /// access to the calendar.
  Future<CalendarRsvp> rsvpCalendarEvent(
    String eventId,
    CalendarRsvp status, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Answering calendar invitation');
    final response = await _dio.post(
      '${_calendarEventPath(eventId)}/rsvp',
      data: <String, dynamic>{'status': status.wire},
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = _requireResponseMap(response.data, 'calendar rsvp');
    final stored = CalendarRsvp.fromWire(body['rsvp'] as String?);
    if (body['status'] != true || stored == null) {
      throw const FormatException('calendar rsvp: server did not confirm');
    }
    return stored;
  }

  /// A page of events matching [query] in the calendars the account can read.
  Future<CalendarEventSearchPage> searchCalendarEvents({
    String? query,
    int skip = 0,
    int limit = 30,
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Searching calendar events');
    final trimmed = query?.trim();
    final response = await _dio.get(
      '$_base/events/search',
      queryParameters: <String, dynamic>{
        if (trimmed != null && trimmed.isNotEmpty) 'query': trimmed,
        'skip': skip,
        'limit': limit,
      },
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = _requireResponseMap(response.data, 'calendar search');
    final items = body['items'];
    if (items is! List) {
      throw const FormatException('calendar search: missing items list');
    }
    final events = List<CalendarEventModel>.unmodifiable([
      for (final entry in items)
        if (entry is Map)
          ?CalendarEventModel.tryFromJson(entry.cast<String, dynamic>()),
    ]);
    final total = body['total'];
    return CalendarEventSearchPage(
      items: events,
      total: total is int ? total : events.length,
    );
  }

  CalendarModel _requireCalendar(Object? data, String context) {
    final calendar = CalendarModel.tryFromJson(
      _requireResponseMap(data, context),
    );
    if (calendar == null) throw FormatException('$context: missing id');
    return calendar;
  }

  CalendarEventModel _requireEvent(Object? data, String context) {
    final event = CalendarEventModel.tryFromJson(
      _requireResponseMap(data, context),
    );
    if (event == null) throw FormatException('$context: malformed event');
    return event;
  }
}
