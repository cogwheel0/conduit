@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/mcp_apps_service.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// `mcpApps.*` without an Open WebUI account: what is refused, and what
/// answers that nothing was there. Running an app against a server is
/// the desktop's `--e2e rendering` pass.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late McpAppsService apps;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('mcp-apps-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    apps = McpAppsService(runtime.container, EventBus());
  });

  tearDownAll(() async {
    apps.dispose();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('an app needs an Open WebUI account to open', () async {
    await expectLater(
      apps.open(
        const McpAppOpen(
          chatId: 'chat-1',
          app: McpAppDto(
            serverId: 'harbour',
            toolName: 'show_tides',
            binding: 'b',
          ),
        ),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.unauthenticated,
        ),
      ),
    );
  });

  test('messages, context and close for no app answer that none ran', () async {
    expect(
      (await apps.message(const McpAppMessage(appId: 'gone', payload: '{}')))
          .ok,
      isFalse,
    );
    expect(
      apps.context(const McpAppContext(appId: 'gone', theme: 'dark')).ok,
      isFalse,
    );
    expect(apps.close(const McpAppRef(appId: 'gone')).ok, isFalse);
  });

  group('with an account', () {
    late _Api api;
    late Object epoch;
    late ProviderContainer container;
    late EventBus events;
    late UiRequestsService ui;
    late McpAppsService apps;
    late List<EventEnvelope> seen;

    setUp(() {
      api = _Api();
      epoch = Object();
      container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWith((ref) => api),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        ],
      );
      events = EventBus();
      seen = <EventEnvelope>[];
      events
        ..attach('window', seen.add)
        ..subscribe(
          'window',
          const EventSubscription(
            events: <String>[
              ConduitEvents.mcpAppsEvent,
              ConduitEvents.openUrl,
              ConduitEvents.uiRequest,
              ConduitEvents.uiSettled,
            ],
            scopes: <String>['chat-1'],
          ),
        );
      ui = UiRequestsService(events);
      apps = McpAppsService(container, events, uiRequests: ui);
    });
    tearDown(() {
      apps.dispose();
      container.dispose();
      api.dispose();
    });

    const open = McpAppOpen(
      chatId: 'chat-1',
      app: McpAppDto(serverId: 'harbour', toolName: 'show_tides', binding: 'b'),
    );

    Future<String> started() async {
      final session = await apps.open(open);
      await apps.message(
        McpAppMessage(
          appId: session.appId,
          payload: jsonEncode(<String, Object>{
            'jsonrpc': '2.0',
            'method': 'ui/notifications/initialized',
          }),
        ),
      );
      return session.appId;
    }

    test("an app read under one account is never run under the next", () async {
      final page = Completer<Map<String, dynamic>>();
      api.page = () => page.future;
      final opening = apps.open(open);
      // Another account signs in while the page is read.
      api = _Api();
      epoch = Object();
      container
        ..invalidate(apiServiceProvider)
        ..invalidate(openWebUiAuthSessionEpochProvider);
      container.read(apiServiceProvider);
      page.complete(_page);
      await expectLater(
        opening,
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );
    });

    test('a link allowed after its app closed is not opened', () async {
      final appId = await started();
      final asking = apps.message(
        McpAppMessage(
          appId: appId,
          payload: jsonEncode(<String, Object>{
            'jsonrpc': '2.0',
            'id': 7,
            'method': 'ui/open-link',
            'params': <String, String>{'url': 'https://example.org/tides'},
          }),
        ),
      );
      final question = ui.pending.single;
      apps.close(McpAppRef(appId: appId));
      ui.respond(UiResponse(requestId: question.requestId, choice: 'allow'));
      await asking;
      expect(seen.where((e) => e.event == ConduitEvents.openUrl), isEmpty);
    });

    test('closing an app takes back the link question it asked', () async {
      final appId = await started();
      final asking = apps.message(
        McpAppMessage(
          appId: appId,
          payload: jsonEncode(<String, Object>{
            'jsonrpc': '2.0',
            'id': 8,
            'method': 'ui/open-link',
            'params': <String, String>{'url': 'https://example.org/tides'},
          }),
        ),
      );
      final question = ui.pending.single;
      apps.close(McpAppRef(appId: appId));
      await asking;
      expect(ui.pending, isEmpty, reason: 'the card stayed up');
      expect(
        seen.where(
          (e) =>
              e.event == ConduitEvents.uiSettled &&
              UiSettled.fromJson(e.payload).requestId == question.requestId,
        ),
        hasLength(1),
      );
      expect(seen.where((e) => e.event == ConduitEvents.openUrl), isEmpty);
    });

    test('closing an app takes back its tool call question', () async {
      final appId = await started();
      final asking = apps.message(
        McpAppMessage(
          appId: appId,
          payload: jsonEncode(<String, Object>{
            'jsonrpc': '2.0',
            'id': 9,
            'method': 'tools/call',
            'params': <String, Object>{
              'name': 'show_tides',
              'arguments': <String, String>{'harbour': 'North'},
            },
          }),
        ),
      );
      final question = ui.pending.single;
      apps.close(McpAppRef(appId: appId));
      await asking;
      expect(ui.pending, isEmpty, reason: 'the card stayed up');
      expect(
        seen.where(
          (e) =>
              e.event == ConduitEvents.uiSettled &&
              UiSettled.fromJson(e.payload).requestId == question.requestId,
        ),
        hasLength(1),
      );
    });

    test('a new sign-in on the same server closes the apps', () async {
      final appId = await started();
      // The same client, a new session: the old one's apps are not its.
      epoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      container.read(openWebUiAuthSessionEpochProvider);
      expect(
        apps.context(McpAppContext(appId: appId, theme: 'dark')).ok,
        isFalse,
      );
    });

    test('a closed app hears that it is going', () async {
      final appId = await started();
      seen.clear();
      apps.close(McpAppRef(appId: appId));
      final delivered = <String>[
        for (final e in seen)
          if (e.event == ConduitEvents.mcpAppsEvent)
            McpAppEvent.fromJson(e.payload).message ?? '',
      ];
      expect(delivered.where((m) => m.contains('ui/resource-teardown')), hasLength(1));
    });
  });
}

const _server = ServerConfig(
  id: 'server',
  name: 'Home server',
  url: 'https://home.invalid',
);

const _page = <String, dynamic>{
  'html': '<p>Tides</p>',
  'csp': "default-src 'none'",
};

/// The account's server, answering the app's page from memory.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager());

  Future<Map<String, dynamic>> Function() page = () async => _page;

  @override
  Future<Map<String, dynamic>> runMcpAppRequest(
    OpenWebUiMcpApp app, {
    required String method,
    Map<String, dynamic> params = const <String, dynamic>{},
    CancelToken? cancelToken,
  }) => method == 'ui/resource' ? page() : Future.value(<String, dynamic>{});
}
