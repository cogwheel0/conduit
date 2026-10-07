import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/calendar/calendar_access.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

typedef _Operation = Future<Object?> Function(
  CalendarAgenda calendar,
  CalendarOwner owner,
);

CalendarEventModel _own() => _parse(_event('ev-mine', 'cal-mine'));

final _operations = <String, _Operation>{
  'fetchEvent': (c, o) => c.fetchEvent('ev-mine', owner: o),
  'createEvent': (c, o) => c.createEvent(
    const CalendarEventForm(
      calendarId: 'cal-mine',
      title: 't',
      startAtNs: 1791320940000000000,
    ),
    owner: o,
  ),
  'updateEvent': (c, o) => c.updateEvent(
    _own(),
    const CalendarEventUpdate({'title': 'x'}),
    owner: o,
  ),
  'deleteEvent': (c, o) => c.deleteEvent(_own(), owner: o),
  'respond': (c, o) => c.respond(
    _parse(_event('ev-invite', 'cal-hidden', attendees: ['user-1'])),
    CalendarRsvp.accepted,
    owner: o,
  ),
  'createCalendar': (c, o) =>
      c.createCalendar(const CalendarForm(name: 'Work'), owner: o),
  'makeDefault': (c, o) => c.makeDefault(
    CalendarModel.tryFromJson(_calendar('cal-mine', 'user-1'))!,
    owner: o,
  ),
  'search': (c, o) => c.search('plan', owner: o),
};

