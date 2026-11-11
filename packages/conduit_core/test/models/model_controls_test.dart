import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show modelControlChoicesProvider, modelControlStates;
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/model_controls.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A settings endpoint that stores what is posted to it.
class _SettingsServer implements HttpClientAdapter {
  _SettingsServer(this.settings);

  Map<String, dynamic> settings;
  final updates = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    if (options.method == 'POST') {
      final body = await requestStream!.fold<List<int>>(
        <int>[],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      settings = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      updates.add(settings);
    }
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(settings)),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Controls as Open WebUI 0.13.3 builds them for a Codex model
/// (`utils/agents/discovery.py`, `model_controls`).
Model _codex() => Model.fromJson({
  'id': 'agent:t1:codex:gpt-5.1',
  'name': 'codex/gpt-5.1',
  'info': {
    'params': {
      'model_controls': {
        'reasoning_effort': {
          'label': 'Reasoning effort',
          'options': {
            'low': {
              'label': 'low',
              'params': {'reasoning_effort': 'low'},
            },
            'medium': {
              'label': 'medium',
              'params': {'reasoning_effort': 'medium'},
            },
            'xhigh': {
              'label': 'xhigh',
              'params': {'reasoning_effort': 'xhigh'},
            },
          },
          'default': 'medium',
        },
        'service_tier': {
          'label': 'Service tier',
          'options': {
            'flex': {
              'label': 'Flex',
              'params': {'service_tier': 'flex'},
            },
          },
          // Not one of its options: no default.
          'default': 'priority',
        },
        'broken': {'label': 'No options'},
      },
    },
  },
});

void main() {
  test('reads a model\'s controls in the server\'s order', () {
    final controls = modelControlsOf(_codex());
    check(controls.map((c) => c.key).toList())
        .deepEquals(['reasoning_effort', 'service_tier']);
    check(controls.first)
      ..has((c) => c.label, 'label').equals('Reasoning effort')
      ..has((c) => c.defaultValue, 'default').equals('medium');
    check(controls.first.options.map((o) => o.value).toList())
        .deepEquals(['low', 'medium', 'xhigh']);
    check(controls.last.defaultValue).isNull();
    check(modelHasReasoningEffortControl(_codex())).isTrue();
    check(modelHasReasoningEffortControl(const Model(id: 'm', name: 'm')))
        .isFalse();
  });

  test('a saved pick the selected model no longer offers is cleared on '
      'load', () async {
    // Open WebUI refuses a turn whose saved pick is not an option.
    final server = _SettingsServer({
      'ui': {
        'params': {
          'model_controls': {
            'agent:t1:codex:gpt-5.1': {
              'reasoning_effort': 'gone',
              'service_tier': 'flex',
            },
          },
        },
      },
    });
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'test',
        name: 'Test Server',
        url: 'http://localhost:9999',
      ),
      workerManager: WorkerManager(),
    );
    api.dio.httpClientAdapter = server;
    api.dio.interceptors.clear();
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        openWebUiAccountAvailableProvider.overrideWithValue(true),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedModelProvider.notifier).set(_codex());

    final subscription = container.listen(
      modelControlChoicesProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    await container.read(modelControlChoicesProvider.future);
    for (var i = 0; i < 10 && server.updates.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);

    check(server.updates).length.equals(1);
    check(modelControlChoicesFromSettings(server.settings)).deepEquals({
      'agent:t1:codex:gpt-5.1': {'service_tier': 'flex'},
    });
    check(container.read(modelControlChoicesProvider).value)
        .isNotNull()
        .deepEquals({
          'agent:t1:codex:gpt-5.1': {'service_tier': 'flex'},
        });
  });

  test('a pick applies, a stale one falls back to the default', () {
    final states = modelControlStates(_codex(), {
      'agent:t1:codex:gpt-5.1': {
        'reasoning_effort': 'gone',
        'service_tier': 'flex',
      },
    });
    check(states.map((s) => s.value).toList()).deepEquals(['medium', 'flex']);
  });

  group('settings', () {
    test('picks are read from ui.params.model_controls', () {
      check(
        modelControlChoicesFromSettings({
          'ui': {
            'params': {
              'model_controls': {
                'm': {'reasoning_effort': 'high', 'bad': 3},
                'n': 'not a map',
              },
            },
          },
        }),
      ).deepEquals({
        'm': {'reasoning_effort': 'high'},
      });
      check(modelControlChoicesFromSettings(null)).isEmpty();
    });

    test('a pick is saved under ui.params beside the other params', () {
      final next = settingsWithModelControlChoice(
        {
          'ui': {
            'system': 'Be brief.',
            'params': {
              'temperature': 0.2,
              'model_controls': {
                'm': {'service_tier': 'flex'},
              },
            },
          },
        },
        modelId: 'm',
        controlKey: 'reasoning_effort',
        value: 'high',
      );
      check(next).deepEquals({
        'ui': {
          'system': 'Be brief.',
          'params': {
            'temperature': 0.2,
            'model_controls': {
              'm': {'service_tier': 'flex', 'reasoning_effort': 'high'},
            },
          },
        },
      });
    });

    test('a document with only legacy root params keeps them in ui.params', () {
      final next = settingsWithModelControlChoice(
        {
          'params': {'temperature': 0.7},
        },
        modelId: 'm',
        controlKey: 'reasoning_effort',
        value: 'low',
      );
      check(next['ui']).isA<Map>().deepEquals({
        'params': {
          'temperature': 0.7,
          'model_controls': {
            'm': {'reasoning_effort': 'low'},
          },
        },
      });
    });

    test('clearing a pick removes it', () {
      final next = settingsWithModelControlChoice(
        {
          'ui': {
            'params': {
              'model_controls': {
                'm': {'reasoning_effort': 'low'},
              },
            },
          },
        },
        modelId: 'm',
        controlKey: 'reasoning_effort',
        value: null,
      );
      check(modelControlChoicesFromSettings(next))
          .deepEquals({'m': <String, String>{}});
    });
  });
}
