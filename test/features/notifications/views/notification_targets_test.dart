import 'dart:convert';

import 'package:conduit/features/notifications/views/notification_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart'
    show AdaptiveSwitch;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

const _secretUrl = 'https://hooks.example.com/services/T000/B000/s3cr3t';
const _advanced = AppSettings(advancedFeaturesEnabled: true);

void main() {
  group('visibility', () {
    testWidgets('Advanced off hides the section and the local toggles stay', (
      tester,
    ) async {
      final session = await _pump(tester, settings: const AppSettings());

      expect(find.text('Webhook destinations'), findsNothing);
      expect(find.text('Enable notifications'), findsOneWidget);
      // Hidden, not deleted: nothing is sent, so server delivery is untouched.
      expect(session.wire.requests, isEmpty);
    });

    testWidgets('an account without the permission sees no section', (
      tester,
    ) async {
      final session = await _pump(
        tester,
        permissions: const {
          'features': {'webhooks': false},
        },
      );

      expect(find.text('Webhook destinations'), findsNothing);
      expect(find.text('Enable notifications'), findsOneWidget);
      expect(session.wire.requests, isEmpty);
    });

    testWidgets('a server with user webhooks off shows no section', (
      tester,
    ) async {
      final session = await _pump(tester, serverEnabled: false);

      expect(find.text('Webhook destinations'), findsNothing);
      expect(session.wire.requests, isEmpty);
    });

    testWidgets('the section is reachable without the master toggle', (
      tester,
    ) async {
      await _pump(tester);

      expect(find.text('Webhook destinations'), findsOneWidget);
      expect(find.text('ops'), findsOneWidget);
    });
  });

  group('list and editor', () {
    testWidgets('lists what the server holds without sending a test', (
      tester,
    ) async {
      final session = await _pump(tester);

      expect(find.text('ops'), findsOneWidget);
      expect(
        find.textContaining('https://hooks.example.com/...cret'),
        findsOneWidget,
      );
      expect(find.textContaining('Default'), findsOneWidget);

      await _openEditor(tester, 'ops');

      expect(session.wire.writes, isEmpty);
      expect(session.wire.tests, 0);
    });

    testWidgets('the editor labels events from the catalog and keeps one the '
        'server does not list', (tester) async {
      await _pump(
        tester,
        targets: [
          _target(events: const ['chat.finished', 'future.event']),
        ],
      );

      await _openEditor(tester, 'ops');

      expect(find.text('Chat finished'), findsOneWidget);
      expect(find.text('Channel message'), findsOneWidget);
      expect(find.text('future.event'), findsOneWidget);
      expect(
        find.textContaining("Not in this server's event list"),
        findsOneWidget,
      );
    });

    testWidgets('a change to delivery sends only delivery, never the URL', (
      tester,
    ) async {
      final session = await _pump(tester);
      await _openEditor(tester, 'ops');

      await tester.tap(
        find.byKey(const Key('notification-target-delivery-always')),
      );
      await tester.pump();
      await _save(tester);

      expect(session.wire.writes, hasLength(1));
      final put = session.wire.writes.single;
      expect(put.method, 'PUT');
      expect(put.path, '/api/v1/notifications/targets/ops');
      expect(put.data, {'delivery': 'always'});
    });

    testWidgets('an event change sends the whole selection, unknown ids '
        'included', (tester) async {
      final session = await _pump(
        tester,
        targets: [
          _target(events: const ['chat.finished', 'future.event']),
        ],
      );
      await _openEditor(tester, 'ops');

      await tester.tap(
        find.descendant(
          of: find.byKey(
            const Key('notification-target-event-channel.message'),
          ),
          matching: find.byType(AdaptiveSwitch),
        ),
      );
      await tester.pump();
      await _save(tester);

      final events = (session.wire.writes.single.data as Map)['events'] as List;
      expect(events, ['chat.finished', 'channel.message', 'future.event']);
    });

    testWidgets('a typed URL is the only way config is sent', (tester) async {
      final session = await _pump(tester);
      await _openEditor(tester, 'ops');

      await tester.enterText(
        find.byKey(const Key('notification-target-url')),
        _secretUrl,
      );
      await _save(tester);

      expect(session.wire.writes.single.data, {
        'config': {'url': _secretUrl},
      });
    });

    testWidgets('a new destination needs a URL and sends the form', (
      tester,
    ) async {
      final session = await _pump(tester);
      await tester.tap(find.byKey(const Key('notification-targets-add')));
      await tester.pumpAndSettle();

      await _save(tester);
      expect(find.text('Enter the webhook URL.'), findsOneWidget);
      expect(session.wire.writes, isEmpty);

      await tester.enterText(
        find.byKey(const Key('notification-target-name')),
        'team-chat',
      );
      await tester.enterText(
        find.byKey(const Key('notification-target-url')),
        _secretUrl,
      );
      await _save(tester);

      expect(session.wire.writes.single.method, 'POST');
      expect(session.wire.writes.single.data, {
        'id': 'team-chat',
        'type': 'webhook',
        'enabled': true,
        'events': <String>[],
        'delivery': 'away',
        'config': {'url': _secretUrl},
      });
    });

    testWidgets('one press of Test calls the test endpoint once', (
      tester,
    ) async {
      final session = await _pump(tester);
      await _openEditor(tester, 'ops');
      expect(session.wire.tests, 0);

      await tester.tap(find.byKey(const Key('notification-target-test')));
      await tester.pumpAndSettle();

      expect(session.wire.tests, 1);
      expect(find.text('Test notification sent.'), findsOneWidget);
    });

    testWidgets('a failed test says so with the server\'s reason', (
      tester,
    ) async {
      final session = await _pump(tester);
      await _openEditor(tester, 'ops');
      session.wire.rejectWrites = 'Webhook delivery failed';

      await tester.tap(find.byKey(const Key('notification-target-test')));
      await tester.pumpAndSettle();

      expect(find.text('Webhook delivery failed'), findsOneWidget);
      expect(session.wire.tests, 1);
    });

    testWidgets('Make default sends the default call', (tester) async {
      final session = await _pump(tester, targets: [_target(isDefault: false)]);
      await _openEditor(tester, 'ops');

      await tester.tap(
        find.byKey(const Key('notification-target-make-default')),
      );
      await tester.pumpAndSettle();

      expect(session.wire.writes.single.method, 'PUT');
      expect(
        session.wire.writes.single.path,
        '/api/v1/notifications/targets/ops/default',
      );
    });

    testWidgets('Delete waits for confirmation', (tester) async {
      final session = await _pump(tester);
      await _openEditor(tester, 'ops');

      await tester.tap(find.byKey(const Key('notification-target-delete')));
      await tester.pumpAndSettle();
      expect(session.wire.writes, isEmpty);

      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(session.wire.writes, isEmpty);

      await tester.tap(find.byKey(const Key('notification-target-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete destination').last);
      await tester.pumpAndSettle();

      expect(session.wire.writes.single.method, 'DELETE');
    });

    testWidgets('a refused save keeps the form and shows the server\'s reason, '
        'not the URL', (tester) async {
      final session = await _pump(tester);
      await tester.tap(find.byKey(const Key('notification-targets-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('notification-target-url')),
        _secretUrl,
      );
      session.wire.rejectWrites = 'Invalid URL';

      await _save(tester);

      expect(find.text('Invalid URL'), findsOneWidget);
      expect(find.textContaining('s3cr3t'), findsOneWidget); // the field only
      expect(
        find.descendant(
          of: find.byKey(const Key('notification-target-error')),
          matching: find.textContaining('s3cr3t'),
        ),
        findsNothing,
      );

      session.wire.rejectWrites = null;
      await _save(tester);
      expect(
        session.wire.writes.last.data,
        containsPair('config', {'url': _secretUrl}),
      );
      expect(find.byKey(const Key('notification-target-url')), findsNothing);
    });
  });

  group('a form opened for one account', () {
    testWidgets('does not save for the account that signs in next', (
      tester,
    ) async {
      final session = await _pump(tester);
      await tester.tap(find.byKey(const Key('notification-targets-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('notification-target-url')),
        _secretUrl,
      );

      session.switchAccount();
      await tester.pumpAndSettle();
      await _save(tester);

      expect(session.wire.writes, isEmpty);
      // The sheet stays open with what was typed, and says why.
      expect(find.byKey(const Key('notification-target-url')), findsOneWidget);
      expect(find.textContaining('s3cr3t'), findsOneWidget);
      expect(
        find.text(
          'The account changed. Close this and open the destination again.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('does not test, default or delete for the next account', (
      tester,
    ) async {
      final session = await _pump(tester, targets: [_target(isDefault: false)]);
      await _openEditor(tester, 'ops');

      session.switchAccount();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notification-target-test')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('notification-target-make-default')),
      );
      await tester.pumpAndSettle();

      expect(session.wire.tests, 0);
      expect(session.wire.writes, isEmpty);
    });

    testWidgets('does not delete after a confirmation outlived the account', (
      tester,
    ) async {
      final session = await _pump(tester);
      await _openEditor(tester, 'ops');

      await tester.tap(find.byKey(const Key('notification-target-delete')));
      await tester.pumpAndSettle();
      session.switchAccount();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete destination').last);
      await tester.pumpAndSettle();

      expect(session.wire.writes, isEmpty);
    });
  });
}

Future<void> _openEditor(WidgetTester tester, String id) async {
  await tester.tap(find.text(id));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('notification-target-save')));
  await tester.tap(find.byKey(const Key('notification-target-save')));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _target({
  List<String> events = const ['chat.finished'],
  bool isDefault = true,
}) => {
  'id': 'ops',
  'type': 'webhook',
  'is_default': isDefault,
  'enabled': true,
  'events': events,
  'delivery': 'away',
  'config': {'url_masked': 'https://hooks.example.com/...cret'},
};

/// The Notifications page for a signed-in account whose server speaks through
/// [wire], on the real ApiService and auth interceptor.
final class _Session {
  _Session(this.wire, this.container);

  final _Wire wire;
  final ProviderContainer container;
  Object epoch = Object();
  String token = 'token-a';

  /// Another user signing in on the same server: same [ApiService], new auth
  /// session.
  void switchAccount() {
    epoch = Object();
    token = 'token-b';
    container
      ..invalidate(openWebUiAuthSessionEpochProvider)
      ..invalidate(authTokenProvider3);
  }
}

Future<_Session> _pump(
  WidgetTester tester, {
  AppSettings settings = _advanced,
  Map<String, dynamic> permissions = const {
    'features': {'webhooks': true},
  },
  bool serverEnabled = true,
  List<Map<String, dynamic>>? targets,
}) async {
  // Tall enough that the whole page is built, not only what a phone shows.
  tester.view
    ..physicalSize = const Size(800, 2600)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final wire = _Wire(targets ?? [_target()]);
  final api = ApiService(
    serverConfig: _server,
    workerManager: WorkerManager(),
    authToken: 'token-a',
  );
  api.dio.httpClientAdapter = wire;
  addTearDown(api.dispose);

  late final _Session session;
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(() => _Settings(settings)),
      apiServiceProvider.overrideWithValue(api),
      optimizedStorageServiceProvider.overrideWithValue(_Storage()),
      currentUserProvider2.overrideWithValue(
        const User(
          id: 'user-1',
          username: 'user',
          email: 'user@example.com',
          role: 'user',
        ),
      ),
      isAuthenticatedProvider2.overrideWithValue(true),
      authTokenProvider3.overrideWith((ref) => session.token),
      openWebUiAuthSessionEpochProvider.overrideWith((ref) => session.epoch),
      backendConfigProvider.overrideWith(
        () => _Config(
          BackendConfig(
            serverId: _server.id,
            enableUserWebhooks: serverEnabled,
          ),
        ),
      ),
      userPermissionsProvider.overrideWith((ref) async => permissions),
    ],
  );
  addTearDown(container.dispose);
  session = _Session(wire, container);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NotificationSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

final class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);

  final AppSettings _settings;

  @override
  AppSettings build() => _settings;
}

final class _Config extends BackendConfigNotifier {
  _Config(this._config);

  final BackendConfig _config;

  @override
  Future<BackendConfig?> build() async => _config;
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

/// What reaches the wire, answered like the Open WebUI notification routes.
final class _Wire implements HttpClientAdapter {
  _Wire(this.targets);

  final List<Map<String, dynamic>> targets;
  final requests = <RequestOptions>[];
  String? rejectWrites;

  Iterable<RequestOptions> get writes =>
      requests.where((r) => r.method != 'GET' && !r.uri.path.endsWith('/test'));

  int get tests => requests.where((r) => r.uri.path.endsWith('/test')).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    if (options.method != 'GET' && rejectWrites != null) {
      return _json({'detail': rejectWrites}, 400);
    }
    if (path.endsWith('/events')) {
      return _json({
        'events': [
          {'event': 'chat.finished', 'label': 'Chat finished'},
          {'event': 'channel.message', 'label': 'Channel message'},
        ],
      });
    }
    if (options.method == 'GET') return _json({'targets': targets});
    if (path.endsWith('/test') || options.method == 'DELETE') {
      return _json({'ok': true});
    }
    return _json(targets.first);
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