void main() {
  group('capability', () {
    // Each case is one way the account may not use the calendar. The load and
    // every operation must refuse before any request.
    final denied = <String, void Function(_Session session)>{
      'server flag off': (s) => s.config = _config(enabled: false),
      'server flag missing': (s) => s.config = _config(enabled: null),
      'config from another server': (s) =>
          s.config = _config(serverId: 'other-server'),
      'no permission document entry': (s) => s.permissions = const {},
      'permission off': (s) => s.permissions = const {
        'features': {'calendar': false},
      },
    };

    for (final MapEntry(:key, :value) in denied.entries) {
      test('$key refuses the load and every operation', () async {
        final session = await _Session.start(configure: value);
        addTearDown(session.dispose);
        final calendar = session.container.read(
          calendarAgendaProvider.notifier,
        );
        final owner = calendar.captureOwner()!;

        await expectLater(
          session.container.read(calendarAgendaProvider.future),
          throwsA(isA<CalendarUnavailableException>()),
        );
        for (final MapEntry(key: name, value: run) in _operations.entries) {
          await expectLater(
            run(calendar, owner),
            throwsA(isA<CalendarUnavailableException>()),
            reason: name,
          );
        }

        check(session.server.requests).isEmpty();
        check(session.container.read(calendarAvailableProvider)).isFalse();
      });
    }

    test('a permitted account loads, and admins need no permission', () async {
      for (final configure in <void Function(_Session)>[
        (s) {},
        (s) {
          s.user = _user(role: 'admin');
          s.permissions = const {};
        },
      ]) {
        final session = await _Session.start(configure: configure);
        addTearDown(session.dispose);

        final data = await session.container.read(
          calendarAgendaProvider.future,
        );

        check(data.calendars.map((c) => c.id)).contains('cal-mine');
        check(session.container.read(calendarAvailableProvider)).isTrue();
      }
    });
  });

  group('owner captured when a surface opens', () {
    test('nothing reaches the server once another account signs in on the '
        'same API', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      final owner = calendar.captureOwner()!;

      session.switchAccount();
      await session.container.read(calendarAgendaProvider.future);
      session.server.requests.clear();

      for (final MapEntry(:key, :value) in _operations.entries) {
        await expectLater(
          value(calendar, owner),
          throwsA(isA<CalendarOwnerChangedException>()),
          reason: key,
        );
      }
      // A refresh never throws; for a stale owner it simply does not run.
      await calendar.refresh(owner: owner);
      check(session.server.requests).isEmpty();
    });

    test(
      'an agenda that arrives after an account switch is discarded',
      () async {
        final session = await _Session.start();
        addTearDown(session.dispose);
        await session.container.read(calendarAgendaProvider.future);
        final calendar = session.container.read(
          calendarAgendaProvider.notifier,
        );
        final owner = calendar.captureOwner()!;

        final gate = session.server.holdAgenda = Completer<void>();
        final refreshed = calendar.refresh(owner: owner);
        await pumpEventQueue();
        session.server.holdAgenda = null;

        session.server.events = [
          _event('ev-b', 'cal-mine', title: 'Account B'),
        ];
        session.switchAccount();
        await session.container.read(calendarAgendaProvider.future);
        gate.complete();
        await refreshed;

        final shown = session.container
            .read(calendarAgendaProvider)
            .requireValue;
        check(shown.items.whereType<CalendarEventModel>().map((e) => e.title))
            .deepEquals(['Account B']);
      },
    );

    test('a detail read that answers after the switch is refused', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      final owner = calendar.captureOwner()!;

      final gate = session.server.holdReads = Completer<void>();
      final read = calendar.fetchEvent('ev-mine', owner: owner);
      final refused = expectLater(
        read,
        throwsA(isA<CalendarOwnerChangedException>()),
      );
      await pumpEventQueue();
      session.server.holdReads = null;
      session.switchAccount();
      await session.container.read(calendarAgendaProvider.future);
      gate.complete();

      await refused;
    });

    test('a write accepted for the first account still completes', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      final owner = calendar.captureOwner()!;

      final gate = session.server.holdWrites = Completer<void>();
      final delete = calendar.deleteEvent(_own(), owner: owner);
      await pumpEventQueue();
      session.server.holdWrites = null;
      session.switchAccount();
      gate.complete();

      // The server accepted it for the first account; the surface decides it
      // is no longer for the signed-in one.
      await delete;
      check(calendar.isCurrentOwner(owner)).isFalse();
      check(session.server.writes).length.equals(1);
    });
  });

  group('agenda', () {
    test('asks for the device-zone range, with the calendars chosen', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      final data = await session.container.read(calendarAgendaProvider.future);

      final first = session.server.requests.firstWhere(
        (r) => r.uri.path.endsWith('/calendars/events'),
      );
      // "Now" is 2026-10-06T10:00Z and the fixed zone is UTC-4.
      check(first.uri.queryParameters).deepEquals({
        'start': '2026-10-06T00:00:00-04:00',
        'end': '2026-10-20T00:00:00-04:00',
      });
      check(data.range.dayCount).equals(calendarAgendaDays);

      final calendar = session.container.read(calendarAgendaProvider.notifier);
      await calendar.refresh(
        owner: calendar.captureOwner()!,
        filter: {'cal-ro', 'cal-mine'},
      );
      final filtered = session.server.requests.lastWhere(
        (r) => r.uri.path.endsWith('/calendars/events'),
      );
      check(filtered.uri.queryParameters['calendar_ids'])
          .equals('cal-mine,cal-ro');
    });

    test('keeps every occurrence of a recurring event', () async {
      final session = await _Session.start(
        configure: (s) => s.server.events = [
          for (final day in [0, 1, 2])
            _event(
              'series',
              'cal-ro',
              instanceId: 'series_$day',
              startAt: 1791777600000000000 + day * 86400000000000,
              rrule: 'FREQ=DAILY;COUNT=3',
            ),
        ],
      );
      addTearDown(session.dispose);

      final data = await session.container.read(calendarAgendaProvider.future);

      check(
        data.items.map((i) => i.key),
      ).deepEquals(['series|series_0', 'series|series_1', 'series|series_2']);
    });

    test('shows scheduled-task entries only to an account that may use '
        'scheduled tasks', () async {
      for (final (automations, shown) in [(true, true), (false, false)]) {
        final session = await _Session.start(
          configure: (s) {
            s.config = _config(automations: automations);
            s.permissions = {
              'features': {'calendar': true, 'automations': automations},
            };
            s.server.virtualCalendar = true;
            s.server.events = [_virtualEntry()];
          },
        );
        addTearDown(session.dispose);

        final data = await session.container.read(
          calendarAgendaProvider.future,
        );

        check(data.scheduledTasksVisible).equals(shown);
        check(data.items.whereType<ScheduledTaskCalendarEntry>()).length
            .equals(shown ? 1 : 0);
        check(data.calendars.any((c) => c.isVirtual)).equals(shown);
      }
    });
  });

  group('writing events', () {
    test('creating goes to a calendar the account can write', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      final owner = calendar.captureOwner()!;
      session.server.requests.clear();

      await calendar.createEvent(
        const CalendarEventForm(
          calendarId: 'cal-rw',
          title: 'Standup',
          startAtNs: 1791320940000000000,
          attendees: [
            {'user_id': 'user-2'},
          ],
        ),
        owner: owner,
      );

      final write = session.server.writes.single;
      check(write.uri.path).equals('/api/v1/calendars/events/create');
      check(write.data).isA<Map<String, dynamic>>().deepEquals({
        'calendar_id': 'cal-rw',
        'title': 'Standup',
        'start_at': 1791320940000000000,
        'all_day': false,
        'attendees': [
          {'user_id': 'user-2'},
        ],
      });
    });

    test('creating in a read-only or virtual calendar sends nothing', () async {
      final session = await _Session.start(
        configure: (s) => s.server.virtualCalendar = true,
      );
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      final owner = calendar.captureOwner()!;
      session.server.requests.clear();

      for (final id in ['cal-ro', scheduledTasksCalendarId, 'unknown']) {
        await expectLater(
          calendar.createEvent(
            CalendarEventForm(
              calendarId: id,
              title: 't',
              startAtNs: 1791320940000000000,
            ),
            owner: owner,
          ),
          throwsA(_denied(CalendarDenial.notWritable)),
          reason: id,
        );
      }
      check(session.server.writes).isEmpty();
    });

    test(
      'an edit sends only what changed, and a move needs both ends',
      () async {
        final session = await _Session.start();
        addTearDown(session.dispose);
        await session.container.read(calendarAgendaProvider.future);
        final calendar = session.container.read(
          calendarAgendaProvider.notifier,
        );
        final owner = calendar.captureOwner()!;
        session.server.requests.clear();
        final event = _own();

        await calendar.updateEvent(
          event,
          const CalendarEventUpdate({'title': 'Renamed'}),
          owner: owner,
        );
        await calendar.updateEvent(
          event,
          const CalendarEventUpdate({'calendar_id': 'cal-rw'}),
          owner: owner,
        );

        check(session.server.writes.map((r) => r.data)).deepEquals([
          {'title': 'Renamed'},
          {'calendar_id': 'cal-rw'},
        ]);
        session.server.requests.clear();

        // A read-only, an unknown and the virtual destination are all refused.
        for (final destination in [
          'cal-ro',
          'unknown',
          scheduledTasksCalendarId,
        ]) {
          await expectLater(
            calendar.updateEvent(
              event,
              CalendarEventUpdate({'calendar_id': destination}),
              owner: owner,
            ),
            throwsA(_denied(CalendarDenial.destinationNotWritable)),
            reason: destination,
          );
        }
        // An event in a read-only calendar cannot be edited or deleted at all.
        final readOnly = _parse(_event('ev-ro', 'cal-ro'));
        await expectLater(
          calendar.updateEvent(
            readOnly,
            const CalendarEventUpdate({'title': 'x'}),
            owner: owner,
          ),
          throwsA(_denied(CalendarDenial.notWritable)),
        );
        await expectLater(
          calendar.deleteEvent(readOnly, owner: owner),
          throwsA(_denied(CalendarDenial.notWritable)),
        );
        check(session.server.writes).isEmpty();
      },
    );

    test('write access comes from a user grant, a public grant, a group or '
        'being an admin', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      final data = await session.container.read(calendarAgendaProvider.future);

      check(data.writableCalendars.map((c) => c.id))
          .unorderedEquals(['cal-mine', 'cal-rw', 'cal-group', 'cal-public']);

      final admin = await _Session.start(
        configure: (s) {
          s.user = _user(role: 'admin');
          s.permissions = const {};
        },
      );
      addTearDown(admin.dispose);
      final adminData = await admin.container.read(
        calendarAgendaProvider.future,
      );
      check(adminData.writableCalendars.map((c) => c.id)).unorderedEquals([
        'cal-mine',
        'cal-rw',
        'cal-ro',
        'cal-group',
        'cal-public',
      ]);
    });

    test(
      'a rejected save keeps the draft and makes no second request',
      () async {
        final session = await _Session.start();
        addTearDown(session.dispose);
        await session.container.read(calendarAgendaProvider.future);
        final calendar = session.container.read(
          calendarAgendaProvider.notifier,
        );
        final owner = calendar.captureOwner()!;
        session.server.requests.clear();
        session.server.writeRejection = (
          status: 422,
          detail: 'Recurrence is too frequent',
        );

        await expectLater(
          calendar.updateEvent(
            _own(),
            const CalendarEventUpdate({'rrule': 'FREQ=HOURLY'}),
            owner: owner,
          ),
          throwsA(isA<DioException>()),
        );

        check(session.server.writes).length.equals(1);
        check(session.server.requests.where((r) => r.method == 'DELETE'))
            .isEmpty();
      },
    );

    test('deleting a stored event sends its id and reloads', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      session.server.requests.clear();

      await calendar.deleteEvent(_own(), owner: calendar.captureOwner()!);

      final write = session.server.writes.single;
      check(write.method).equals('DELETE');
      check(write.uri.path).equals('/api/v1/calendars/events/ev-mine/delete');
      check(
        session.server.requests.where(
          (r) => r.uri.path.endsWith('/calendars/events'),
        ),
      ).isNotEmpty();
    });

    test('a scheduled-task entry cannot be sent to an event route', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      final owner = calendar.captureOwner()!;
      session.server.requests.clear();

      final disguised = [
        _parse(_event('auto_a1', scheduledTasksCalendarId)),
        _parse(_event('run_r1', 'cal-mine')),
      ];
      for (final event in disguised) {
        for (final run in <Future<Object?> Function()>[
          () => calendar.updateEvent(
            event,
            const CalendarEventUpdate({'title': 'x'}),
            owner: owner,
          ),
          () => calendar.deleteEvent(event, owner: owner),
          () => calendar.respond(event, CalendarRsvp.accepted, owner: owner),
        ]) {
          await expectLater(
            run(),
            throwsA(_denied(CalendarDenial.scheduledTaskEntry)),
          );
        }
      }
      check(session.server.requests).isEmpty();
    });
  });

  group('invitations', () {
    // The pinned server lists an event the account only attends, even when the
    // account has no read grant on its calendar; the detail route then answers
    // 403, and edits are refused, while the RSVP route works.
    test('an attendee without calendar access answers from the agenda '
        'projection', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      final data = await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      final owner = calendar.captureOwner()!;

      final invitation = data.items.whereType<CalendarEventModel>().singleWhere(
        (e) => e.id == 'ev-invite',
      );
      check(data.calendars.map((c) => c.id))
          .not((it) => it.contains('cal-hidden'));
      check(data.access!.canEdit(invitation, data.calendars)).isFalse();
      check(data.access!.canRsvp(invitation)).isTrue();

      await expectLater(
        calendar.fetchEvent('ev-invite', owner: owner),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            403,
          ),
        ),
      );
      session.server.requests.clear();

      final stored = await calendar.respond(
        invitation,
        CalendarRsvp.tentative,
        owner: owner,
      );

      check(stored).equals(CalendarRsvp.tentative);
      final write = session.server.writes.single;
      check(write.uri.path).equals('/api/v1/calendars/events/ev-invite/rsvp');
      check(write.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({'status': 'tentative'});
      session.server.requests.clear();

      await expectLater(
        calendar.updateEvent(
          invitation,
          const CalendarEventUpdate({'title': 'Mine now'}),
          owner: owner,
        ),
        throwsA(_denied(CalendarDenial.notWritable)),
      );
      await expectLater(
        calendar.deleteEvent(invitation, owner: owner),
        throwsA(_denied(CalendarDenial.notWritable)),
      );
      check(session.server.writes).isEmpty();
    });

    test('a person who is not invited has no answer to give', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      session.server.requests.clear();

      await expectLater(
        calendar.respond(
          _parse(_event('ev-ro', 'cal-ro', attendees: ['user-2'])),
          CalendarRsvp.accepted,
          owner: calendar.captureOwner()!,
        ),
        throwsA(_denied(CalendarDenial.notInvited)),
      );
      check(session.server.requests).isEmpty();
    });

    test('an attendee with read-only access can still answer', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      session.server.requests.clear();

      await calendar.respond(
        _parse(_event('ev-ro', 'cal-ro', attendees: ['user-1'])),
        CalendarRsvp.declined,
        owner: calendar.captureOwner()!,
      );

      check(session.server.writes.single.uri.path)
          .endsWith('/events/ev-ro/rsvp');
    });
  });

  group('calendars', () {
    test('the account\'s default is its own, never another owner\'s', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      final data = await session.container.read(calendarAgendaProvider.future);

      // cal-ro is the other user's default; cal-mine is this account's.
      check(data.calendars.firstWhere((c) => c.id == 'cal-ro').isDefault)
          .isTrue();
      check(data.access!.defaultCalendar(data.calendars)?.id)
          .equals('cal-mine');
    });

    test('only an owned stored calendar can be made the default', () async {
      final session = await _Session.start(
        configure: (s) => s.server.virtualCalendar = true,
      );
      addTearDown(session.dispose);
      final data = await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      final owner = calendar.captureOwner()!;
      session.server.requests.clear();

      for (final id in ['cal-rw', 'cal-ro', scheduledTasksCalendarId]) {
        await expectLater(
          calendar.makeDefault(
            data.calendars.firstWhere((c) => c.id == id),
            owner: owner,
          ),
          throwsA(_denied(CalendarDenial.notOwnCalendar)),
          reason: id,
        );
      }
      check(session.server.writes).isEmpty();

      await calendar.makeDefault(
        data.calendars.firstWhere((c) => c.id == 'cal-mine'),
        owner: owner,
      );
      check(session.server.writes.single.uri.path)
          .equals('/api/v1/calendars/cal-mine/default');
    });

    test('creating one sends a name and colour and reloads', () async {
      final session = await _Session.start();
      addTearDown(session.dispose);
      await session.container.read(calendarAgendaProvider.future);
      final calendar = session.container.read(calendarAgendaProvider.notifier);
      session.server.requests.clear();

      await calendar.createCalendar(
        const CalendarForm(name: 'Work', color: '#3366ff'),
        owner: calendar.captureOwner()!,
      );

      check(session.server.writes.single.data)
          .isA<Map<String, dynamic>>()
          .deepEquals({'name': 'Work', 'color': '#3366ff'});
      check(
        session.container
            .read(calendarAgendaProvider)
            .requireValue
            .writableCalendars
            .map((c) => c.name),
      ).contains('Work');
    });
  });

  group('access rules', () {
    test('an account that owns nothing and holds no grant cannot write', () {
      const access = CalendarAccess(userId: 'me', isAdmin: false);
      final calendar = CalendarModel.tryFromJson(_calendar('c', 'other'))!;

      check(access.canWrite(calendar)).isFalse();
      check(access.canMakeDefault(calendar)).isFalse();
    });

    test('a read grant, or a write grant for someone else, is not write', () {
      const access = CalendarAccess(
        userId: 'me',
        isAdmin: false,
        groupIds: {'g-1'},
      );
      for (final grants in [
        [_grant('user', 'me', 'read')],
        [_grant('user', 'someone', 'write')],
        [_grant('group', 'g-2', 'write')],
        [_grant('anyone', '*', 'write')],
      ]) {
        final calendar = CalendarModel.tryFromJson(
          _calendar('c', 'other', grants: grants),
        )!;
        check(access.canWrite(calendar)).isFalse();
      }
    });
  });
}

