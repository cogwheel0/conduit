import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/hermes/widgets/hermes_configuration_actions.dart';
import 'package:conduit/features/hermes/widgets/hermes_visual_model_selector.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart'
    show AdaptiveSwitch, CompactModelSelector;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/reasoning_effort_provider.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:checks/checks.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_visual_model_store.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// Minimal gateway stub: answers `session.create` WITHOUT a `running` field,
/// which is what a real Hermes 0.20.x gateway does, then lets the test push
/// `session.info` frames by hand.
final class _GatewayHarness {
  _GatewayHarness() {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      // The client subscribes inside connect(); announce readiness right after
      // so the handshake completes without the test guessing at timing.
      scheduleMicrotask(ready);
      return incoming.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      sent.add(frame);
      final id = frame['id'];
      if (id == null) return;
      final method = frame['method']?.toString() ?? '';
      final error = errorResponder(method);
      if (error != null) {
        scheduleMicrotask(
          () => incoming.add(
            jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': error}),
          ),
        );
        return;
      }
      final result = responder(method);
      if (result == null) return;
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        ),
      );
    });
  }

  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];

  Map<String, dynamic>? Function(String method) responder = (_) => null;

  /// When non-null for a method, the gateway answers with a JSON-RPC error
  /// instead of a result.
  Map<String, dynamic>? Function(String method) errorResponder = (_) => null;

  void ready() {
    if (incoming.isClosed) return;
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': {}},
      }),
    );
  }

  /// Pushes the `session.info` the gateway emits when a turn settles.
  void sessionInfo(String runtimeId, {required bool running}) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': 'session.info',
        'session_id': runtimeId,
        'payload': {'running': running},
      },
    }),
  );

  /// Pushes a turn event for [runtimeId], e.g. `message.start`.
  void event(
    String runtimeId,
    String type, [
    Map<String, dynamic> payload = const {},
  ]) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': type, 'session_id': runtimeId, 'payload': payload},
    }),
  );

  Future<void> dispose() => incoming.close();
}

Dio _statusDio([_StubAdapter? adapter]) {
  final dio = Dio();
  dio.httpClientAdapter = adapter ?? _StubAdapter();
  return dio;
}

