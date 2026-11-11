import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/pages/webhook_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

final AppLocalizations _l10n = AppLocalizationsEn();

const _ops = '${webhookPagePrefix}ops';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('list', () {
    testWidgets('lists what the server holds without sending a test', (
      tester,
    ) async {
      final session = await _open(tester);

      final rows = session.rows(webhookListPageId);
      final ops = rows.singleWhere((row) => row.id == _ops);
      expect(ops.title, 'ops');
      expect(ops.subtitle, contains('https://hooks.example.com/...cret'));
      expect(ops.subtitle, contains('Default'));
      expect(rows.map((row) => row.id), contains(webhookNewPageId));

      await session.openPage(_ops);

      expect(session.wire.writes, isEmpty);
      expect(session.wire.tests, 0);
    });

    testWidgets('a list that failed to load offers Retry', (tester) async {
      final session = await _open(tester, failLists: true);

      expect(
        session.rows(webhookListPageId).map((row) => row.title),
        contains(_l10n.notificationTargetsLoadFailed),
      );

      session.wire.failLists = false;
      await session.change(webhookRetryId, true);
      // Retry reads again away from the row queue.
      await session.until(
        () => session.rows(webhookListPageId).any((row) => row.id == _ops),
      );
    });
  });

  group('a destination page', () {
    testWidgets('labels events from the catalog and hides one the server no '
        'longer lists', (tester) async {
      // Open WebUI 0.13 dropped the file processing alert; the server refuses
      // any event outside the catalog it lists.
      final session = await _open(
        tester,
        targets: [
          _target(
            events: const ['chat.finished', 'retrieval.content.process_failed'],
          ),
        ],
      );
      await session.openPage(_ops);

      final titles = session.rows(_ops).map((row) => row.title);
      expect(titles, containsAll(['Chat finished', 'Channel message']));
      // A form: Done saves it, and leaving with changes asks first.
      final page = session.container.read(settingsPagesProvider)[_ops]!;
      expect(page.confirmActionId, webhookRowId('save', _ops));
      expect(page.discardPrompt, isNotNull);
      expect(titles, isNot(contains('retrieval.content.process_failed')));
    });

    testWidgets(
      'without the catalog, the events a destination holds are shown and '
      'kept',
      (tester) async {
        final session = await _open(
          tester,
          targets: [
            _target(events: const ['chat.finished', 'future.event']),
          ],
          failCatalog: true,
        );
        await session.openPage(_ops);

        final unknown = session
            .rows(_ops)
            .singleWhere((row) => row.title == 'future.event');
        expect(unknown.subtitle, _l10n.notificationTargetUnknownEvent);

        await session.change(webhookRowId('delivery', _ops), 'always');
        await session.change(webhookRowId('save', _ops), true);

        expect(session.wire.writes.single.data, {'delivery': 'always'});
      },
    );

    testWidgets('any save drops an event the server no longer lists', (
      tester,
    ) async {
      // The server checks the stored events on every update, so a delivery
      // change alone would be refused while the retired event stays.
      final session = await _open(
        tester,
        targets: [
          _target(
            events: const ['chat.finished', 'retrieval.content.process_failed'],
          ),
        ],
      );
      await session.openPage(_ops);

      await session.change(webhookRowId('delivery', _ops), 'always');
      await session.change(webhookRowId('save', _ops), true);

      expect(session.wire.writes.single.data, {
        'events': ['chat.finished'],
        'delivery': 'always',
      });
    });

    testWidgets('a change to delivery sends only delivery, never the URL', (
      tester,
    ) async {
      final session = await _open(tester);
      await session.openPage(_ops);

      await session.change(webhookRowId('delivery', _ops), 'always');
      await session.change(webhookRowId('save', _ops), true);

      final put = session.wire.writes.single;
      expect(put.method, 'PUT');
      expect(put.path, '/api/v1/notifications/targets/ops');
      expect(put.data, {'delivery': 'always'});
    });

    testWidgets('an event change sends the whole selection the server keeps', (
      tester,
    ) async {
      final session = await _open(tester);
      await session.openPage(_ops);

      await session.change(webhookRowId('event.channel.message', _ops), true);
      await session.change(webhookRowId('save', _ops), true);

      final events = (session.wire.writes.single.data as Map)['events'] as List;
      expect(events, ['chat.finished', 'channel.message']);
    });

    testWidgets('a typed URL is the only way config is sent', (tester) async {
      final session = await _open(tester);
      await session.openPage(_ops);

      await session.change(webhookRowId('url', _ops), ' https://new.example ');
      await session.change(webhookRowId('save', _ops), true);

      expect(session.wire.writes.single.data, {
        'config': {'url': 'https://new.example'},
      });
    });

    testWidgets(
      'a refused save keeps the draft and shows the server\'s reason',
      (tester) async {
        final session = await _open(tester);
        await session.openPage(_ops);
        session.wire.rejectWrites = 'Invalid URL';

        await session.change(webhookRowId('url', _ops), 'nope');
        await session.change(webhookRowId('save', _ops), true);

        final rows = session.rows(_ops);
        expect(rows.first.title, 'Invalid URL');
        expect(
          rows.singleWhere((row) => row.id == webhookRowId('url', _ops)).value,
          'nope',
        );

        session.wire.rejectWrites = null;
        await session.change(webhookRowId('save', _ops), true);
        expect(session.wire.writes.last.data, {
          'config': {'url': 'nope'},
        });
        // Saved, the page is closed and the list read again.
        expect(session.closed, [_ops]);
      },
    );

    testWidgets('a second Done after the page closed sends nothing more', (
      tester,
    ) async {
      final session = await _open(tester);
      await session.openPage(_ops);

      await session.change(webhookRowId('delivery', _ops), 'always');
      await session.change(webhookRowId('save', _ops), true);
      await session.change(webhookRowId('save', _ops), true);

      expect(session.wire.writes, hasLength(1));
    });
  });

  group('a new destination', () {
    testWidgets('needs a URL, then sends the form', (tester) async {
      final session = await _open(tester);
      await session.openPage(webhookNewPageId);

      await session.change(webhookRowId('save', webhookNewPageId), true);
      expect(
        session.rows(webhookNewPageId).first.title,
        _l10n.notificationTargetUrlRequired,
      );
      expect(session.wire.writes, isEmpty);

      await session.change(
        webhookRowId('url', webhookNewPageId),
        'https://hooks.example.com/new',
      );
      await session.change(webhookRowId('name', webhookNewPageId), 'team');
      await session.change(webhookRowId('save', webhookNewPageId), true);

      expect(session.wire.writes.single.method, 'POST');
      expect(session.wire.writes.single.data, {
        'type': 'webhook',
        'id': 'team',
        'enabled': true,
        'events': <String>[],
        'delivery': 'away',
        'config': {'url': 'https://hooks.example.com/new'},
      });
    });
  });

  group('actions', () {
    testWidgets('Test calls the test endpoint once, and says it was sent', (
      tester,
    ) async {
      final session = await _open(tester);
      await session.openPage(_ops);

      await session.change(webhookRowId('test', _ops), true);

      expect(session.wire.tests, 1);
      expect(session.rows(_ops).first.title, _l10n.notificationTargetTestSent);
    });

    testWidgets('a failed test says so with the server\'s reason', (
      tester,
    ) async {
      final session = await _open(tester);
      await session.openPage(_ops);
      session.wire.rejectWrites = 'Webhook delivery failed';

      await session.change(webhookRowId('test', _ops), true);

      expect(session.rows(_ops).first.title, 'Webhook delivery failed');
    });

    testWidgets('Test and Make default wait until the changes are saved', (
      tester,
    ) async {
      final session = await _open(tester, targets: [_target(isDefault: false)]);
      await session.openPage(_ops);
      await session.change(webhookRowId('delivery', _ops), 'always');

      await session.change(webhookRowId('test', _ops), true);
      expect(
        session.rows(_ops).first.title,
        _l10n.notificationTargetTestNeedsSave,
      );
      await session.change(webhookRowId('default', _ops), true);
      expect(
        session.rows(_ops).first.title,
        _l10n.notificationTargetMakeDefaultNeedsSave,
      );

      expect(session.wire.tests, 0);
      expect(session.wire.writes, isEmpty);
    });

    testWidgets('Make default sends the default call', (tester) async {
      final session = await _open(tester, targets: [_target(isDefault: false)]);
      await session.openPage(_ops);

      await session.change(webhookRowId('default', _ops), true);

      expect(session.wire.writes.single.method, 'PUT');
      expect(
        session.wire.writes.single.path,
        '/api/v1/notifications/targets/ops/default',
      );
    });

    testWidgets('Delete asks first, then deletes', (tester) async {
      final session = await _open(tester);
      await session.openPage(_ops);

      final delete = session
          .rows(_ops)
          .singleWhere((row) => row.id == webhookRowId('delete', _ops));
      expect(
        delete.confirmMessage,
        _l10n.notificationTargetDeleteConfirm('ops'),
      );

      await session.change(webhookRowId('delete', _ops), true);

      expect(session.wire.writes.single.method, 'DELETE');
    });
  });

  group('account switch', () {
    testWidgets(
      'saves, tests, defaults and deletes nothing for the account that '
      'signs in next',
      (tester) async {
        final session = await _open(
          tester,
          targets: [_target(isDefault: false)],
        );
        await session.openPage(_ops);
        await session.change(webhookRowId('url', _ops), 'https://new.example');

        session.switchAccount();
        await session.change(webhookRowId('save', _ops), true);
        await session.change(webhookRowId('test', _ops), true);
        await session.change(webhookRowId('default', _ops), true);
        await session.change(webhookRowId('delete', _ops), true);

        expect(session.wire.writes, isEmpty);
        expect(session.wire.tests, 0);
        expect(
          session.rows(_ops).first.title,
          _l10n.notificationTargetsAccountChanged,
        );
      },
    );
  });
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