Map<String, dynamic> _grant(String type, String principal, String permission) =>
    {
      'id': 'grant-$type-$principal-$permission',
      'resource_type': 'calendar',
      'principal_type': type,
      'principal_id': principal,
      'permission': permission,
    };

Map<String, dynamic> _calendar(
  String id,
  String owner, {
  bool isDefault = false,
  List<Map<String, dynamic>> grants = const [],
  String? name,
}) => {
  'id': id,
  'user_id': owner,
  'name': name ?? id,
  'color': '#3366ff',
  'is_default': isDefault,
  'is_system': false,
  'access_grants': grants,
  'created_at': 1790000000000000000,
  'updated_at': 1790000000000000000,
};

Map<String, dynamic> _event(
  String id,
  String calendarId, {
  String title = 'Event',
  List<String> attendees = const [],
  String? instanceId,
  String? rrule,
  int startAt = 1791320967123456789,
}) => {
  'id': id,
  'calendar_id': calendarId,
  'user_id': 'user-9',
  'title': title,
  'start_at': startAt,
  'end_at': startAt + 3600000000000,
  'all_day': false,
  'rrule': rrule,
  'instance_id': instanceId,
  'attendees': [
    for (final user in attendees)
      {
        'id': 'att-$id-$user',
        'event_id': id,
        'user_id': user,
        'status': 'pending',
        'created_at': 1,
        'updated_at': 1,
      },
  ],
  'created_at': 1,
  'updated_at': 2,
};