/// Serves `/api/status` (auth not required) so `_connect` can reach the socket,
/// and records every REST URI so tests can assert profile scoping.
final class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({
    this.messages = const <Map<String, dynamic>>[],
    this.agentConfig,
    this.modelSummary,
  });

  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic>? agentConfig, modelSummary;
  final requested = <Uri>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    final settings = switch (options.uri.path) {
      '/api/config' => agentConfig == null ? null : {'config': agentConfig},
      '/api/model/info' => modelSummary,
      _ => null,
    };
    if (settings != null) {
      return ResponseBody.fromString(
        jsonEncode(settings),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.uri.path.endsWith('/read-data-url')) {
      return ResponseBody.fromString(
        jsonEncode({'dataUrl': 'data:text/plain;base64,SGVsbG8='}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.uri.path.endsWith('/messages')) {
      return ResponseBody.fromString(
        jsonEncode({'messages': messages}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    final body = jsonEncode({
      'version': '0.20.1',
      'auth_required': false,
      'gateway_running': true,
    });
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Serves `/api/status` like [_StubAdapter] but fails the transcript request.
final class _PagedTitleAdapter extends _StubAdapter {
  _PagedTitleAdapter(this.history);
  final List<Map<String, dynamic>> history;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.uri.path.endsWith('/messages')) {
      return super.fetch(options, requestStream, cancelFuture);
    }
    requested.add(options.uri);
    final offset = int.parse(options.uri.queryParameters['offset'] ?? '0');
    final limit = int.parse(options.uri.queryParameters['limit'] ?? '40');
    return ResponseBody.fromString(
      jsonEncode({'messages': history.skip(offset).take(limit).toList()}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

final class _FailingMessagesAdapter extends _StubAdapter {
  _FailingMessagesAdapter({required this.status});

  final int status;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.endsWith('/messages')) {
      requested.add(options.uri);
      return ResponseBody.fromString(
        jsonEncode({'error': 'session_not_found'}),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}

void main() {
  test('Auto rename suggestion uses a bounded one-shot without opening or posting to a chat', () async {
    final harness = _GatewayHarness();
    harness.responder = (method) => method == 'llm.oneshot'
        ? {'text': '"Website Navigation Redesign"'}
        : {};
    final adapter = _StubAdapter(
      messages: const [
        {'role': 'assistant', 'content': 'Use a compact navigation bar.'},
        {'role': 'tool', 'content': 'Do not include private tool output'},
        {'role': 'user', 'content': 'Help me redesign the website navigation.'},
      ],
    );
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(adapter),
      rpc: HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      ),
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });
    final title = await service.suggestSessionTitle('stored-review');
    expect(title, 'Website Navigation Redesign');
    final call = harness.sent.singleWhere((f) => f['method'] == 'llm.oneshot');
    final params = call['params'] as Map;
    expect(params['input'], contains('redesign the website navigation'));
    expect(params['input'], isNot(contains('private tool output')));
    expect(params['session_id'], isNull);
    expect(
      harness.sent.where(
        (f) => {
          'session.create',
          'session.resume',
          'prompt.submit',
          'slash.exec',
          'session.title',
        }.contains(f['method']),
      ),
      isEmpty,
    );
    final transcript = adapter.requested.singleWhere(
      (uri) => uri.path.endsWith('/messages'),
    );
    expect(transcript.queryParameters['limit'], '200');
    expect(transcript.queryParameters['order'], 'oldest');
  });

  test('Auto rename includes opening and recent context across stored history pages', () async {
    final harness = _GatewayHarness();
    harness.responder = (method) => method == 'llm.oneshot'
        ? {'text': 'Accessible Website Navigation'}
        : {};
    final history = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': 'Opening topic: redesign the company website.',
      },
      for (var i = 1; i < 249; i++)
        {
          'role': i.isEven ? 'user' : 'assistant',
          'content': 'Design discussion $i. ${'x' * 1700}',
        },
      {
        'role': 'user',
        'content':
            'Latest decision: accessible navigation and keyboard controls.',
      },
    ];
    final adapter = _PagedTitleAdapter(history);
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(adapter),
      rpc: HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      ),
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });
    await service.suggestSessionTitle('long-review');
    final params =
        harness.sent.singleWhere(
              (frame) => frame['method'] == 'llm.oneshot',
            )['params']
            as Map;
    expect(params['input'], contains('Opening topic'));
    expect(params['input'], contains('Latest decision'));
    expect((params['input'] as String).length, lessThanOrEqualTo(12000));
    expect(
      adapter.requested.where((uri) => uri.path.endsWith('/messages')).length,
      2,
    );
    expect(
      harness.sent.where(
        (frame) => {
          'session.resume',
          'prompt.submit',
          'slash.exec',
          'session.title',
        }.contains(frame['method']),
      ),
      isEmpty,
    );
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(PreferencesStore.debugReset);
  testWidgets(
    'Bare reasoning opens once, shows current settings and changes display separately',
    (tester) async {
      final fixture = await _pumpConfiguration(
        tester,
        'reasoning',
        autoOpen: true,
      );
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.text('Choose reasoning effort'), findsOneWidget);
      expect(find.text('Current reasoning: medium'), findsOneWidget);
      expect(find.text('Show reasoning'), findsOneWidget);
      expect(
        fixture.harness.sent.where((frame) => frame['method'] == 'config.set'),
        isEmpty,
      );
      await tester.tap(find.byType(AdaptiveSwitch));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      final write = fixture.harness.sent.singleWhere(
        (frame) => frame['method'] == 'config.set',
      );
      expect((write['params'] as Map)['key'], 'reasoning');
      expect((write['params'] as Map)['value'], 'show');
      expect((write['params'] as Map)['scope'], 'session');
      expect(
        fixture.container
            .read(chatMessagesProvider)
            .single
            .metadata?['hermesReasoningDisplay'],
        isTrue,
      );
      expect(find.text('Choose reasoning effort'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      fixture.container
          .read(hermesMobileNavigationProvider.notifier)
          .showConversation();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Choose reasoning effort'), findsNothing);
      expect(find.text('Change Reasoning'), findsOneWidget);
    },
  );

  testWidgets(
    'Reasoning picker hides effort choices for models with no controls',
    (tester) async {
      final fixture = await _pumpConfiguration(
        tester,
        'reasoning',
        reasoningAvailable: false,
      );
      await tester.tap(find.text('Change Reasoning'));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(
        find.text('This model does not support reasoning controls.'),
        findsOneWidget,
      );
      expect(find.text('High'), findsNothing);
      expect(
        fixture.harness.sent.where((frame) => frame['method'] == 'config.set'),
        isEmpty,
      );
    },
  );

  test('Mandatory reasoning excludes the Off choice', () {
    const settings = HermesSessionReasoningSettings(
      reasoningAvailable: true,
      canDisableReasoning: false,
    );
    expect(settings.levels, isNot(contains('none')));
    expect(settings.levels, contains('high'));
  });
  testWidgets(
    'Model control picks provider then model and confirms expensive choices',
    (tester) async {
      final fixture = await _pumpConfiguration(tester, 'model');
      await tester.tap(find.text('Change Model'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Choose a provider'), findsOneWidget);
      await tester.tap(find.text('configured'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Model A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Confirm this model'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        fixture.harness.sent.where((f) => f['method'] == 'config.set'),
        hasLength(1),
      );
      expect(
        fixture.container
            .read(selectedModelProvider)
            ?.metadata?['hermesConfiguredDefault'],
        isTrue,
      );
      await tester.tap(find.text('Change Model'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('configured'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Model A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      final setters = fixture.harness.sent
          .where((f) => f['method'] == 'config.set')
          .toList();
      expect(setters, hasLength(3));
      expect(
        (setters.last['params'] as Map)['confirm_expensive_model'],
        isTrue,
      );
      expect(
        fixture.container
            .read(selectedModelProvider)
            ?.metadata?['hermesModelId'],
        'model-a',
      );
    },
  );

  testWidgets(
    'Reasoning pick applies to the session and persists for the next turn',
    (tester) async {
      final fixture = await _pumpConfiguration(tester, 'reasoning');
      await tester.tap(find.text('Change Reasoning'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Choose reasoning effort'), findsOneWidget);
      await tester.tap(find.text('High'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      final params =
          fixture.harness.sent.singleWhere(
                (f) => f['method'] == 'config.set',
              )['params']
              as Map;
      expect(params['session_id'], 'runtime-picker');
      expect(params['key'], 'reasoning');
      expect(params['value'], 'high');
      expect(params['scope'], 'session');
      expect(fixture.container.read(configuredReasoningEffortProvider), 'high');
    },
  );

  testWidgets(
    'Switching chats while picking a provider prevents the stale mutation',
    (tester) async {
      final fixture = await _pumpConfiguration(tester, 'model');
      await tester.tap(find.text('Change Model'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      fixture.container.read(activeConversationProvider.notifier).clear();
      await tester.tap(find.text('configured'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        fixture.harness.sent.where((f) => f['method'] == 'config.set'),
        isEmpty,
      );
      expect(find.text('Choose a model'), findsNothing);
    },
  );

  test('Bare configuration commands offer native controls without submitting an agent prompt', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    final harness = _GatewayHarness();
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(),
      rpc: HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      ),
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });
    harness.responder = (method) => switch (method) {
      'session.resume' => {
        'session_id': 'runtime-1',
        'stored_session_id': 'stored-1',
        'running': false,
        'info': {'running': false},
      },
      'slash.exec' => {'output': 'Current setting'},
      _ => {},
    };
    for (final command in ['model', 'reasoning']) {
      final response = await service.streamDesktopResponse(
        HermesChatInput.text('/$command'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(reasoningEffort: 'medium'),
      );
      final events = await response.events.toList();
      expect(
        events.whereType<HermesConfigurationRequested>().single.command,
        command,
      );
      expect(
        events.whereType<HermesFinalOutput>().single.text,
        'Current setting',
      );
    }
    expect(
      harness.sent.where(
        (frame) =>
            const {'prompt.submit', 'config.set'}.contains(frame['method']),
      ),
      isEmpty,
    );
  });

  testWidgets(
    'chat selector loads without configuration writes and disappears for an untrusted owner',
    (tester) async {
      final fixture = await _pumpConfiguration(tester, 'model');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: HermesChatModelSelector(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Model A · Medium'), findsOneWidget);
      await tester.tap(find.text('Model A · Medium'));
      await tester.pumpAndSettle();
      expect(find.byType(CompactModelSelector), findsOneWidget);
      expect(
        fixture.harness.sent.where((f) => f['method'] == 'config.set'),
        isEmpty,
      );
      final active = fixture.container.read(activeConversationProvider)!;
      fixture.container
          .read(activeConversationProvider.notifier)
          .set(
            inheritNativeHermesConversationProvenance(
              active,
              active.copyWith(
                metadata: {
                  ...active.metadata,
                  kHermesConnectionIdentityMetadataKey: 'different-owner',
                },
              ),
            ),
          );
      await tester.pumpAndSettle();
      expect(find.byType(CompactModelSelector), findsNothing);
      expect(
        fixture.harness.sent.where((f) => f['method'] == 'config.set'),
        isEmpty,
      );
    },
  );

  for (final raw in <Object>[
    'model-a',
    {'model': 'model-a'},
    <String, dynamic>{},
  ]) {
    testWidgets(
      'draft model selector resolves legacy config $raw and the provider summary',
      (tester) async {
        final fixture = await _pumpConfiguration(
          tester,
          'model',
          adapter: _StubAdapter(
            agentConfig: {
              'model': raw,
              'agent': {'reasoning_effort': 'medium'},
            },
            modelSummary: {'model': 'model-a', 'provider': 'configured'},
          ),
        );
        fixture.container.read(activeConversationProvider.notifier).set(null);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: const MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomLeft,
                  child: HermesChatModelSelector(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Model A · Medium'));
        await tester.pumpAndSettle();
        final control = tester.widget<CompactModelSelector>(
          find.byType(CompactModelSelector),
        );
        expect(control.model, 'Model A');
        expect(control.provider, 'Configured');
        expect(control.effort, 'medium');
        expect(
          fixture.harness.sent.where((f) => f['method'] == 'config.set'),
          isEmpty,
        );
      },
    );
  }

  test('visual model mode survives reload and cannot cross connection or session boundaries', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    await HermesVisualModelStore.write(
      'fixture-owner-a',
      'fixture-session-a',
      const HermesDesktopSessionOptions(followGlobal: true),
    );
    expect(
      HermesVisualModelStore.read('fixture-owner-b', 'fixture-session-a'),
      isNull,
    );
    expect(
      HermesVisualModelStore.read('fixture-owner-a', 'fixture-session-b'),
      isNull,
    );
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    expect(
      HermesVisualModelStore.read(
        'fixture-owner-a',
        'fixture-session-a',
      )?.followGlobal,
      isTrue,
    );
    await HermesVisualModelStore.write(
      'fixture-owner-a',
      'fixture-session-a',
      const HermesDesktopSessionOptions(preserveSession: true),
    );
    final current = HermesVisualModelStore.read(
      'fixture-owner-a',
      'fixture-session-a',
    );
    expect(current?.followGlobal, isFalse);
    expect(current?.preserveSession, isTrue);
  });

  test('visual selector reads supported effort levels and keeps global reset scoped to the owning bot', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    final harness = _GatewayHarness();
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopProfile: 'default',
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'fixture-token',
        ),
      ),
      dio: _statusDio(),
      rpc: HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      ),
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });
    var globalModel = 'model-a', globalEffort = 'high';
    harness.responder = (method) {
      final params = harness.sent.last['params'] as Map? ?? {};
      return switch (method) {
        'session.resume' => {
          'session_id': 'runtime-bot',
          'stored_session_id': 'stored-bot',
          'running': false,
          'info': {'running': false},
        },
        'model.options' => {
          'model': globalModel,
          'provider': 'configured',
          'providers': [
            {
              'slug': 'configured',
              'models': [globalModel],
              'capabilities': {
                globalModel: {
                  'reasoning': true,
                  'fast': true,
                  'supported_efforts': ['low', 'medium', 'high'],
                  'can_disable_reasoning': false,
                },
              },
            },
          ],
        },
        'config.get' =>
          params['key'] == 'full'
              ? {
                  'config': {
                    'agent': {'service_tier': 'auto'},
                  },
                }
              : {
                  'value': params['key'] == 'fast' ? 'fast' : globalEffort,
                  'display': 'hide',
                },
        'config.set' => {'value': params['value']},
        _ => {},
      };
    };
    await service.openBotChat(
      const HermesBot(
        name: 'researcher',
        title: 'Research',
        chatSessionId: 'stored-bot',
      ),
    );
    final settings = await service.sessionReasoningSettings('stored-bot');
    expect(settings.levels, ['low', 'medium', 'high']);
    expect(settings.supportsFast, isTrue);
    expect(settings.fast, isTrue);
    expect(settings.provider, 'configured');
    await service.configureSession('stored-bot', fast: false);
    final fastWrite = harness.sent.last['params'] as Map;
    expect(fastWrite['key'], 'fast');
    expect(fastWrite['value'], 'normal');
    expect(fastWrite['scope'], 'session');
    await service.applyGlobalSessionOptions('stored-bot');
    globalModel = 'model-b';
    globalEffort = 'low';
    await service.applyGlobalSessionOptions('stored-bot');
    final setters = harness.sent
        .where((f) => f['method'] == 'config.set')
        .map((f) => f['params'] as Map)
        .toList();
    expect(
      setters.any(
        (p) => p['value'] == 'model-b --provider configured --session',
      ),
      isTrue,
    );
    expect(
      setters.any((p) => p['key'] == 'reasoning' && p['value'] == 'low'),
      isTrue,
    );
    expect(
      setters.any((p) => p['key'] == 'fast' && p['value'] == 'auto'),
      isTrue,
    );
    for (final params in setters) {
      expect(params['session_id'], 'runtime-bot');
      expect(params['profile'], 'researcher');
      expect(params['scope'], 'session');
    }
    final globalReads = harness.sent
        .where(
          (f) =>
              f['method'] == 'config.get' &&
              (f['params'] as Map)['key'] == 'full',
        )
        .map((f) => f['params'] as Map);
    expect(globalReads, hasLength(2));
    for (final params in globalReads) {
      expect(params['session_id'], isNull);
      expect(params['profile'], 'researcher');
    }
  });

  test('Session picker reads and mutations keep runtime and bot profile scope, and expose confirmation', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    final harness = _GatewayHarness();
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopProfile: 'default',
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(),
      rpc: HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      ),
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });
    harness.responder = (method) => switch (method) {
      'session.resume' => {
        'session_id': 'runtime-bot',
        'stored_session_id': 'stored-bot',
        'running': false,
        'info': {'running': false},
      },
      'model.options' => {
        'providers': [
          {
            'slug': 'configured',
            'models': ['model-a'],
          },
          {
            'slug': 'unavailable',
            'authenticated': false,
            'models': ['model-b'],
          },
        ],
      },
      'config.get' => {'key': 'reasoning', 'value': 'medium'},
      'config.set' => {
        'confirm_required': true,
        'confirm_message': 'Confirm this model',
      },
      _ => {},
    };
    await service.openBotChat(
      const HermesBot(
        name: 'researcher',
        title: 'Research',
        chatSessionId: 'stored-bot',
      ),
    );
    final models = await service.sessionModelOptions('stored-bot');
    expect(models.map((option) => option.id), ['model-a']);
    expect(await service.sessionReasoning('stored-bot'), 'medium');
    final confirmation = await service.configureSession(
      'stored-bot',
      model: 'model-a',
      provider: 'configured',
    );
    expect(confirmation['confirm_required'], isTrue);
    var setters = harness.sent
        .where((frame) => frame['method'] == 'config.set')
        .toList();
    expect(
      (setters.single['params'] as Map)['confirm_expensive_model'],
      isNull,
    );
    await service.configureSession(
      'stored-bot',
      model: 'model-a',
      provider: 'configured',
      confirmExpensiveModel: true,
    );
    await service.configureSession('stored-bot', reasoning: 'high');
    setters = harness.sent
        .where((frame) => frame['method'] == 'config.set')
        .toList();
    expect((setters[1]['params'] as Map)['confirm_expensive_model'], isTrue);
    expect(
      (setters[0]['params'] as Map)['value'],
      'model-a --provider configured --session',
    );
    expect((setters[2]['params'] as Map)['value'], 'high');
    for (final frame in harness.sent.where(
      (frame) => const {
        'model.options',
        'config.get',
        'config.set',
      }.contains(frame['method']),
    )) {
      final params = frame['params'] as Map;
      expect(params['profile'], 'researcher');
      expect(params['session_id'], 'runtime-bot');
      if (frame['method'] == 'config.set') expect(params['scope'], 'session');
    }
  });

  test(
    'session.info clears an unsupportedGateway state keyed by stored id',
    () async {
      final harness = _GatewayHarness();
      final rpc = HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      );
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'session-token',
          ),
        ),
        dio: _statusDio(),
        rpc: rpc,
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });

      // A real gateway answers session.create with no `running` field.
      harness.responder = (method) => switch (method) {
        'session.create' => {
          'session_id': 'runtime-1',
          'stored_session_id': 'stored-1',
          'message_count': 0,
          'messages': const [],
          'info': const {},
        },
        _ => const {},
      };
      final stored = await service.createDesktopSession();
      check(stored).equals('stored-1');

      // Absent `running`, the stored id parks at unsupportedGateway — the
      // state that made every turn after the first fail with the generic
      // "Hermes run failed." until a resume repaired it.
      check(service.turnStateFor('stored-1'))
          .equals(HermesDesktopTurnState.unsupportedGateway);

      // The turn settles: the gateway emits session.info against the RUNTIME
      // id. That must repair the stored id too, not just its own key.
      harness.sessionInfo('runtime-1', running: false);
      await Future<void>.delayed(Duration.zero);

      check(service.turnStateFor('stored-1'))
          .equals(HermesDesktopTurnState.idle);
      check(service.turnStateFor('runtime-1'))
          .equals(HermesDesktopTurnState.idle);
    },
  );

  test('a running session.info reports the turn as running', () async {
    final harness = _GatewayHarness();
    final rpc = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => harness.channel,
    );
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(),
      rpc: rpc,
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });

    harness.responder = (method) => switch (method) {
      'session.create' => {
        'session_id': 'runtime-2',
        'stored_session_id': 'stored-2',
        'info': const {},
      },
      _ => const {},
    };
    await service.createDesktopSession();

    harness.sessionInfo('runtime-2', running: true);
    await Future<void>.delayed(Duration.zero);

    check(service.turnStateFor('stored-2'))
        .equals(HermesDesktopTurnState.running);
  });

  test('continued chats request the latest transcript page', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    final harness = _GatewayHarness();
    final adapter = _StubAdapter();
    final rpc = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => harness.channel,
    );
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(adapter),
      rpc: rpc,
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });

    harness.responder = (method) => switch (method) {
      'session.resume' => {
        'session_id': 'runtime-existing',
        'stored_session_id': 'stored-existing',
        'running': false,
      },
      'config.get' => {'value': 'medium'},
      _ => const {},
    };

    final response = await service.streamDesktopResponse(
      HermesChatInput.text('second message'),
      sessionId: 'stored-existing',
      options: const HermesDesktopSessionOptions(),
    );
    harness.event('runtime-existing', 'message.start');
    harness.sessionInfo('runtime-existing', running: false);
    await response.events.toList();

    final historyRequest = adapter.requested.singleWhere(
      (uri) => uri.path.endsWith('/messages'),
    );
    check(historyRequest.queryParameters['order']).equals('latest');
  });

  test(
    'a session the gateway refuses to resume still loads over REST',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
      final harness = _GatewayHarness();
      final adapter = _StubAdapter(
        messages: const [
          {'role': 'user', 'content': 'hello from telegram'},
          {'role': 'assistant', 'content': 'hi'},
        ],
      );
      final rpc = HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      );
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'session-token',
          ),
        ),
        dio: _statusDio(adapter),
        rpc: rpc,
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });
      final turnStates = <HermesDesktopTurnState>[];
      final subscription = service.turnStates.listen(turnStates.add);
      addTearDown(subscription.cancel);

      harness.errorResponder = (method) => switch (method) {
        'session.resume' => {
          'code': 4130,
          'message': 'Session too large to resume',
        },
        _ => null,
      };

      final messages = await service.getSessionMessages('telegram:123');
      await Future<void>.delayed(Duration.zero);

      check(messages).length.equals(2);
      check(messages.last['content']).equals('hi');
      final historyRequest = adapter.requested.singleWhere(
        (uri) => uri.path.endsWith('/messages'),
      );
      check(historyRequest.path)
          .endsWith('/api/sessions/telegram%3A123/messages');
      check(historyRequest.queryParameters['order']).equals('oldest');
      check(historyRequest.queryParameters['limit']).equals('200');
      check(turnStates.last).equals(HermesDesktopTurnState.idle);
    },
  );

  test(
    'Files reads stored history without resuming or consuming runtime events',
    () async {
      final harness = _GatewayHarness();
      final adapter = _StubAdapter(
        messages: const [
          {'role': 'assistant', 'content': 'An output'},
        ],
      );
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'test-token',
          ),
        ),
        dio: _statusDio(adapter),
        rpc: HermesDesktopRpcClient(
          channelFactory: (_, _, {httpClient}) => harness.channel,
        ),
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });
      final messages = await service.readStoredTranscript('session:one');
      expect(messages.single['content'], 'An output');
      expect(harness.sent, isEmpty);
      expect(
        adapter.requested
            .singleWhere((uri) => uri.path.endsWith('/messages'))
            .queryParameters['order'],
        'oldest',
      );
    },
  );

  test(
    'Tasks and installed skills use read-only profile-scoped RPCs',
    () async {
      final harness = _GatewayHarness();
      harness.responder = (method) => switch (method) {
        'session.active_list' => {
          'sessions': [
            {'id': 'runtime', 'session_key': 'stored', 'status': 'working'},
          ],
        },
        'skills.manage' => {
          'skills': {
            'productivity': ['planning'],
            'writing': ['drafting'],
          },
        },
        'commands.catalog' => {
          'pairs': [
            ['planning', 'Plan a project'],
            ['reset', 'Reset chat'],
          ],
        },
        _ => const {},
      };
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopProfile: 'work',
          desktopCredentials: HermesDesktopCredentials(legacyToken: 'fixture'),
        ),
        dio: _statusDio(),
        rpc: HermesDesktopRpcClient(
          channelFactory: (_, _, {httpClient}) => harness.channel,
        ),
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });
      expect(
        (await service.listActiveSessions()).single['session_key'],
        'stored',
      );
      final skills = await service.listSkills();
      expect(skills.map((row) => row['name']), ['planning', 'drafting']);
      expect(skills.map((row) => row['category']), ['productivity', 'writing']);
      expect(skills.first['description'], 'Plan a project');
      expect(
        harness.sent.map((frame) => frame['method']),
        isNot(
          contains(
            anyOf('session.resume', 'session.activate', 'approval.received'),
          ),
        ),
      );
      for (final frame in harness.sent.where(
        (frame) =>
            frame['method'] == 'session.active_list' ||
            frame['method'] == 'skills.manage',
      )) {
        expect((frame['params'] as Map)['profile'], 'work');
      }
    },
  );

  test(
    'File reads keep path, session and profile in the authenticated endpoint',
    () async {
      final adapter = _StubAdapter();
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopProfile: 'work',
          desktopCredentials: HermesDesktopCredentials(legacyToken: 'fixture'),
        ),
        dio: _statusDio(adapter),
      );
      addTearDown(service.close);
      expect(
        await service.readSessionFileDataUrl(
          '/workspace/report.txt',
          'session:one',
        ),
        'data:text/plain;base64,SGVsbG8=',
      );
      final uri = adapter.requested.singleWhere(
        (uri) => uri.path.endsWith('/read-data-url'),
      );
      expect(uri.path, '/api/fs/read-data-url');
      expect(uri.queryParameters, {
        'path': '/workspace/report.txt',
        'session_id': 'session:one',
        'profile': 'work',
      });
      await expectLater(
        service.readSessionFileDataUrl('bad\u0000path', 'session:one'),
        throwsArgumentError,
      );
      expect(
        adapter.requested.where((uri) => uri.path.endsWith('/read-data-url')),
        hasLength(1),
      );
    },
  );

  test('a REST failure after a refused resume is not swallowed', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    final harness = _GatewayHarness();
    final adapter = _FailingMessagesAdapter(status: 404);
    final rpc = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => harness.channel,
    );
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(adapter),
      rpc: rpc,
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });

    harness.errorResponder = (method) => switch (method) {
      'session.resume' => {'code': 4007, 'message': 'Session not found'},
      _ => null,
    };

    Object? failure;
    try {
      await service.getSessionMessages('stored-missing');
    } catch (error) {
      failure = error;
    }
    check(failure)
        .isA<DioException>()
        .has((error) => error.response?.statusCode, 'status')
        .equals(404);
  });

  test('a new bot chat opens before its first prompt is persisted', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    final harness = _GatewayHarness();
    final adapter = _StubAdapter();
    final rpc = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => harness.channel,
    );
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopProfile: 'default',
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(adapter),
      rpc: rpc,
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });

    harness.responder = (method) => switch (method) {
      // No existing "Bot Chat" title match.
      'session.resume' => const {},
      'session.create' => {
        'session_id': 'runtime-new-bot',
        'stored_session_id': 'stored-new-bot',
        'info': const {},
      },
      _ => const {},
    };

    final storedId = await service.openBotChat(
      const HermesBot(name: 'researcher', title: 'Research'),
    );
    check(storedId).equals('stored-new-bot');
    check(await service.getSessionMessages(storedId)).isEmpty();

    check(
      harness.sent.where((frame) => frame['method'] == 'session.resume').length,
    ).equals(1);
    check(adapter.requested.where((uri) => uri.path.endsWith('/messages')))
        .isEmpty();
  });

  test(
    'bot chat transcripts use gateway history instead of dashboard REST',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
      final harness = _GatewayHarness();
      final adapter = _StubAdapter();
      final rpc = HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      );
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          // The CONNECTION profile. A bot chat lives in another profile, and
          // an unscoped read silently resolves against this one instead,
          // returning a different conversation that shares the session id.
          desktopProfile: 'default',
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'session-token',
          ),
        ),
        dio: _statusDio(adapter),
        rpc: rpc,
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });

      harness.responder = (method) => switch (method) {
        'session.resume' => {
          'session_id': 'runtime-bot',
          'stored_session_id': 'stored-bot',
          'info': const {'running': false},
          'running': false,
        },
        'session.history' => {
          'messages': const [
            {'role': 'assistant', 'content': 'Hello from Research'},
          ],
        },
        _ => const {},
      };

      await service.openBotChat(
        const HermesBot(
          name: 'researcher',
          title: 'Research',
          chatSessionId: 'stored-bot',
        ),
      );
      final messages = await service.getSessionMessages('stored-bot');

      check(messages.single['content']).equals('Hello from Research');
      check(adapter.requested.where((uri) => uri.path.endsWith('/messages')))
          .isEmpty();
      final history = harness.sent.singleWhere(
        (frame) => frame['method'] == 'session.history',
      );
      check((history['params'] as Map)['session_id']).equals('runtime-bot');
      check((history['params'] as Map)['profile']).equals('researcher');
    },
  );

  test(
    'every bot-chat RPC names the bot profile, never the connection one',
    () async {
      SharedPreferences.setMockInitialValues({});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
      final harness = _GatewayHarness();
      final rpc = HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => harness.channel,
      );
      final service = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopProfile: 'default',
          desktopCredentials: HermesDesktopCredentials(
            legacyToken: 'session-token',
          ),
        ),
        dio: _statusDio(),
        rpc: rpc,
      );
      addTearDown(() async {
        service.close();
        await harness.dispose();
      });

      harness.responder = (method) => switch (method) {
        'session.resume' => {
          'session_id': 'runtime-bot',
          'stored_session_id': 'stored-bot',
          'info': const {'running': false},
          'running': false,
        },
        'session.steer' => {'status': 'queued'},
        _ => const {},
      };

      await service.openBotChat(
        const HermesBot(
          name: 'researcher',
          title: 'Research',
          chatSessionId: 'stored-bot',
        ),
      );
      await service.interrupt('stored-bot');
      await service.steer('stored-bot', 'hello');
      await service.queue('stored-bot', 'later');
      await service.renameSession('stored-bot', 'Renamed');
      await service.resolveApprovalChoiceForSession(
        'stored-bot',
        approvalId: 'req-1',
        choice: 'once',
      );
      await service.respondToDecision(
        storedSessionId: 'stored-bot',
        runtimeId: 'runtime-bot',
        requestId: 'req-2',
        kind: HermesDecisionKind.clarification,
        value: 'answer',
      );
      await service.reloadMcp(runtimeId: 'runtime-bot');
      // A DENIED MCP setup skips install/enable/authorize and goes straight
      // to mcp.setup.respond, which must also name the bot profile.
      await service.respondToDecision(
        storedSessionId: 'stored-bot',
        runtimeId: 'runtime-bot',
        requestId: 'req-3',
        kind: HermesDecisionKind.mcpSetup,
        value: 'deny',
        mcpServer: 'docs',
        mcpAction: 'enable',
      );

      // The transport injects the CONNECTION profile as a default, so any bot
      // frame that fails to name its own profile silently travels as 'default'.
      final botFrames = harness.sent
          .where((frame) => (frame['params'] as Map)['session_id'] != null)
          .toList();
      check(botFrames).isNotEmpty();
      for (final frame in botFrames) {
        final params = frame['params'] as Map;
        check(
          params['profile'],
          because:
              '${frame['method']} left the bot session on the connection '
              'profile: $params',
        ).equals('researcher');
      }
    },
  );

  test('bot sends keep the bot profile model settings', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    final harness = _GatewayHarness();
    final rpc = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => harness.channel,
    );
    final adapter = _StubAdapter();
    final service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopProfile: 'default',
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'session-token',
        ),
      ),
      dio: _statusDio(adapter),
      rpc: rpc,
    );
    addTearDown(() async {
      service.close();
      await harness.dispose();
    });

    harness.responder = (method) => switch (method) {
      'session.resume' => {
        'session_id': 'runtime-bot',
        'stored_session_id': 'stored-bot',
        'info': const {'running': false},
        'running': false,
      },
      'session.history' => {'messages': const []},
      _ => const {},
    };

    await service.openBotChat(
      const HermesBot(
        name: 'researcher',
        title: 'Research',
        chatSessionId: 'stored-bot',
      ),
    );
    final response = await service.streamDesktopResponse(
      HermesChatInput.text('hello'),
      sessionId: 'stored-bot',
      options: const HermesDesktopSessionOptions(
        model: 'other-model',
        provider: 'other-provider',
        reasoningEffort: 'high',
        fast: true,
      ),
    );
    harness.event('runtime-bot', 'message.start');
    harness.sessionInfo('runtime-bot', running: false);
    await response.events.toList();

    check(
      harness.sent
          .map((frame) => frame['method'])
          .where((method) => method == 'config.get' || method == 'config.set'),
    ).isEmpty();
    final submit = harness.sent.singleWhere(
      (frame) => frame['method'] == 'prompt.submit',
    );
    final params = submit['params'] as Map;
    check(params['profile']).equals('researcher');
    for (final key in ['model', 'provider', 'reasoningEffort', 'fast']) {
      check(params.containsKey(key)).isFalse();
    }
    check(adapter.requested.where((uri) => uri.path.endsWith('/messages')))
        .isEmpty();
  });
  // the gateway reports `session.info` asynchronously after a session is
  // created or resumed. An idle one that lands while `prompt.submit` is in
  // flight was replayed after the acknowledgement and ended the turn before
  // its first delta, leaving an empty reply.
  test('an idle session.info from before the turn does not end it', () async {
    final deltas = await _replyAfterPreTurnFrames(
      (harness) => harness.sessionInfo('runtime-race', running: false),
    );
    check(deltas).equals('Hello there.');
  });

  test(
    'a late tool event does not let an idle session.info end the turn',
    () async {
      final deltas = await _replyAfterPreTurnFrames((harness) {
        harness.event('runtime-race', 'tool.complete', {'name': 'earlier'});
        harness.sessionInfo('runtime-race', running: false);
      });
      check(deltas).equals('Hello there.');
    },
  );
}