/// The webhook pages of a signed-in account whose server speaks through
/// [wire], on the real ApiService and auth interceptor.
final class _Session {
  _Session(this.tester, this.wire, this.container);

  final WidgetTester tester;
  final _Wire wire;
  final ProviderContainer container;
  Object epoch = Object();
  String token = 'token-a';

  SettingsPageModule get module => container
      .read(settingsPageModulesProvider)
      .whereType<WebhookSettingsPages>()
      .single;

  /// Pages asked to close, in order.
  List<String> get closed => [
    for (final MapEntry(:key, :value)
        in container.read(settingsPagesProvider).closeRequests.entries)
      for (var i = 0; i < value; i++) key,
  ];

  List<NativeSheetItemConfig> rows(String pageId) {
    final page = container.read(settingsPagesProvider)[pageId]!;
    return [...page.items, for (final s in page.sections) ...s.items];
  }

  Future<void> openPage(String pageId) =>
      _settle(module.hydrate(pageId, _l10n));

  Future<void> change(String id, Object? value) =>
      _settle(module.handleChange(id, value, _l10n));

  /// Moves the test clock until [done], as work the module started without
  /// waiting for it finishes.
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 500 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  /// Waits for [work] while the test clock moves, so the requests it makes
  /// through the API's timers come back.
  Future<void> _settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    while (!done) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
  }

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

