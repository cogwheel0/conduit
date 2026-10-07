import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/calendar/views/calendar_page.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

const calendarTestServer = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

/// The shell the chat, folder and channel pages live in, as in the app.
const calendarShellKey = Key('calendar-shell');
const calendarChatKey = Key('calendar-chat');
Key calendarChannelKey(String id) => Key('calendar-channel-$id');
Key calendarScheduledTaskKey(String id) => Key('calendar-task-$id');

/// UTC-4 all year, so every instant in these tests is plain arithmetic.
final class FixedCalendarZone implements CalendarZone {
  const FixedCalendarZone();

  @override
  Duration offsetAt(DateTime utcInstant) => const Duration(hours: -4);
}

Map<String, dynamic> grant(String type, String principal, String permission) =>
    {
      'id': 'grant-$type-$principal-$permission',
      'resource_type': 'calendar',
      'principal_type': type,
      'principal_id': principal,
      'permission': permission,
    };

Map<String, dynamic> calendarJson(
  String id,
  String owner, {
  String? name,
  bool isDefault = false,
  List<Map<String, dynamic>> grants = const [],
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

Map<String, dynamic> attendeeJson(
  String eventId,
  String user, {
  String status = 'pending',
  Map<String, dynamic>? meta,
}) => {
  'id': 'att-$eventId-$user',
  'event_id': eventId,
  'user_id': user,
  'status': status,
  'meta': meta,
  'created_at': 1,
  'updated_at': 1,
};

/// A stored event in the shape the pinned server returns it.
Map<String, dynamic> eventJson(
  String id,
  String calendarId, {
  String title = 'Planning',
  String owner = 'user-1',
  int startAt = 1791320967123456789,
  int? endAt = 1791324567987654321,
  bool allDay = false,
  String? rrule,
  String? instanceId,
  String? location,
  String? description,
  List<Map<String, dynamic>> attendees = const [],
  Map<String, dynamic>? meta,
}) => {
  'id': id,
  'calendar_id': calendarId,
  'user_id': owner,
  'title': title,
  'description': description,
  'start_at': startAt,
  'end_at': endAt,
  'all_day': allDay,
  'rrule': rrule,
  'color': null,
  'location': location,
  'data': null,
  'meta': meta,
  'is_cancelled': false,
  'instance_id': instanceId,
  'attendees': attendees,
  'created_at': 1790000000123456789,
  'updated_at': 1790000001987654321,
};

Map<String, dynamic> scheduledEntryJson(
  String id, {
  String title = 'Digest',
  int startAt = 1791320967000000001,
  String automationId = 'a1',
  String? runId,
  String? chatId,
  String? status,
}) => {
  'id': id,
  'calendar_id': scheduledTasksCalendarId,
  'user_id': 'user-1',
  'title': title,
  'start_at': startAt,
  'meta': {
    'automation_id': automationId,
    'run_id': ?runId,
    'chat_id': ?chatId,
    'status': ?status,
  },
  'attendees': [],
  'created_at': 1,
  'updated_at': 2,
};

/// Answers the calendar routes like the pinned server for the account
/// `user-1`: an event is listed for the calendars the account can read and for
/// those it attends, its detail needs read access to the calendar (403
/// otherwise), an update applies only the keys it carries, a replaced attendee
/// list keeps each person's answer, and an RSVP needs only an invitation.
final class CalendarWire implements HttpClientAdapter {
  CalendarWire() {
    calendars = [
      calendarJson('cal-mine', 'user-1', name: 'Personal', isDefault: true),
      calendarJson(
        'cal-rw',
        'user-9',
        name: 'Team',
        grants: [grant('user', 'user-1', 'write')],
      ),
      calendarJson(
        'cal-ro',
        'user-9',
        name: 'Holidays',
        isDefault: true,
        grants: [grant('user', 'user-1', 'read')],
      ),
    ];
    events = [eventJson('ev-mine', 'cal-mine', title: 'Planning')];
  }

  late List<Map<String, dynamic>> calendars;
  late List<Map<String, dynamic>> events;
  List<Map<String, dynamic>> scheduled = [];

  /// What the agenda returns instead of the stored events, as when the server
  /// has expanded a recurring event into occurrences.
  List<Map<String, dynamic>>? agendaOverride;
  bool virtualCalendar = false;

  /// Refuses every event detail read, as when access was withdrawn.
  bool denyDetail = false;
  final requests = <RequestOptions>[];
  ({int status, String detail})? rejectWrites;
  Completer<void>? holdWrites;

  Iterable<RequestOptions> get writes =>
      requests.where((r) => r.method != 'GET');

  Iterable<RequestOptions> get agendaRequests =>
      requests.where((r) => r.uri.path == '/api/v1/calendars/events');

  Map<String, dynamic>? stored(String id) =>
      events.where((e) => e['id'] == id).firstOrNull;

  bool _canRead(String calendarId) =>
      calendars.any((c) => c['id'] == calendarId);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    final rejection = rejectWrites;
    if (options.method != 'GET' && rejection != null) {
      return _json({'detail': rejection.detail}, rejection.status);
    }
    if (options.method != 'GET') await holdWrites?.future;

    if (path == '/api/v1/groups/') return _json(<Object>[]);
    if (path == '/api/v1/calendars/') {
      return _json([
        ...calendars,
        if (virtualCalendar)
          {
            'id': scheduledTasksCalendarId,
            'user_id': 'user-1',
            'name': 'Scheduled Tasks',
            'color': '#8b5cf6',
            'is_default': false,
            'is_system': true,
            'created_at': 1,
            'updated_at': 1,
          },
      ]);
    }
    if (path == '/api/v1/calendars/create') {
      final body = options.data as Map<String, dynamic>;
      final created = calendarJson(
        'cal-new-${calendars.length}',
        'user-1',
        name: body['name'] as String,
      );
      calendars.add(created);
      return _json(created);
    }
    final defaultMatch = RegExp(r'/calendars/([^/]+)/default$')
        .firstMatch(path);
    if (defaultMatch != null) {
      final id = Uri.decodeComponent(defaultMatch.group(1)!);
      for (final calendar in calendars) {
        if (calendar['user_id'] == 'user-1') {
          calendar['is_default'] = calendar['id'] == id;
        }
      }
      return _json(calendars.firstWhere((c) => c['id'] == id));
    }
    if (path == '/api/v1/calendars/events') {
      final ids = options.uri.queryParameters['calendar_ids']?.split(',');
      final listed = [
        ...?agendaOverride,
        for (final event
            in agendaOverride == null ? events : const <Map<String, dynamic>>[])
          if ((_canRead(event['calendar_id'] as String) &&
                  (ids == null || ids.contains(event['calendar_id']))) ||
              (event['attendees'] as List).any((a) => a['user_id'] == 'user-1'))
            event,
        if (ids == null || ids.contains(scheduledTasksCalendarId)) ...scheduled,
      ];
      return _json(listed);
    }
    if (path == '/api/v1/calendars/events/create') {
      final body = options.data as Map<String, dynamic>;
      final id = 'new-${events.length}';
      final created = eventJson(
        id,
        body['calendar_id'] as String,
        title: body['title'] as String,
        startAt: body['start_at'] as int,
        endAt: body['end_at'] as int?,
        allDay: body['all_day'] == true,
        rrule: body['rrule'] as String?,
        location: body['location'] as String?,
        description: body['description'] as String?,
        attendees: [
          for (final person in (body['attendees'] as List?) ?? const [])
            attendeeJson(id, (person as Map)['user_id'] as String),
        ],
      );
      events.add(created);
      return _json(created);
    }
    final eventMatch = RegExp(r'/calendars/events/([^/]+)(?:/(\w+))?$')
        .firstMatch(path);
    if (eventMatch == null) return _json({'detail': 'unexpected $path'}, 500);
    final id = Uri.decodeComponent(eventMatch.group(1)!);
    final event = stored(id);
    if (event == null) return _json({'detail': 'Event not found'}, 404);
    switch (eventMatch.group(2)) {
      case 'rsvp':
        final attendees = event['attendees'] as List;
        final mine = attendees.where((a) => a['user_id'] == 'user-1');
        if (mine.isEmpty) {
          return _json({'detail': 'Not an attendee of this event'}, 404);
        }
        final status = (options.data as Map<String, dynamic>)['status'];
        (mine.first as Map<String, dynamic>)['status'] = status;
        return _json({'status': true, 'rsvp': status});
      case 'delete':
        events.remove(event);
        return _json({'status': true});
      case 'update':
        _apply(event, options.data as Map<String, dynamic>);
        return _json(event);
      default:
        if (denyDetail || !_canRead(event['calendar_id'] as String)) {
          return _json({'detail': 'Access denied'}, 403);
        }
        return _json(event);
    }
  }

  /// The server's update: only the keys sent change, `data` and `meta` merge,
  /// and a replaced attendee list keeps each person's answer.
  void _apply(Map<String, dynamic> event, Map<String, dynamic> form) {
    for (final entry in form.entries) {
      switch (entry.key) {
        case 'attendees':
          final before = {
            for (final a in event['attendees'] as List)
              (a as Map)['user_id'] as String: a['status'],
          };
          event['attendees'] = [
            for (final person in entry.value as List)
              attendeeJson(
                event['id'] as String,
                (person as Map)['user_id'] as String,
                status: (before[person['user_id']] ?? 'pending') as String,
                meta: person['meta'] as Map<String, dynamic>?,
              ),
          ];
        case 'data' || 'meta':
          event[entry.key] = {
            ...?(event[entry.key] as Map<String, dynamic>?),
            ...?(entry.value as Map<String, dynamic>?),
          };
        default:
          event[entry.key] = entry.value;
      }
    }
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

/// Records a chat the agenda asked to open, then reports it opened.
final class FakeSelection extends ConversationSelection {
  static final selected = <Conversation>[];

  @override
  Future<ConversationSelectionResult> select(Conversation summary) async {
    selected.add(summary);
    return const ConversationSelectionResult.committed();
  }
}

class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);

  final AppSettings _settings;

  @override
  AppSettings build() => _settings;
}

class _Config extends BackendConfigNotifier {
  _Config(this._config);

  final BackendConfig _config;

  @override
  Future<BackendConfig?> build() async => _config;
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  bool isUncommittedServerConfigCandidate(ServerConfig config) => false;

  @override
  Future<List<ServerConfig>> getServerConfigs() async => const [
    calendarTestServer,
  ];

  @override
  Future<List<ServerConfig>> getServerConfigsStrict() async => const [
    calendarTestServer,
  ];

  @override
  Future<String?> getActiveServerId() async => calendarTestServer.id;
}

/// A signed-in client under test. The same [ApiService] serves the next account
/// after [switchAccount], as when another user signs in on the same server.
final class CalendarSession {
  CalendarSession(this.wire, this.container, this.router, this.api);

  final CalendarWire wire;
  final ProviderContainer container;
  final GoRouter router;
  final ApiService api;
  Object epoch = Object();
  String token = 'token-a';

  void switchAccount() {
    epoch = Object();
    token = 'token-b';
    api.updateAuthToken('token-b');
    container
      ..invalidate(openWebUiAuthSessionEpochProvider)
      ..invalidate(authTokenProvider3)
      ..invalidate(userPermissionsProvider);
  }
}

/// People the principal picker can find.
const calendarDirectory = [
  WorkspacePrincipalPreview(
    id: 'user-2',
    type: WorkspacePrincipalType.user,
    name: 'Grace Hopper',
    email: 'grace@example.com',
  ),
  WorkspacePrincipalPreview(
    id: 'user-3',
    type: WorkspacePrincipalType.user,
    name: 'Alan Turing',
    email: 'alan@example.com',
  ),
];

Future<CalendarSession> pumpCalendar(
  WidgetTester tester, {
  String location = Routes.calendar,
  String shellLocation = Routes.chat,
  Map<String, dynamic> permissions = const {
    'features': {'calendar': true, 'automations': true},
  },
  bool serverEnabled = true,
  String role = 'user',
  void Function(CalendarWire wire)? configureWire,
}) async {
  tester.view
    ..physicalSize = const Size(800, 3200)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  FakeSelection.selected.clear();
  final wire = CalendarWire();
  configureWire?.call(wire);
  final api = ApiService(
    serverConfig: calendarTestServer,
    workerManager: WorkerManager(),
    authToken: 'token-a',
  );
  api.dio.httpClientAdapter = wire;
  addTearDown(api.dispose);

  late final CalendarSession session;
  // The same shape as the app's router: chat, folder and channel are children
  // of one shell that is already mounted before Settings is opened over it, and
  // the calendar and scheduled-task pages are top-level routes outside it.
  final router = GoRouter(
    initialLocation: shellLocation,
    routes: [
      ShellRoute(
        builder: (_, _, child) =>
            KeyedSubtree(key: calendarShellKey, child: child),
        routes: [
          for (final (path, name, key) in [
            (Routes.chat, RouteNames.chat, calendarChatKey),
            (Routes.channel, RouteNames.channel, null),
          ])
            GoRoute(
              path: path,
              name: name,
              pageBuilder: (_, state) => NoTransitionPage<void>(
                key: state.pageKey,
                name: state.name,
                child: SizedBox.expand(
                  key: key ?? calendarChannelKey(state.pathParameters['id']!),
                ),
              ),
            ),
        ],
      ),
      GoRoute(
        path: Routes.calendar,
        name: RouteNames.calendar,
        builder: (_, _) => const CalendarPage(),
      ),
      GoRoute(
        path: Routes.scheduledTaskDetail,
        name: RouteNames.scheduledTaskDetail,
        builder: (_, state) => SizedBox.expand(
          key: calendarScheduledTaskKey(state.pathParameters['id']!),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  final container = ProviderContainer(
    overrides: [
      // Advanced stays off: the calendar does not depend on it.
      appSettingsProvider.overrideWith(() => _Settings(const AppSettings())),
      apiServiceProvider.overrideWithValue(api),
      optimizedStorageServiceProvider.overrideWithValue(_Storage()),
      currentUserProvider2.overrideWithValue(
        User(
          id: 'user-1',
          username: 'user',
          email: 'user@example.com',
          role: role,
        ),
      ),
      isAuthenticatedProvider2.overrideWithValue(true),
      authTokenProvider3.overrideWith((ref) => session.token),
      openWebUiAuthSessionEpochProvider.overrideWith((ref) => session.epoch),
      backendConfigProvider.overrideWith(
        () => _Config(
          BackendConfig(
            serverId: calendarTestServer.id,
            enableCalendar: serverEnabled,
            enableAutomations: true,
          ),
        ),
      ),
      userPermissionsProvider.overrideWith((ref) async => permissions),
      conversationSelectionProvider.overrideWith(FakeSelection.new),
      calendarZoneProvider.overrideWithValue(const FixedCalendarZone()),
      calendarClockProvider.overrideWithValue(
        () => DateTime.utc(2026, 10, 6, 10),
      ),
      workspacePrincipalDirectoryProvider.overrideWithValue(
        WorkspacePrincipalDirectory(
          searchUsers: (query) async => [
            for (final person in calendarDirectory)
              if (person.name.toLowerCase().contains(query.toLowerCase()))
                person,
          ],
          loadGroups: () async => const [],
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  session = CalendarSession(wire, container, router, api);
  // The agenda rebuilds when the active server resolves. In the app it is long
  // resolved by the time Settings opens, so settle it first.
  await container.read(activeServerProvider.future);
  await container.read(userPermissionsProvider.future);
  await container.read(backendConfigProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  unawaited(router.push<void>(location));
  await tester.pumpAndSettle();
  return session;
}