Map<String, dynamic> _virtualEntry() => {
  'id': 'auto_a1',
  'calendar_id': scheduledTasksCalendarId,
  'user_id': 'user-1',
  'title': 'Digest',
  'start_at': 1791320967000000001,
  'meta': {'automation_id': 'a1'},
  'attendees': [],
  'created_at': 1,
  'updated_at': 2,
};

CalendarEventModel _parse(Map<String, dynamic> json) =>
    CalendarEventModel.tryFromJson(json)!;

Matcher _denied(CalendarDenial denial) => isA<CalendarPermissionException>()
    .having((e) => e.denial, 'denial', denial);

BackendConfig _config({
  bool? enabled = true,
  bool automations = true,
  String? serverId = 'test-server',
}) => BackendConfig(
  serverId: serverId,
  enableCalendar: enabled,
  enableAutomations: automations,
);

User _user({String role = 'user'}) =>
    User(id: 'user-1', username: 'user', email: 'user@example.com', role: role);

/// UTC-4 all year; the zone's rules are tested in the time test.
final class _FixedZone implements CalendarZone {
  const _FixedZone();

  @override
  Duration offsetAt(DateTime utcInstant) => const Duration(hours: -4);
}

/// One signed-in client whose account can be switched without replacing the
/// [ApiService], as happens when another user signs in on the same server.
final class _Session {
  _Session._(this.api, this.server) {
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        currentUserProvider2.overrideWith((ref) => user),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWith((ref) => token),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => _epoch),
        backendConfigProvider.overrideWith(() => _FakeBackendConfig(this)),
        userPermissionsProvider.overrideWith((ref) async => permissions),
        calendarZoneProvider.overrideWithValue(const _FixedZone()),
        calendarClockProvider.overrideWithValue(
          () => DateTime.utc(2026, 10, 6, 10),
        ),
      ],
    );
  }

  static Future<_Session> start({
    void Function(_Session session)? configure,
  }) async {
    final server = _Server();
    final api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    api.dio.httpClientAdapter = server;
    final session = _Session._(api, server);
    configure?.call(session);
    await session.container.read(activeServerProvider.future);
    await session.container.read(userPermissionsProvider.future);
    await session.container.read(backendConfigProvider.future);
    await pumpEventQueue();
    return session;
  }

  final ApiService api;
  final _Server server;
  late final ProviderContainer container;
  Object _epoch = Object();
  String token = 'token-a';
  User user = _user();
  BackendConfig? config = _config();
  Map<String, dynamic> permissions = const {
    'features': {'calendar': true, 'automations': true},
  };

  void switchAccount() {
    _epoch = Object();
    token = 'token-b';
    api.updateAuthToken('token-b');
    container
      ..invalidate(openWebUiAuthSessionEpochProvider)
      ..invalidate(authTokenProvider3)
      ..invalidate(userPermissionsProvider);
  }

  void dispose() {
    container.dispose();
    api.dispose();
  }
}

