import 'package:checks/checks.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

// Written the way the pinned server serializes it: epochs are nanoseconds, as
// plain JSON integers larger than a double holds exactly.
const _eventJson = '''
{
  "id": "event-1",
  "calendar_id": "cal-1",
  "user_id": "user-1",
  "title": "Planning",
  "description": "Quarterly",
  "start_at": 1791320967123456789,
  "end_at": 1791324567987654321,
  "all_day": false,
  "rrule": null,
  "color": null,
  "location": "Room 4",
  "data": {"kept": {"deep": true}},
  "meta": {"alert_minutes": 10},
  "is_cancelled": false,
  "attendees": [
    {
      "id": "att-1",
      "event_id": "event-1",
      "user_id": "user-2",
      "status": "accepted",
      "meta": {"role": "optional"},
      "created_at": 1790000000000000001,
      "updated_at": 1790000000000000002
    }
  ],
  "created_at": 1790000000123456789,
  "updated_at": 1790000001987654321,
  "user": {"id": "user-1", "name": "Ada"}
}
''';

const _calendarJson = '''
{
  "id": "cal-1",
  "user_id": "user-1",
  "name": "Personal",
  "color": "#3366ff",
  "is_default": true,
  "is_system": false,
  "data": null,
  "meta": null,
  "access_grants": [
    {
      "id": "g1",
      "resource_type": "calendar",
      "resource_id": "cal-1",
      "principal_type": "user",
      "principal_id": "user-2",
      "permission": "read",
      "created_at": 1790000000000000000
    }
  ],
  "created_at": 1790000000000000000,
  "updated_at": 1790000000000000000
}
''';