/// Streams a reply while [preTurnFrames] arrive before `prompt.submit` is
/// acknowledged, and returns the text that reached the caller.
Future<String> _replyAfterPreTurnFrames(
  void Function(_GatewayHarness harness) preTurnFrames,
) async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  final harness = _GatewayHarness();
  final rpc = HermesDesktopRpcClient(
    channelFactory: (_, _, {httpClient}) => harness.channel,
  );
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'session-token',
      ),
    ),
    dio: _statusDio(),
    rpc: rpc,
  );
  addTearDown(() async {
    service.close();
    await harness.dispose();
  });

  harness.responder = (method) {
    if (method == 'prompt.submit') {
      // Delivered before the acknowledgement, as on the wire.
      preTurnFrames(harness);
      return {'status': 'streaming'};
    }
    return switch (method) {
      'session.resume' => {
        'session_id': 'runtime-race',
        'stored_session_id': 'stored-race',
        'running': false,
      },
      'config.get' => {'value': 'medium'},
      _ => const {},
    };
  };

  final response = await service.streamDesktopResponse(
    HermesChatInput.text('hello'),
    sessionId: 'stored-race',
    options: const HermesDesktopSessionOptions(),
  );
  final events = response.events.toList();
  await Future<void>.delayed(Duration.zero);
  harness.event('runtime-race', 'message.start');
  harness.event('runtime-race', 'message.delta', {'text': 'Hello there.'});
  harness.event('runtime-race', 'message.complete', {'text': 'Hello there.'});
  harness.sessionInfo('runtime-race', running: false);

  final deltas = (await events).whereType<HermesTokenDelta>();
  return deltas.map((event) => event.content).join();
}