final class _FakeBackendConfig extends BackendConfigNotifier {
  _FakeBackendConfig(this._session);

  final _Session _session;

  @override
  Future<BackendConfig?> build() async => _session.config;
}

final class _Storage extends Fake implements OptimizedStorageService {
  @override
  bool isUncommittedServerConfigCandidate(ServerConfig config) => false;

  @override
  Future<List<ServerConfig>> getServerConfigs() async => const [_server];

  @override
  Future<List<ServerConfig>> getServerConfigsStrict() async => const [_server];

  @override
  Future<String?> getActiveServerId() async => _server.id;
}

/// A server that answers like the pinned one for the account `user-1`: shared
/// calendars with their grants, an attendee-only invitation whose calendar the
/// account cannot read (listed in the agenda, 403 on detail), and a recording
/// of every request.
final class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool virtualCalendar = false;
  Completer<void>? holdAgenda;
  Completer<void>? holdReads;
  Completer<void>? holdWrites;
  ({int status, String detail})? writeRejection;
  final created = <Map<String, dynamic>>[];

  late List<Map<String, dynamic>> events = [
    _event('ev-mine', 'cal-mine'),
    _event('ev-ro', 'cal-ro'),
    _event('ev-invite', 'cal-hidden', attendees: ['user-1']),
  ];

  Iterable<RequestOptions> get writes =>
      requests.where((r) => r.method != 'GET');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    final rejection = writeRejection;
    if (options.method != 'GET' && rejection != null) {
      return _json({'detail': rejection.detail}, rejection.status);
    }
    if (path == '/api/v1/groups/') {
      return _json([
        {'id': 'g-1', 'name': 'Team'},
      ]);
    }
    if (path == '/api/v1/calendars/') {
      return _json([
        _calendar('cal-mine', 'user-1', isDefault: true),
        _calendar(
          'cal-rw',
          'user-9',
          grants: [_grant('user', 'user-1', 'write')],
        ),
        // The other owner's default; it must not read as this account's.
        _calendar(
          'cal-ro',
          'user-9',
          isDefault: true,
          grants: [_grant('user', 'user-1', 'read')],
        ),
        _calendar(
          'cal-group',
          'user-9',
          grants: [_grant('group', 'g-1', 'write')],
        ),
        _calendar(
          'cal-public',
          'user-9',
          grants: [_grant('user', '*', 'write')],
        ),
        ...created,
        if (virtualCalendar)
          {
            'id': scheduledTasksCalendarId,
            'user_id': 'user-1',
            'name': 'Scheduled Tasks',
            'is_default': false,
            'is_system': true,
            'created_at': 1,
            'updated_at': 1,
          },
      ]);
    }
    if (path == '/api/v1/calendars/create') {
      final body = options.data as Map<String, dynamic>;
      final calendar = _calendar(
        'cal-new',
        'user-1',
        name: body['name'] as String,
      );
      created.add(calendar);
      await holdWrites?.future;
      return _json(calendar);
    }
    if (path.endsWith('/default')) {
      return _json(_calendar('cal-mine', 'user-1'));
    }
    if (path == '/api/v1/calendars/events') {
      await holdAgenda?.future;
      return _json(events);
    }
    if (path == '/api/v1/calendars/events/search') {
      await holdReads?.future;
      return _json({'items': [], 'total': 0});
    }
    if (path.endsWith('/rsvp')) {
      final status = (options.data as Map<String, dynamic>)['status'];
      return _json({'status': true, 'rsvp': status});
    }
    if (path.endsWith('/delete')) {
      await holdWrites?.future;
      return _json({'status': true});
    }
    final event = events.firstWhere(
      (e) => path.contains('/events/${e['id']}'),
      orElse: () => events.first,
    );
    if (options.method == 'GET') {
      await holdReads?.future;
      // No read grant on the invitation's calendar.
      if (event['calendar_id'] == 'cal-hidden') {
        return _json({'detail': 'Access denied'}, 403);
      }
    } else {
      await holdWrites?.future;
    }
    return _json(event);
  }

  ResponseBody _json(Object body, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