void main() {
  late _Adapter adapter;
  late ApiService api;

  setUp(() {
    adapter = _Adapter();
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'https://server.example',
      ),
      workerManager: WorkerManager(),
      authToken: 'session-a',
    );
    api.dio.httpClientAdapter = adapter;
  });

  tearDown(() => api.dispose());

  group('calendars', () {
    test('lists calendars with their grants and the virtual one', () async {
      adapter.reply('''
[
  $_calendarJson,
  {"id": "__scheduled_tasks__", "user_id": "user-1", "name": "Scheduled Tasks",
   "color": "#8b5cf6", "is_default": false, "is_system": true,
   "created_at": 1790000000000000000, "updated_at": 1790000000000000000},
  {"name": "no id, dropped"}
]''');

      final calendars = await api.getCalendars(
        authSnapshot: api.captureAuthSnapshot(),
      );

      final request = adapter.requests.single;
      check(request.method).equals('GET');
      check(request.path).equals('/api/v1/calendars/');
      check(request.headers['Authorization']).equals('Bearer session-a');
      check(calendars.map((c) => c.id))
          .deepEquals(['cal-1', '__scheduled_tasks__']);
      check(calendars.first.isDefault).isTrue();
      check(calendars.first.accessGrants.single['principal_id'])
          .equals('user-2');
      check(calendars.last.isVirtual).isTrue();
    });

    test('creating one sends only its name and colour', () async {
      adapter.reply(_calendarJson);

      final created = await api.createCalendar(
        const CalendarForm(name: 'Work', color: '#3366ff'),
        authSnapshot: api.captureAuthSnapshot(),
      );

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/calendars/create');
      check(request.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({'name': 'Work', 'color': '#3366ff'});
      check(created.id).equals('cal-1');
    });

    test(
      'choosing a default posts to that calendar\'s default route',
      () async {
        adapter.reply(_calendarJson);

        await api.setDefaultCalendar(
          'cal 1',
          authSnapshot: api.captureAuthSnapshot(),
        );

        final request = adapter.requests.single;
        check(request.method).equals('POST');
        check(request.path).equals('/api/v1/calendars/cal%201/default');
      },
    );

    test('group memberships are read as ids', () async {
      adapter.reply('[{"id": "g-1", "name": "A"}, {"id": "g-2"}, {"x": 1}]');

      final ids = await api.getCalendarMemberGroupIds(
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(adapter.requests.single.path).equals('/api/v1/groups/');
      check(ids).unorderedEquals(['g-1', 'g-2']);
    });
  });

  group('agenda', () {
    test(
      'sends ISO bounds with their offsets, encoded, and stable ids',
      () async {
        adapter.reply('[]');

        await api.getCalendarEvents(
          startIso: '2026-10-06T00:00:00+05:30',
          endIso: '2026-10-20T00:00:00+05:30',
          calendarIds: ['b', 'a', 'b'],
          authSnapshot: api.captureAuthSnapshot(),
        );

        final request = adapter.requests.single;
        check(request.path).equals('/api/v1/calendars/events');
        check(request.uri.queryParameters).deepEquals({
          'start': '2026-10-06T00:00:00+05:30',
          'end': '2026-10-20T00:00:00+05:30',
          'calendar_ids': 'a,b',
        });
        // A bare `+` would reach the server as a space and break the offset.
        check(request.uri.query).not((it) => it.contains('+'));
      },
    );

    test('leaves the calendar filter out when none is chosen', () async {
      adapter.reply('[]');

      await api.getCalendarEvents(
        startIso: '2026-10-06T00:00:00-04:00',
        endIso: '2026-10-07T00:00:00-04:00',
        calendarIds: const [],
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(adapter.requests.single.queryParameters.keys)
          .unorderedEquals(['start', 'end']);
    });

    test('keeps each occurrence of a server-expanded series', () async {
      // The three instance ids a read-only shared all-day series answers with.
      String occurrence(int day) =>
          '''
{"id": "series-1", "calendar_id": "cal-2", "user_id": "user-9",
 "title": "Holiday", "all_day": true, "rrule": "FREQ=DAILY;COUNT=3",
 "start_at": ${1791777600000000000 + day * 86400000000000},
 "end_at": ${1791777600000000000 + day * 86400000000000 + 86340000000000},
 "instance_id": "series-1_${1791777600000000000 + day * 86400000000000}",
 "attendees": [], "created_at": 1, "updated_at": 2}''';
      adapter.reply('[${occurrence(0)}, ${occurrence(1)}, ${occurrence(2)}]');

      final items = await api.getCalendarEvents(
        startIso: 'a',
        endIso: 'b',
        authSnapshot: api.captureAuthSnapshot(),
      );

      final events = items.cast<CalendarEventModel>();
      check(events.map((e) => e.id).toSet()).deepEquals({'series-1'});
      check(events.map((e) => e.key).toSet()).length.equals(3);
      check(events.every((e) => e.isRecurring && e.allDay)).isTrue();
      check(events.map((e) => e.startAtNs)).deepEquals([
        1791777600000000000,
        1791864000000000000,
        1791950400000000000,
      ]);
    });

    test('reads scheduled-task entries as a separate projection', () async {
      adapter.reply('''
[
  {"id": "auto_a1", "calendar_id": "__scheduled_tasks__", "user_id": "user-1",
   "title": "Digest", "description": "Summarize", "start_at": 1791320967000000001,
   "end_at": null, "all_day": false, "rrule": "RRULE:FREQ=DAILY",
   "instance_id": "auto_a1_1791320967000000001",
   "meta": {"automation_id": "a1"}, "attendees": [], "created_at": 1, "updated_at": 2},
  {"id": "run_r1", "calendar_id": "__scheduled_tasks__", "user_id": "user-1",
   "title": "Digest", "description": "boom", "start_at": 1791300000000000000,
   "meta": {"automation_id": "a1", "run_id": "r1", "chat_id": "channel:chan-1",
            "status": "error"},
   "attendees": [], "created_at": 1, "updated_at": 2},
  {"id": "run_r2", "calendar_id": "__scheduled_tasks__", "user_id": "user-1",
   "title": "Digest", "start_at": 1791290000000000000,
   "meta": {"automation_id": "a1", "run_id": "r2", "chat_id": "chat-9",
            "status": "success"}}
]''');

      final items = await api.getCalendarEvents(
        startIso: 'a',
        endIso: 'b',
        authSnapshot: api.captureAuthSnapshot(),
      );

      check(items).every((it) => it.isA<ScheduledTaskCalendarEntry>());
      final [future, failedRun, okRun] = items
          .cast<ScheduledTaskCalendarEntry>();
      check(future.isRun).isFalse();
      check(future.automationId).equals('a1');
      check(failedRun.isRun).isTrue();
      check(failedRun.failed).isTrue();
      check(failedRun.resultChannelId).equals('chan-1');
      check(failedRun.resultChatId).isNull();
      check(okRun.failed).isFalse();
      check(okRun.resultChatId).equals('chat-9');
    });

    test(
      'keeps nanoseconds, opaque fields and attendees of an event',
      () async {
        adapter.reply('[$_eventJson, {"id": "", "start_at": 1}, {"id": "x"}]');

        final items = await api.getCalendarEvents(
          startIso: 'a',
          endIso: 'b',
          authSnapshot: api.captureAuthSnapshot(),
        );

        final event = items.single as CalendarEventModel;
        check(event.startAtNs).equals(1791320967123456789);
        check(event.endAtNs).equals(1791324567987654321);
        check(event.data).isNotNull().deepEquals({
          'kept': {'deep': true},
        });
        check(event.attendees.single.userId).equals('user-2');
        check(event.attendees.single.meta)
            .isNotNull()
            .deepEquals({'role': 'optional'});
        check(event.attendees.single.rsvp).equals(CalendarRsvp.accepted);
        check(event.organizerName).equals('Ada');
      },
    );
  });

  group('events', () {
    test(
      'detail reads one event, and a 403 is not turned into a miss',
      () async {
        adapter.reply(_eventJson);
        final event = await api.getCalendarEvent(
          'event-1',
          authSnapshot: api.captureAuthSnapshot(),
        );
        check(adapter.requests.single.path)
            .equals('/api/v1/calendars/events/event-1');
        check(event.title).equals('Planning');

        adapter.reply('{"detail": "Access denied"}', status: 403);
        await check(
          api.getCalendarEvent(
            'event-1',
            authSnapshot: api.captureAuthSnapshot(),
          ),
        ).throws<DioException>(
          (it) => it.has((e) => e.response?.statusCode, 'status').equals(403),
        );
      },
    );

    test(
      'creating sends the form without unset fields or attendee status',
      () async {
        adapter.reply(_eventJson);

        await api.createCalendarEvent(
          const CalendarEventForm(
            calendarId: 'cal-1',
            title: 'Planning',
            startAtNs: 1791320940000000000,
            endAtNs: 1791324540000000000,
            attendees: [
              {'user_id': 'user-2'},
            ],
          ),
          authSnapshot: api.captureAuthSnapshot(),
        );

        final request = adapter.requests.single;
        check(request.method).equals('POST');
        check(request.path).equals('/api/v1/calendars/events/create');
        check(request.data).isA<Map<String, dynamic>>().deepEquals({
          'calendar_id': 'cal-1',
          'title': 'Planning',
          'start_at': 1791320940000000000,
          'end_at': 1791324540000000000,
          'all_day': false,
          'attendees': [
            {'user_id': 'user-2'},
          ],
        });
      },
    );

    test('updating sends only the fields that changed', () async {
      adapter.reply(_eventJson);

      await api.updateCalendarEvent(
        'event-1',
        const CalendarEventUpdate({'title': 'Renamed', 'calendar_id': 'cal-2'}),
        authSnapshot: api.captureAuthSnapshot(),
      );

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/calendars/events/event-1/update');
      check(request.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({'title': 'Renamed', 'calendar_id': 'cal-2'});
    });

    test('deleting needs the server to confirm', () async {
      adapter.reply('{"status": true}');
      await api.deleteCalendarEvent(
        'event-1',
        authSnapshot: api.captureAuthSnapshot(),
      );
      final request = adapter.requests.single;
      check(request.method).equals('DELETE');
      check(request.path).equals('/api/v1/calendars/events/event-1/delete');

      adapter.reply('{"status": false}');
      await check(
        api.deleteCalendarEvent(
          'event-1',
          authSnapshot: api.captureAuthSnapshot(),
        ),
      ).throws<FormatException>();
    });

    test('an RSVP posts the wire status and returns what was stored', () async {
      adapter.reply('{"status": true, "rsvp": "tentative"}');

      final stored = await api.rsvpCalendarEvent(
        'event-1',
        CalendarRsvp.tentative,
        authSnapshot: api.captureAuthSnapshot(),
      );

      final request = adapter.requests.single;
      check(request.method).equals('POST');
      check(request.path).equals('/api/v1/calendars/events/event-1/rsvp');
      check(request.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({'status': 'tentative'});
      check(stored).equals(CalendarRsvp.tentative);
    });

    test('an RSVP the server does not confirm is an error', () async {
      adapter.reply('{"status": false}');

      await check(
        api.rsvpCalendarEvent(
          'event-1',
          CalendarRsvp.accepted,
          authSnapshot: api.captureAuthSnapshot(),
        ),
      ).throws<FormatException>();
    });

    test('search sends a trimmed query and pages', () async {
      adapter.reply('{"items": [$_eventJson], "total": 41}');

      final page = await api.searchCalendarEvents(
        query: ' plan ',
        skip: 30,
        limit: 30,
        authSnapshot: api.captureAuthSnapshot(),
      );

      final request = adapter.requests.single;
      check(request.path).equals('/api/v1/calendars/events/search');
      check(request.queryParameters)
          .deepEquals({'query': 'plan', 'skip': 30, 'limit': 30});
      check(page.total).equals(41);
      check(page.items.single.id).equals('event-1');
    });
  });

  test('a request for a superseded account is cancelled, not sent', () async {
    adapter.reply('[]');
    final snapshot = api.captureAuthSnapshot();
    api.updateAuthToken('session-b');

    await check(api.getCalendars(authSnapshot: snapshot)).throws<DioException>(
      (it) => it.has((e) => e.type, 'type').equals(DioExceptionType.cancel),
    );
    check(adapter.requests).isEmpty();
  });
}

final class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  String _body = '{}';
  int _status = 200;

  void reply(String body, {int status = 200}) {
    _body = body;
    _status = status;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      _body,
      _status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
