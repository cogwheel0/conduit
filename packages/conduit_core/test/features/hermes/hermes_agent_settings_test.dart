import 'dart:convert';

import 'package:conduit_core/features/hermes/models/hermes_agent_settings.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:test/test.dart';

class _Gateway implements HermesDashboardBridge {
  bool supportsGlobalModel = true;
  final requests = <({String method, Uri uri, Object? body})>[];
  Map<String, dynamic> config = {
    'memory': {'memory_enabled': true, 'user_char_limit': 1400},
    'fallback_providers': [],
  };
  Map<String, dynamic> ensembles = {
    'default_preset': 'default',
    'presets': {
      'default': {
        'enabled': false,
        'reference_models': [
          {'provider': 'example', 'model': 'one'},
        ],
        'aggregator': {'provider': 'example', 'model': 'two'},
      },
    },
  };
  bool reject = false;
  bool older = false;
  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  }) async {
    final data = body == null ? null : jsonDecode(body);
    requests.add((method: method, uri: url, body: data));
    if (older && url.path.startsWith('/api/model/')) {
      return (status: 404, body: '{}');
    }
    final result = switch ((method, url.path)) {
      ('GET', '/api/config') => {'config': config},
      ('GET', '/api/config/schema') => {
        'fields': {
          'memory.memory_enabled': {'type': 'boolean'},
          'fallback_providers': {'type': 'list'},
        },
      },
      ('GET', '/api/model/moa') => ensembles,
      ('GET', '/api/model/info') => {
        'model': 'example',
        'provider': 'example-provider',
      },
      ('GET', '/api/model/auxiliary') => {
        'supports_global_model': supportsGlobalModel,
        'tasks': [
          {'task': 'vision', 'provider': 'auto'},
        ],
      },
      _ => {'ok': !reject},
    };
    return (status: 200, body: jsonEncode(result));
  }

  @override
  Future<void> reload() async {}
  @override
  Future<void> close() async {}
}

