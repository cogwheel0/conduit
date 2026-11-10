import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/model.dart';
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

final class _FixedHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    apiKey: 'key',
    sessionKey: 'memory',
  );

  @override
  Future<String> ensureSessionKey() async => 'memory';
}

/// A Hermes whose run waits, as one does on an approval, until [events]
/// ends.
final class _WaitingHermesApi extends HermesApiService {
  _WaitingHermesApi(this.events)
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  final Stream<HermesRunEvent> events;
  var runs = 0;

  @override
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async => 'session-1';

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async => 'run-${++runs}';

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
    int? lastEventId,
    void Function(int seq)? onSequence,
  }) => events;
}

/// A Desktop Gateway whose new sessions cannot be made: the turn fails its
/// preflight, before Hermes has its words.
final class _NoNewSessionDesktopApi extends HermesApiService
    implements HermesDesktopTurnService {
  _NoNewSessionDesktopApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  var turns = 0;

  @override
  Future<List<Map<String, dynamic>>> getCurrentSessionMessages(
    String id,
  ) async => const [];

  @override
  Future<String> createDesktopSession({
    String? title,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
  }) async => throw StateError('Hermes could not open a session.');

  @override
  Future<HermesResponseStream> streamDesktopResponse(
    HermesChatInput input, {
    String? sessionId,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
    String? voiceContext,
    int? truncateBeforeRowId,
    int? truncateSeenThroughRowId,
  }) async {
    turns++;
    return const HermesResponseStream(events: Stream.empty());
  }
}

/// A Desktop Gateway whose turn the user kept off a held model switch.
final class _DeclinedSwitchDesktopApi extends HermesApiService
    implements HermesDesktopTurnService {
  _DeclinedSwitchDesktopApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'key',
        ),
        dio: Dio(),
      );

  @override
  Future<List<Map<String, dynamic>>> getCurrentSessionMessages(
    String id,
  ) async => const [];

  @override
  Future<String> createDesktopSession({
    String? title,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
  }) async => 'session-1';

  @override
  Future<HermesResponseStream> streamDesktopResponse(
    HermesChatInput input, {
    String? sessionId,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
    String? voiceContext,
    int? truncateBeforeRowId,
    int? truncateSeenThroughRowId,
  }) async => throw const HermesModelSwitchDeclined(
    model: 'pricier-model',
    previousModel: 'other-model',
    previousProvider: 'synthetic-provider',
  );
}

final _pricierModel = hermesDesktopModel(
  modelId: 'pricier-model',
  name: 'Pricier',
  provider: 'synthetic-provider',
);
final _otherModel = hermesDesktopModel(
  modelId: 'other-model',
  name: 'Other',
  provider: 'synthetic-provider',
);

final class _HermesModels extends Models {
  @override
  Future<List<Model>> build() async => [_pricierModel, _otherModel];
}

final class _SelectedPricierModel extends SelectedModel {
  @override
  Model build() => _pricierModel;
}

final class _SelectedHermesModel extends SelectedModel {
  @override
  Model build() => hermesSyntheticModel();
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
  setUp(() {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
  });
  tearDown(() {
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
    PreferencesStore.debugReset();
  });

  // The composer gives up a sent message's words when the turn starts. A
  // Hermes send returns only when its run ends, which an approval holds
  // open, so the composer kept showing the sent words until then.
  test('a Hermes send says its turn started while the run waits', () async {
    final events = StreamController<HermesRunEvent>();
    final service = _WaitingHermesApi(events.stream);
    final container = ProviderContainer(
      overrides: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        appDatabaseProvider.overrideWith((ref) {
          final database = AppDatabase(NativeDatabase.memory());
          ref.onDispose(() => unawaited(database.close()));
          return database;
        }),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
        hermesApiServiceProvider.overrideWithValue(service),
        selectedModelProvider.overrideWith(_SelectedHermesModel.new),
        reviewerModeProvider.overrideWithValue(false),
        webSearchEnabledProvider.overrideWith(_NoWebSearch.new),
        imageGenerationEnabledProvider.overrideWith(_NoImageGeneration.new),
        codeInterpreterEnabledProvider.overrideWith(_NoCodeInterpreter.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(hermesConfigProvider);

    final steps = <String>[];
    var sent = false;
    final send = durableSend(
      container,
      'Remove the scratch folder',
      null,
      onAssistantPlaceholderCreated: (_) => steps.add('placeholder'),
      onTurnStarted: () => steps.add('started'),
    ).whenComplete(() => sent = true);
    for (var turn = 0; turn < 100 && service.runs == 0; turn++) {
      await pumpEventQueue();
    }

    check(service.runs).equals(1);
    check(steps).deepEquals(['placeholder', 'started']);
    check(sent).isFalse();

    events.add(const HermesRunDone());
    await events.close();
    await send;
    check(steps).deepEquals(['placeholder', 'started']);
  });

  // The words left the composer as the send began, so a turn whose new
  // session could not be made lost them: Hermes never had them, and a new
  // chat had nothing to keep them in.
  test('a Hermes send whose preflight fails never says its turn started',
      () async {
    final service = _NoNewSessionDesktopApi();
    final container = ProviderContainer(
      overrides: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        appDatabaseProvider.overrideWith((ref) {
          final database = AppDatabase(NativeDatabase.memory());
          ref.onDispose(() => unawaited(database.close()));
          return database;
        }),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
        hermesApiServiceProvider.overrideWithValue(service),
        selectedModelProvider.overrideWith(_SelectedHermesModel.new),
        reviewerModeProvider.overrideWithValue(false),
        webSearchEnabledProvider.overrideWith(_NoWebSearch.new),
        imageGenerationEnabledProvider.overrideWith(_NoImageGeneration.new),
        codeInterpreterEnabledProvider.overrideWith(_NoCodeInterpreter.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(hermesConfigProvider);

    final steps = <String>[];
    await durableSend(
      container,
      'Remove the scratch folder',
      null,
      onAssistantPlaceholderCreated: (_) => steps.add('placeholder'),
      onTurnStarted: () => steps.add('started'),
    );

    check(service.turns).equals(0);
    check(steps).deepEquals(['placeholder']);
  });

  // Kept on its model over a switch Hermes held, the chat had sent nothing:
  // its words go back to the composer, and its picker to the model the
  // session is on, so sending again stays there.
  test('a Hermes send kept off a held switch gives its words and model back',
      () async {
    final container = ProviderContainer(
      overrides: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        appDatabaseProvider.overrideWith((ref) {
          final database = AppDatabase(NativeDatabase.memory());
          ref.onDispose(() => unawaited(database.close()));
          return database;
        }),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
        hermesApiServiceProvider.overrideWithValue(
          _DeclinedSwitchDesktopApi(),
        ),
        modelsProvider.overrideWith(_HermesModels.new),
        selectedModelProvider.overrideWith(_SelectedPricierModel.new),
        reviewerModeProvider.overrideWithValue(false),
        webSearchEnabledProvider.overrideWith(_NoWebSearch.new),
        imageGenerationEnabledProvider.overrideWith(_NoImageGeneration.new),
        codeInterpreterEnabledProvider.overrideWith(_NoCodeInterpreter.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(hermesConfigProvider);
    await container.read(modelsProvider.future);

    await durableSend(container, 'Remove the scratch folder', null);

    final givenBack = container.read(composerTextInsertionProvider);
    check(givenBack?.text).equals('Remove the scratch folder');
    // Never into a draft begun since.
    check(givenBack?.onlyIntoEmpty).equals(true);
    check(container.read(selectedModelProvider)).identicalTo(_otherModel);
  });
}
