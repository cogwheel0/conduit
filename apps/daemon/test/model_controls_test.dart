@TestOn('vm')
library;

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show ModelControlChoicesNotifier, modelControlChoicesProvider;
import 'package:conduit_core/models/model.dart' as core;

import 'dart:async';

import 'package:conduit_core/models/model_controls.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _agentId = 'agent:bench:codex:gpt-5.1';

/// A coding agent as Open WebUI lists it: an effort with a default, and a
/// service tier with none.
const _agent = core.Model(
  id: _agentId,
  name: 'Codex · gpt-5.1',
  metadata: <String, dynamic>{
    'info': <String, dynamic>{
      'params': <String, dynamic>{
        'model_controls': <String, dynamic>{
          'reasoning_effort': <String, dynamic>{
            'label': 'Reasoning effort',
            'default': 'medium',
            'options': <String, dynamic>{
              'low': <String, dynamic>{'label': 'Low'},
              'medium': <String, dynamic>{'label': 'Medium'},
              'high': <String, dynamic>{'label': 'High'},
            },
          },
          'service_tier': <String, dynamic>{
            'label': 'Service tier',
            'options': <String, dynamic>{
              'flex': <String, dynamic>{'label': 'Flex'},
              'priority': <String, dynamic>{'label': 'Priority'},
            },
          },
        },
      },
    },
  },
);

/// The account's saved picks, kept here instead of on a server.
final class _Picks extends ModelControlChoicesNotifier {
  final List<(String, String, String?)> chosen = [];

  @override
  Future<ModelControlChoices> build() async => const {
    _agentId: {'service_tier': 'priority'},
  };

  @override
  Future<void> choose(
    core.Model model,
    String controlKey,
    String? value, {
    ModelControlChoices? loaded,
  }) async {
    chosen.add((model.id, controlKey, value));
    final forModel = {...?state.value?[model.id]};
    if (value == null) {
      forModel.remove(controlKey);
    } else {
      forModel[controlKey] = value;
    }
    state = AsyncData({...?state.value, model.id: forModel});
  }
}

/// Picks that are still being read until [loaded] completes.
final class _SlowPicks extends _Picks {
  static Completer<void> loaded = Completer<void>();

  @override
  Future<ModelControlChoices> build() async {
    await loaded.future;
    return super.build();
  }
}

void main() {
  late ProviderContainer container;
  late ModelsService models;

  setUp(() {
    container = ProviderContainer(
      overrides: [modelControlChoicesProvider.overrideWith(_Picks.new)],
    );
    addTearDown(container.dispose);
    container.listen(modelControlChoicesProvider, (_, _) {});
    container.read(selectedModelProvider.notifier).set(_agent);
    models = ModelsService(container);
  });

  test("the selected agent's controls carry the option in force", () async {
    final list = await models.controls(const ModelControlsQuery());

    expect(list.modelId, _agentId);
    expect(list.controls.map((c) => c.key), [
      'reasoning_effort',
      'service_tier',
    ]);
    final effort = list.controls.first;
    expect(effort.options.map((o) => o.value), ['low', 'medium', 'high']);
    // Nothing picked: the control's own default.
    expect(effort.defaultValue, 'medium');
    expect(effort.value, 'medium');
    // The saved pick.
    expect(list.controls.last.value, 'priority');
  });

  test('a pick is saved, and a cleared pick falls back', () async {
    var list = await models.setControl(
      const SetModelControl(key: 'reasoning_effort', value: 'high'),
    );
    expect(list.controls.first.value, 'high');

    list = await models.setControl(
      const SetModelControl(key: 'service_tier', value: null),
    );
    // No default: "Default".
    expect(list.controls.last.value, isNull);
    final picks =
        container.read(modelControlChoicesProvider.notifier) as _Picks;
    expect(picks.chosen, [
      (_agentId, 'reasoning_effort', 'high'),
      (_agentId, 'service_tier', null),
    ]);
  });

  test('an option the control does not offer is refused', () async {
    await expectLater(
      models.setControl(
        const SetModelControl(key: 'reasoning_effort', value: 'ludicrous'),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.invalidParams,
        ),
      ),
    );
    await expectLater(
      models.setControl(const SetModelControl(key: 'verbosity', value: 'x')),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
  });

  test('a pick asked under one account is never saved for the next', () async {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    addTearDown(PreferencesStore.debugReset);
    var session = Object();
    _SlowPicks.loaded = Completer<void>();
    final slow = ProviderContainer(
      overrides: [
        modelControlChoicesProvider.overrideWith(_SlowPicks.new),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => session),
      ],
    );
    addTearDown(slow.dispose);
    slow.listen(modelControlChoicesProvider, (_, _) {});
    slow.read(selectedModelProvider.notifier).set(_agent);
    final saving = ModelsService(
      slow,
    ).setControl(const SetModelControl(key: 'reasoning_effort', value: 'high'));
    await Future<void>.delayed(Duration.zero);
    // Another session takes charge while the picks are still read.
    session = Object();
    slow.invalidate(openWebUiAuthSessionEpochProvider);
    slow.read(openWebUiAuthSessionEpochProvider);
    _SlowPicks.loaded.complete();
    await expectLater(
      saving,
      throwsA(
        isA<RpcError>()
            .having((e) => e.code, 'code', ConduitErrorCodes.sessionExpired)
            .having((e) => e.args['reason'], 'reason', 'account'),
      ),
    );
    final picks = slow.read(modelControlChoicesProvider.notifier) as _Picks;
    expect(picks.chosen, isEmpty, reason: "saved to the next account's server");
  });

  test('a model without controls has none', () async {
    container
        .read(selectedModelProvider.notifier)
        .set(const core.Model(id: 'fake-model', name: 'Kestrel'));
    final list = await models.controls(const ModelControlsQuery());
    expect(list.modelId, 'fake-model');
    expect(list.controls, isEmpty);
  });
}
