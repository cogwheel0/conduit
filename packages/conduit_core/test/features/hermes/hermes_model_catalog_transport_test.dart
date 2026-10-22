import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model_catalog.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _Channel extends Mock implements WebSocketChannel {}

class _Sink extends Mock implements WebSocketSink {}

class _CatalogRest implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final responses = <String, ({int status, Object body})>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(request);
    final response = request.uri.path == '/api/status'
        ? (status: 200, body: {'auth_required': false, 'desktop_gateway': true})
        : responses[request.uri.queryParameters['provider']] ??
              (status: 404, body: <String, Object>{});
    return ResponseBody.fromString(
      jsonEncode(response.body),
      response.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late HermesDesktopApiService service;
  late HermesDesktopRpcClient rpc;
  late StreamController<Object?> input;
  late List<Map<String, dynamic>> frames;
  late _CatalogRest rest;
  late Map<String, dynamic> inventory;

  setUp(() async {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    frames = [];
    inventory = {
      'providers': [
        {
          'slug': 'custom:one',
          'api_url': 'https://models.example.test/v1',
          'models': [
            {
              'id': 'one-current',
              'name': 'Current model',
              'capabilities': {
                'fast': true,
                'reasoning': true,
                'can_disable_reasoning': false,
                'supported_efforts': ['low', 'high'],
              },
            },
            {'id': 'one-older', 'name': 'Older model'},
          ],
        },
      ],
    };
    input = StreamController<Object?>();
    final channel = _Channel(), sink = _Sink();
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) => input.stream);
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      frames.add(frame);
      if (frame['id'] == null) return;
      final params = frame['params'] as Map? ?? {};
      final Object result = switch (frame['method']) {
        'model.options' => inventory,
        'config.get' => {
          'value': params['key'] == 'reasoning' ? 'high' : 'normal',
        },
        'session.resume' => {
          'session_id': 'runtime-bot',
          'stored_session_id': params['session_id'],
          'running': false,
        },
        _ => {},
      };
      input.add(
        jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
      );
    });
    rpc = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => channel,
    );
    final connect = rpc.connect(Uri.parse('ws://fixture.invalid/api/ws'));
    input.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': {}},
      }),
    );
    await connect;
    // The handshake advertises client capabilities before discovery starts.
    frames.clear();
    rest = _CatalogRest();
    service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'http://fixture.invalid',
        mode: HermesBackendMode.desktopGateway,
        desktopProfile: 'work',
        desktopCredentials: HermesDesktopCredentials(legacyToken: 'fixture'),
      ),
      rpc: rpc,
      dio: Dio()..httpClientAdapter = rest,
    );
  });

  tearDown(() async {
    service.close();
    await rpc.close();
    await input.close();
    PreferencesStore.debugReset();
  });

  List<RequestOptions> recommendationReads() => rest.requests
      .where((r) => r.uri.path == '/api/model/recommended-default')
      .toList();

  void expectDiscoveryOnly({bool resumedSession = false}) {
    expect(rest.requests.every((r) => r.method == 'GET'), true);
    expect(
      frames.where((f) => f['id'] != null).map((f) => f['method']).toSet(),
      resumedSession ? {'session.resume', 'model.options'} : {'model.options'},
    );
  }

  test(
    'overlapping catalog reads share one profile inventory request',
    () async {
      await Future.wait([
        service.configuredModels(),
        service.configuredModels(),
        service.configuredModels(),
      ]);
      expect(frames.where((f) => f['method'] == 'model.options'), hasLength(1));
      await service.configuredModels();
      expect(frames.where((f) => f['method'] == 'model.options'), hasLength(1));
    },
  );

  test('chat readiness uses one cached non-refresh inventory without optional REST metadata', () async {
    inventory['model'] = 'one-current';
    inventory['provider'] = 'custom:one';
    final contexts = await Future.wait([
      service.modelContext(),
      service.modelContext(),
    ]);
    expect(contexts.first.settings.modelId, 'one-current');
    expect(contexts.first.settings.effort, 'high');
    expect(contexts.first.models.map((m) => m.id), [
      'one-current',
      'one-older',
    ]);
    expect(contexts.first.settings.supportsFast, true);
    expect(identical(contexts.first, contexts.last), true);
    expect(frames.where((f) => f['method'] == 'model.options'), hasLength(1));
    expect(frames.where((f) => f['method'] == 'config.get'), hasLength(2));
    final options = frames.singleWhere((f) => f['method'] == 'model.options');
    expect(options['params'], {'profile': 'work', 'explicit_only': true});
    expect(rest.requests.every((r) => r.uri.path == '/api/status'), true);
    inventory['model'] = 'one-older';
    service.invalidateModelContext();
    expect((await service.modelContext()).settings.modelId, 'one-older');
  });

  test(
    'session and follow-global reads stay in the owning bot profile',
    () async {
      inventory['model'] = 'one-current';
      inventory['provider'] = 'custom:one';
      service.bindBotSession('research', 'stored-bot');
      await service.modelContext(sessionId: 'stored-bot');
      final first = frames.lastWhere((f) => f['method'] == 'model.options');
      expect((first['params'] as Map)['profile'], 'research');
      expect((first['params'] as Map)['session_id'], 'runtime-bot');
      expect((first['params'] as Map)['refresh'], isNull);
      await service.modelContext(sessionId: 'stored-bot', followGlobal: true);
      final global = frames.lastWhere((f) => f['method'] == 'model.options');
      expect((global['params'] as Map)['profile'], 'research');
      expect((global['params'] as Map)['session_id'], isNull);
      await service.modelContext();
      final ordinary = frames.lastWhere((f) => f['method'] == 'model.options');
      expect((ordinary['params'] as Map)['profile'], 'work');
    },
  );

  test(
    'cached recommendation hints preserve fresh lifecycle metadata',
    () async {
      inventory['model'] = 'one-current';
      inventory['provider'] = 'custom:one';
      rest.responses['custom:one'] = (
        status: 200,
        body: {'model': 'one-current'},
      );
      final first = await service.modelContext();
      await service.modelRecommendations(first);
      (((inventory['providers'] as List).first as Map)['models'] as List)
              .first['deprecated'] =
          true;
      final fresh = await service.modelContext(refresh: true);
      final enriched = await service.modelRecommendations(fresh);
      expect(enriched.first.deprecated, true);
      expect(recommendationReads(), hasLength(1));
    },
  );

  test(
    'configured catalog refreshes the owning profile and adds live default',
    () async {
      rest.responses['custom:one'] = (
        status: 200,
        body: {'model': 'one-current'},
      );
      final models = await service.configuredModels();
      final options = frames.singleWhere((f) => f['method'] == 'model.options');
      expect(options['params'], {
        'profile': 'work',
        'explicit_only': true,
        'refresh': true,
      });
      final request = recommendationReads().single;
      expect(request.uri.queryParameters, {
        'profile': 'work',
        'provider': 'custom:one',
      });
      expect(models.map((m) => m.id), ['one-current', 'one-older']);
      expect(models.first.isDefault, true);
      expect(models.last.isDefault, isNull);
      expect(models.first.baseUrl, 'https://models.example.test/v1');
      expect(models.first.supportsFast, true);
      expect(models.first.supportedEfforts, ['low', 'high']);
      expect(hermesRecommendedModels(models), [models.first]);
      expectDiscoveryOnly();
    },
  );

  for (final scenario in <String, ({int status, Object body})>{
    'older gateway': (status: 404, body: {}),
    'rejected recommendation': (status: 403, body: {}),
    'server failure': (status: 500, body: {}),
    'missing model field': (status: 200, body: {'provider': 'custom:one'}),
    'unadvertised model': (status: 200, body: {'model': 'not-in-catalog'}),
    'invalid model identity': (status: 200, body: {'model': 'bad\nidentity'}),
  }.entries) {
    test(
      '${scenario.key} retains full catalog without an endorsement',
      () async {
        rest.responses['custom:one'] = scenario.value;
        final models = await service.configuredModels();
        expect(models.map((m) => m.id), ['one-current', 'one-older']);
        expect(models.every((m) => m.isDefault == null), true);
        expect(hermesRecommendedModels(models), isEmpty);
        expectDiscoveryOnly();
      },
    );
  }

  test('recommendation identity cannot cross provider boundaries', () async {
    (inventory['providers'] as List).add({
      'slug': 'custom:two',
      'models': ['two-current'],
    });
    rest.responses['custom:one'] = (
      status: 200,
      body: {'model': 'two-current'},
    );
    rest.responses['custom:two'] = (
      status: 200,
      body: {'model': 'one-current'},
    );
    final models = await service.configuredModels();
    expect(models, hasLength(3));
    expect(models.every((m) => m.isDefault == null), true);
    expect(recommendationReads(), hasLength(2));
    expect(hermesRecommendedModels(models), isEmpty);
    expectDiscoveryOnly();
  });

  test(
    'live default preserves explicit negative recommendation metadata',
    () async {
      final first =
          ((inventory['providers'] as List).first['models'] as List).first
              as Map;
      first['recommended'] = false;
      rest.responses['custom:one'] = (
        status: 200,
        body: {'model': 'one-current'},
      );
      final models = await service.configuredModels();
      expect(models.first.isDefault, true);
      expect(models.first.recommended, false);
      expect(hermesRecommendedModels(models), isEmpty);
      expect(models, hasLength(2));
      expectDiscoveryOnly();
    },
  );

  test(
    'bot session inventory and recommendations stay in its owning profile',
    () async {
      service.bindBotSession('research', 'stored-bot');
      rest.responses['custom:one'] = (
        status: 200,
        body: {'model': 'one-current'},
      );
      final models = await service.sessionModelOptions('stored-bot');
      final resume = frames.singleWhere((f) => f['method'] == 'session.resume');
      expect(resume['params'], {
        'profile': 'research',
        'session_id': 'stored-bot',
        'omit_messages': true,
      });
      final options = frames.singleWhere((f) => f['method'] == 'model.options');
      expect(options['params'], {
        'profile': 'research',
        'session_id': 'runtime-bot',
        'explicit_only': true,
        'refresh': true,
      });
      expect(recommendationReads().single.uri.queryParameters, {
        'profile': 'research',
        'provider': 'custom:one',
      });
      expect(models.map((m) => m.id), ['one-current', 'one-older']);
      expect(models.first.isDefault, true);
      expectDiscoveryOnly(resumedSession: true);
    },
  );
}