/// Opens the list, as the Notifications page's row does.
Future<_Session> _open(
  WidgetTester tester, {
  List<Map<String, dynamic>>? targets,
  bool failLists = false,
  bool failCatalog = false,
}) async {
  final wire = _Wire(targets ?? [_target()])
    ..failLists = failLists
    ..failCatalog = failCatalog;
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
      appSettingsProvider.overrideWith(
        () => _Settings(const AppSettings(advancedFeaturesEnabled: true)),
      ),
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
          BackendConfig(serverId: _server.id, enableUserWebhooks: true),
        ),
      ),
      userPermissionsProvider.overrideWith(
        (ref) async => const {
          'features': {'webhooks': true},
        },
      ),
    ],
  );
  addTearDown(container.dispose);
  session = _Session(tester, wire, container);
  container.read(settingsPagesProvider.notifier).register([
    buildNativeLoadingPage(webhookListPageId),
  ]);
  await session.openPage(webhookListPageId);
  return session;
}

/// A page as the page that leads to it registers it.
NativeSheetDetailConfig buildNativeLoadingPage(String id) =>
    NativeSheetDetailConfig(id: id, title: '');

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
  bool failLists = false;
  bool failCatalog = false;

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
      if (failCatalog) return _json({'detail': 'unavailable'}, 500);
      return _json({
        'events': [
          {'event': 'chat.finished', 'label': 'Chat finished'},
          {'event': 'channel.message', 'label': 'Channel message'},
        ],
      });
    }
    if (options.method == 'GET') {
      if (failLists) return _json({'detail': 'unavailable'}, 500);
      return _json({'targets': targets});
    }
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
