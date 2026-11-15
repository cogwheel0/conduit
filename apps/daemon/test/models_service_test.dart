@TestOn('vm')
library;

import 'dart:io';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesFastTierSelectionProvider;
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _cached = core.Model(id: 'cached-model', name: 'Cached model');

/// The core's model list with the server out of reach: the cached list
/// first, then the refresh behind it fails, and the list stays beside the
/// error.
final class _Unreachable extends Models {
  @override
  Future<List<core.Model>> build() async => const [_cached];

  /// What the refresh behind the cached list leaves.
  void refreshFailed() => state = AsyncError<List<core.Model>>(
    const SocketException('No route to host'),
    StackTrace.current,
  );
}

/// A server offering two models.
final class _Listed extends Models {
  @override
  Future<List<core.Model>> build() async => const [
    core.Model(id: 'first-model', name: 'First model'),
    core.Model(id: 'preferred-model', name: 'Preferred'),
  ];
}

/// Two Hermes models that both offer the Fast tier.
final class _Fast extends Models {
  @override
  Future<List<core.Model>> build() async => const [
    core.Model(id: 'fast-a', name: 'Fast A', metadata: {'hermesFast': true}),
    core.Model(id: 'fast-b', name: 'Fast B', metadata: {'hermesFast': true}),
  ];
}

/// Signed out, or never signed in: there is no list to fall back on.
final class _Failing extends Models {
  @override
  Future<List<core.Model>> build() async =>
      throw const SocketException('No route to host');
}

void main() {
  test('an unreachable server leaves the cached models on offer', () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_Unreachable.new)],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});
    await container.read(modelsProvider.future);
    (container.read(modelsProvider.notifier) as _Unreachable).refreshFailed();
    expect(container.read(modelsProvider).hasError, isTrue);

    final list = await ModelsService(container).list();

    expect(list.models.map((model) => model.id), [_cached.id]);
  });

  test('with nothing chosen, the account default is the selection', () async {
    const first = core.Model(id: 'first-model', name: 'First model');
    const preferred = core.Model(id: 'preferred-model', name: 'Preferred');
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        // The user's settings name a model that the server lists last.
        defaultModelProvider.overrideWith((ref) async => preferred),
      ],
    );
    addTearDown(container.dispose);

    final list = await ModelsService(container).list();

    expect(list.models.first.id, first.id);
    expect(list.selectedId, preferred.id);
    expect((await currentModel(container))?.id, preferred.id);

    // A model picked in the window wins over the default.
    final picked = await ModelsService(container).select(first.id);
    expect(picked.selectedId, first.id);
  });

  test('a default that cannot resolve leaves nothing chosen', () async {
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        defaultModelProvider.overrideWith(
          (ref) async => throw StateError('settings unavailable'),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    final list = await ModelsService(container).list();

    expect(list.models, hasLength(2));
    expect(list.selectedId, isNull);
  });

  Matcher refused(String code) =>
      throwsA(isA<RpcError>().having((e) => e.code, 'code', code));

  test('a pick for a chat that cannot be read is refused', () async {
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        loadConversationProvider.overrideWith(
          (ref, id) async => throw StateError('no chat $id here'),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    await expectLater(
      ModelsService(container).setReasoningEffort(
        const SetReasoningEffort(
          modelId: 'first-model',
          effort: 'high',
          chatId: 'gone',
        ),
      ),
      refused(ConduitErrorCodes.notFound),
    );
  });

  test("another model's Fast tier request changes nothing", () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_Fast.new)],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final models = ModelsService(container);
    await models.select('fast-a');

    await expectLater(
      models.setFastTier(const SetFastTier(modelId: 'fast-b', on: true)),
      refused(ConduitErrorCodes.invalidParams),
    );
    await expectLater(
      models.setFastTier(const SetFastTier(modelId: 'unknown', on: true)),
      refused(ConduitErrorCodes.invalidParams),
    );
    expect(container.read(hermesFastTierSelectionProvider), isFalse);
  });

  test('with no list at all, the failure is the answer', () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_Failing.new)],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    await expectLater(
      ModelsService(container).list(),
      throwsA(isA<SocketException>()),
    );
  });
}
