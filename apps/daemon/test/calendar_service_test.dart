@TestOn('vm')
library;

import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Home server',
  url: 'https://home.invalid',
);

const _ava = User(
  id: 'user-1',
  username: 'ava',
  email: 'ava@example.com',
  name: 'Ava',
  role: 'admin',
);

/// `calendar.*` over one signed-in account whose server answers from memory.
void main() {
  late _Api api;

  setUp(() => api = _Api());
  tearDown(() => api.dispose());

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => api),
        currentUserProvider2.overrideWith((ref) => _ava),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('token'),
        activeServerProvider.overrideWith((ref) async => _server),
        backendConfigProvider.overrideWith(_Config.new),
        userPermissionsProvider.overrideWith(
          (ref) async => const <String, dynamic>{},
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    "a saved event's editor saves later edits to it, not as another event",
    () async {
      final c = container();
      await c.read(activeServerProvider.future);
      final service = CalendarService(c);
      addTearDown(service.dispose);
      final editor = await service.editor(const CalendarEditorOpen());
      final first = editor.fields.copyWith(title: 'Seed swap');
      final saved = await service.save(
        CalendarDraftEdit(token: editor.token, fields: first),
      );
      expect(saved.saved, isTrue, reason: '${saved.issues}');
      // Words typed while that save was out go next, to the same event.
      final again = await service.save(
        CalendarDraftEdit(
          token: editor.token,
          fields: first.copyWith(location: 'The allotment shed'),
        ),
      );
      expect(again.saved, isTrue, reason: '${again.issues}');
      expect(api.created, 1, reason: 'the event was made twice');
      expect(api.updated, ['e1']);
    },
  );
}

/// The account's server, answered from memory.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager());

  var created = 0;
  final updated = <String>[];

  static final _garden = CalendarModel.tryFromJson(const {
    'id': 'garden',
    'user_id': 'user-1',
    'name': 'Garden',
    'color': '#3366ff',
    'is_default': true,
    'is_system': false,
    'access_grants': <Object?>[],
    'created_at': 1790000000000000000,
    'updated_at': 1790000000000000000,
  })!;

  static CalendarEventModel _event(String title) =>
      CalendarEventModel.tryFromJson({
        'id': 'e1',
        'calendar_id': 'garden',
        'user_id': 'user-1',
        'title': title,
        'start_at': 1791320967123456789,
        'end_at': 1791320967123456789 + 3600000000000,
        'all_day': false,
        'rrule': null,
        'instance_id': null,
        'attendees': <Object?>[],
        'created_at': 1,
        'updated_at': 1,
      })!;

  @override
  Future<List<CalendarModel>> getCalendars({
    required ApiAuthSnapshot authSnapshot,
  }) async => [_garden];

  @override
  Future<Set<String>> getCalendarMemberGroupIds({
    required ApiAuthSnapshot authSnapshot,
  }) async => const <String>{};

  @override
  Future<List<CalendarAgendaItem>> getCalendarEvents({
    required String startIso,
    required String endIso,
    Iterable<String>? calendarIds,
    required ApiAuthSnapshot authSnapshot,
  }) async => const <CalendarAgendaItem>[];

  @override
  Future<CalendarEventModel> createCalendarEvent(
    CalendarEventForm form, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    created++;
    return _event(form.title);
  }

  @override
  Future<CalendarEventModel> updateCalendarEvent(
    String eventId,
    CalendarEventUpdate update, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    updated.add(eventId);
    return _event('Seed swap');
  }
}

final class _Config extends BackendConfigNotifier {
  @override
  Future<BackendConfig?> build() async =>
      const BackendConfig(serverId: 'server', enableCalendar: true);
}