class _PickerSelected extends SelectedModel {
  @override
  Model? build() => hermesSyntheticModel();
}

class _PickerConfig extends HermesConfigController {
  _PickerConfig(this.config);
  final HermesConfig config;
  @override
  HermesConfig build() => config;
}

class _PickerMessages extends ChatMessagesNotifier {
  _PickerMessages(this.message);
  final ChatMessage message;
  @override
  List<ChatMessage> build() => [message];
}

Future<({ProviderContainer container, _GatewayHarness harness})>
_pumpConfiguration(
  WidgetTester tester,
  String command, {
  bool autoOpen = false,
  bool reasoningAvailable = true,
  _StubAdapter? adapter,
}) async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  final harness = _GatewayHarness();
  final config = HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    mode: HermesBackendMode.desktopGateway,
    desktopCredentials: HermesDesktopCredentials(legacyToken: 'session-token'),
  );
  final service = HermesDesktopApiService(
    config: config,
    dio: _statusDio(adapter),
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => harness.channel,
    ),
  );
  harness.responder = (method) => switch (method) {
    'session.resume' => {
      'session_id': 'runtime-picker',
      'stored_session_id': 'stored-picker',
      'running': false,
      'info': {'running': false},
    },
    'model.options' => {
      'model': 'model-a',
      'provider': 'configured',
      'providers': [
        {
          'slug': 'configured',
          'capabilities': {
            'model-a': {'reasoning': reasoningAvailable},
          },
          'models': [
            {'id': 'model-a', 'name': 'Model A'},
          ],
        },
      ],
    },
    'config.get' => {'key': 'reasoning', 'value': 'medium', 'display': 'hide'},
    'config.set' =>
      (harness.sent.last['params'] as Map)['key'] == 'model' &&
              (harness.sent.last['params'] as Map)['confirm_expensive_model'] !=
                  true
          ? {'confirm_required': true, 'confirm_message': 'Confirm this model'}
          : {
              'key': (harness.sent.last['params'] as Map)['key'],
              'value': (harness.sent.last['params'] as Map)['value'],
            },
    _ => {},
  };
  await tester.runAsync(() => service.sessionModelOptions('stored-picker'));
  late final ChatMessage message;
  final container = ProviderContainer(
    overrides: [
      hermesApiServiceProvider.overrideWithValue(service),
      hermesConfigProvider.overrideWith(() => _PickerConfig(config)),
      selectedModelProvider.overrideWith(_PickerSelected.new),
      chatMessagesProvider.overrideWith(() => _PickerMessages(message)),
      apiServiceProvider.overrideWithValue(null),
    ],
  );
  addTearDown(() async {
    container.dispose();
    service.close();
    await harness.dispose();
  });
  final identity = HermesLocalDocumentTrustStore.connectionIdentity(
    endpointIdentity: HermesConfigController.connectionEndpoint(
      config.baseUrl,
    )!,
    principalId: container
        .read(hermesConfigProvider.notifier)
        .documentTrustPrincipalId(),
  );
  message = ChatMessage(
    id: 'configuration',
    role: 'assistant',
    content: 'Current setting',
    timestamp: DateTime(2026),
    metadata: {
      'hermesConfigurationCommand': command,
      'hermesConfigurationSessionId': 'stored-picker',
      if (autoOpen) 'hermesConfigurationAutoOpen': true,
      kHermesConnectionIdentityMetadataKey: identity,
    },
  );
  container
      .read(activeConversationProvider.notifier)
      .set(
        markNativeHermesConversation(
          Conversation(
            id: 'native-picker',
            title: 'Settings test',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            messages: [message],
            metadata: {
              'hermesSessionId': 'stored-picker',
              kHermesConnectionIdentityMetadataKey: identity,
            },
          ),
        ),
      );
  if (autoOpen) {
    container.read(hermesMobileNavigationProvider.notifier).showConversation();
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HermesConfigurationActions(message: message)),
      ),
    ),
  );
  if (autoOpen) {
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  } else {
    await tester.pumpAndSettle();
  }
  return (container: container, harness: harness);
}