void main() {
  late _Gateway gateway;
  late HermesDesktopApiService service;
  setUp(() {
    gateway = _Gateway();
    service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://example.test',
        mode: HermesBackendMode.desktopGateway,
        desktopAuthKind: HermesDesktopAuthKind.dashboardCookie,
        desktopProfile: 'work',
      ),
      dashboardBridgeFactory: ({required root, required accessHeaders}) =>
          gateway,
    );
  });
  tearDown(() => service.close());

  test('reads profile settings, main and auxiliary summaries', () async {
    final data = await service.agentSettings();
    expect(data.field('memory.memory_enabled', 'Memory')!.value, true);
    expect(data.model['model'], 'example');
    expect(data.auxiliary.single['task'], 'vision');
    expect(
      gateway.requests.every((r) => r.uri.queryParameters['profile'] == 'work'),
      true,
    );
  });
  test(
    'global model uses a reference and refuses unsupported servers',
    () async {
      final data = await service.agentSettings();
      expect(data.supportsGlobalModel, isTrue);
      await service.useGlobalModel('vision');
      final write = gateway.requests.where((r) => r.method == 'POST').single;
      expect(write.uri.queryParameters['profile'], 'work');
      expect(write.body, {
        'scope': 'auxiliary',
        'task': 'vision',
        'provider': 'global',
        'model': '',
        'reasoning_effort': null,
      });
      gateway.requests.clear();
      gateway.supportsGlobalModel = false;
      await expectLater(service.useGlobalModel('vision'), throwsStateError);
      expect(gateway.requests.where((r) => r.method == 'POST'), isEmpty);
    },
  );
  test('optional summaries are absent on older dashboard gateways', () async {
    gateway.older = true;
    final data = await service.agentSettings();
    expect(data.auxiliary, isEmpty);
    expect(data.model, isEmpty);
    expect(data.config, isNotEmpty);
  });
  test(
    'saves a minimal nested patch with profile and language preserved',
    () async {
      final data = await service.agentSettings();
      await service.setAgentSetting(
        data.field('memory.memory_enabled', 'Memory')!,
        false,
      );
      final write = gateway.requests.where((r) => r.method == 'PUT').single;
      expect(write.body, {
        'config': {
          'memory': {'memory_enabled': false},
        },
      });
      expect(write.uri.queryParameters, {
        'profile': 'work',
        'preserve_language': 'true',
      });
    },
  );
  test('conflicting edits and invalid values never write', () async {
    final data = await service.agentSettings();
    final field = data.field('memory.memory_enabled', 'Memory')!;
    await expectLater(
      service.setAgentSetting(field, 'false'),
      throwsFormatException,
    );
    gateway.config['memory'] = {'memory_enabled': false};
    await expectLater(service.setAgentSetting(field, false), throwsStateError);
    expect(gateway.requests.where((r) => r.method == 'PUT'), isEmpty);
  });
  test('unsupported paths and unsafe paths are rejected', () async {
    const field = HermesSettingField('api_key', 'Key', 'string', '', [], '');
    await expectLater(
      service.setAgentSetting(field, 'secret'),
      throwsFormatException,
    );
    expect(
      () => hermesSettingPatch('__proto__.key', 'x'),
      throwsFormatException,
    );
    expect(gateway.requests, isEmpty);
  });
  test('gateway rejection is not reported as success', () async {
    final data = await service.agentSettings();
    gateway.reject = true;
    await expectLater(
      service.setAgentSetting(
        data.field('memory.memory_enabled', 'Memory')!,
        false,
      ),
      throwsStateError,
    );
  });
  test(
    'main and auxiliary models use explicit profile-scoped model API',
    () async {
      const model = HermesDesktopModelOption(
        id: 'example-model',
        name: 'Example',
        provider: 'example-provider',
        supportsFast: false,
        supportsReasoning: true,
      );
      await service.setDefaultModel(model);
      await service.setDefaultModel(model, task: 'vision');
      await service.resetAuxiliaryModel('vision');
      await service.setAuxiliaryReasoning(
        task: 'vision',
        provider: 'custom:example',
        model: 'example',
        effort: 'high',
        baseUrl: 'https://models.example.test/v1',
      );
      final writes = gateway.requests.where((r) => r.method == 'POST').toList();
      expect(writes[0].body, {
        'model': 'example-model',
        'provider': 'example-provider',
      });
      expect(writes[1].body, {
        'model': 'example-model',
        'provider': 'example-provider',
        'scope': 'auxiliary',
        'task': 'vision',
      });
      expect(writes[2].body, {
        'model': '',
        'provider': 'auto',
        'scope': 'auxiliary',
        'task': 'vision',
        'reasoning_effort': null,
      });
      expect(writes[3].body, {
        'scope': 'auxiliary',
        'task': 'vision',
        'provider': 'custom:example',
        'model': 'example',
        'reasoning_effort': 'high',
        'base_url': 'https://models.example.test/v1',
      });
      expect(
        writes.every((r) => r.uri.queryParameters['profile'] == 'work'),
        true,
      );
    },
  );
  test('fallback ordering preserves provider-specific fields', () async {
    final rows = [
      {
        'model': 'one',
        'provider': 'example',
        'base_url': 'https://example.test',
      },
      {'model': 'two', 'provider': 'example'},
    ];
    await service.setFallbackModels(rows, []);
    expect(gateway.requests.last.body, {
      'config': {'fallback_providers': rows},
    });
    await expectLater(
      service.setFallbackModels([
        {'model': '', 'provider': 'example'},
      ], []),
      throwsFormatException,
    );
  });
  test(
    'voice sections only expose the active provider and valid list editors',
    () {
      final data = HermesAgentSettings(
        config: {
          'tts': {
            'provider': 'edge',
            'edge': {'voice': 'test'},
          },
          'terminal': {
            'env_passthrough': ['LANG'],
          },
          'command_allowlist': [
            {'unsafe': 'object'},
          ],
        },
        schema: {
          'tts.provider': {
            'type': 'select',
            'options': ['edge', 'openai'],
          },
          'tts.edge.voice': {'type': 'string'},
          'tts.openai.voice': {'type': 'string'},
        },
      );
      expect(
        data
            .fields(
              hermesMobileSettingGroups.firstWhere(
                (g) => g.title == 'Speech output',
              ),
            )
            .map((f) => f.path),
        ['tts.provider', 'tts.edge.voice'],
      );
      expect(data.field('command_allowlist', 'Commands'), isNull);
      expect(
        data.field('terminal.env_passthrough', 'Environment')!.type,
        'list',
      );
      expect(data.field('nonexistent.field', 'Missing'), isNull);
    },
  );
  test('numbers respect finite values and schema bounds', () {
    const field = HermesSettingField(
      'memory.memory_char_limit',
      'Budget',
      'number',
      10,
      [],
      '',
      minimum: 1,
      maximum: 100,
    );
    expect(() => field.validate(double.nan), throwsFormatException);
    expect(() => field.validate(101), throwsFormatException);
    expect(() => field.validate(50), returnsNormally);
  });
  test(
    'ensembles use a scoped full preset update and reject stale edits',
    () async {
      final original =
          jsonDecode(jsonEncode(gateway.ensembles)) as Map<String, dynamic>;
      final next = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
      ((next['presets'] as Map)['default'] as Map)['enabled'] = true;
      await service.setModelEnsembles(next, original);
      expect(gateway.requests.last.method, 'PUT');
      expect(gateway.requests.last.uri.path, '/api/model/moa');
      expect(gateway.requests.last.body, next);
      expect(gateway.requests.last.uri.queryParameters['profile'], 'work');
      gateway.ensembles['active_preset'] = 'default';
      await expectLater(
        service.setModelEnsembles(next, original),
        throwsStateError,
      );
    },
  );
  test('recursive or empty ensemble models never write', () async {
    final next =
        jsonDecode(jsonEncode(gateway.ensembles)) as Map<String, dynamic>;
    (((next['presets'] as Map)['default'] as Map)['aggregator']
            as Map)['provider'] =
        'moa';
    await expectLater(
      service.setModelEnsembles(next, gateway.ensembles),
      throwsFormatException,
    );
    expect(gateway.requests, isEmpty);
  });
  test(
    'configured custom model endpoints reach the model-setting API',
    () async {
      final parsed = parseHermesDesktopConfiguredModels({
        'providers': [
          {
            'slug': 'custom:example',
            'api_url': 'https://models.example.test/v1',
            'models': ['example-model'],
          },
        ],
      });
      final model = HermesDesktopModelOption.fromJson(parsed.single);
      await service.setDefaultModel(model);
      expect(
        (gateway.requests.last.body as Map)['base_url'],
        'https://models.example.test/v1',
      );
    },
  );
  test('numeric settings validate units and discrete provider formats', () {
    HermesSettingField field(String path) =>
        HermesSettingField(path, path, 'number', 1, [], '');
    expect(
      () => field('memory.memory_char_limit').validate(2.5),
      throwsFormatException,
    );
    expect(
      () => field('memory.memory_char_limit').validate(0),
      returnsNormally,
    );
    expect(
      () => field('compression.threshold').validate(2),
      throwsFormatException,
    );
    expect(
      () => field('tts.xai.sample_rate').validate(30000),
      throwsFormatException,
    );
    expect(() => field('tts.xai.sample_rate').validate(44100), returnsNormally);
    expect(
      () => field('tts.xai.bit_rate').validate(128),
      throwsFormatException,
    );
    expect(() => field('tts.xai.bit_rate').validate(128000), returnsNormally);
    expect(
      () => field('approvals.timeout').validate(1.5),
      throwsFormatException,
    );
    expect(
      () => field('terminal.timeout').validate(1.5),
      throwsFormatException,
    );
    expect(
      () => field('agent.api_max_retries').validate(0),
      throwsFormatException,
    );
    expect(
      () => field('delegation.child_timeout_seconds').validate(10),
      throwsFormatException,
    );
    expect(
      () => field('delegation.child_timeout_seconds').validate(0),
      returnsNormally,
    );
  });

  test(
    'nullable turn cap retains original value while offering numeric Unlimited',
    () {
      final data = HermesAgentSettings(
        config: {
          'agent': {'max_turns': null},
        },
        schema: {
          'agent.max_turns': {'type': 'string'},
        },
      );
      final field = data.field('agent.max_turns', 'Turn limit')!;
      expect(field.type, 'number');
      expect(field.value, isNull);
      expect(() => field.validate(0), returnsNormally);
      expect(() => field.validate(50), returnsNormally);
      expect(() => field.validate(1.5), throwsFormatException);
    },
  );
}
