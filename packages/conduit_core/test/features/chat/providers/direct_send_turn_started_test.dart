import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/direct_run_registry.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

final class _FixedProfiles extends DirectConnectionProfilesController {
  _FixedProfiles(this.profile);

  final DirectConnectionProfile profile;

  @override
  Future<List<DirectConnectionProfile>> build() async => [profile];
}

/// A provider whose reply streams until the test ends it, as one does while
/// a tool approval holds it open.
final class _WaitingAdapter implements DirectProviderAdapter {
  final events = StreamController<DirectStreamEvent>();
  final done = Completer<void>();
  var runs = 0;

  @override
  String get key => kOllamaAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    runs++;
    return DirectCompletionRun(
      id: 'run-$runs',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: events.stream,
      cancelToken: CancelToken(),
      done: done.future,
    );
  }

  Future<void> finish() async {
    await events.close();
    if (!done.isCompleted) done.complete();
  }
}

final class _NoWebSearch extends WebSearchEnabledNotifier {
  @override
  bool build() => false;
}

final class _NoImageGeneration extends ImageGenerationEnabledNotifier {
  @override
  bool build() => false;
}

final class _NoCodeInterpreter extends CodeInterpreterEnabledNotifier {
  @override
  bool build() => false;
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  // A Direct send, like a Hermes one, returns only when its reply ends. The
  // composer kept the sent words until then, through any tool approval.
  test('a Direct send says its turn started while the reply runs', () async {
    final adapter = _WaitingAdapter();
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Local provider',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    );
    final models = DirectModelRegistry();
    final model = models.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model-one'),
    ]).single;
    final container = ProviderContainer(
      overrides: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        directLocalDatabaseProvider.overrideWith((ref) {
          final database = AppDatabase(NativeDatabase.memory());
          ref.onDispose(() => unawaited(database.close()));
          return database;
        }),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWithValue(model),
        reviewerModeProvider.overrideWithValue(false),
        directConnectionProfilesProvider.overrideWith(
          () => _FixedProfiles(profile),
        ),
        directModelRegistryProvider.overrideWithValue(models),
        directRunRegistryProvider.overrideWithValue(DirectRunRegistry()),
        directProviderAdapterRegistryProvider.overrideWithValue(
          DirectProviderAdapterRegistry([adapter]),
        ),
        webSearchEnabledProvider.overrideWith(_NoWebSearch.new),
        imageGenerationEnabledProvider.overrideWith(_NoImageGeneration.new),
        codeInterpreterEnabledProvider.overrideWith(_NoCodeInterpreter.new),
      ],
    );
    addTearDown(container.dispose);

    final steps = <String>[];
    var sent = false;
    final send = durableSend(
      container,
      'Summarize the synthetic notes',
      null,
      onAssistantPlaceholderCreated: (_) => steps.add('placeholder'),
      onTurnStarted: () => steps.add('started'),
    ).whenComplete(() => sent = true);
    for (var turn = 0; turn < 200 && adapter.runs == 0; turn++) {
      await pumpEventQueue();
    }

    check(adapter.runs).equals(1);
    check(steps).deepEquals(['placeholder', 'started']);
    check(sent).isFalse();

    adapter.events
      ..add(const DirectContentDelta('Done.'))
      ..add(const DirectStreamDone());
    await adapter.finish();
    await send;
    check(steps).deepEquals(['placeholder', 'started']);
  });
}
