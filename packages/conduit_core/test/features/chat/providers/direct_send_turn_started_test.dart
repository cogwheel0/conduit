import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart'
    show DirectChatInputException;
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/direct_run_registry.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/account_change_reset.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show accountChangeStopRepliesProvider;
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/sync_engine.dart';
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
  StreamController<DirectStreamEvent> events =
      StreamController<DirectStreamEvent>();
  Completer<void> done = Completer<void>();
  final requests = <DirectCompletionRequest>[];
  var runs = 0;

  /// Completes when the current reply is asked for.
  Completer<void> asked = Completer<void>();

  void prepareNextRun() {
    events = StreamController<DirectStreamEvent>();
    done = Completer<void>();
    asked = Completer<void>();
  }

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
    requests.add(request);
    if (!asked.isCompleted) asked.complete();
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

/// A container whose selected model is a Direct one answered by [adapter].
ProviderContainer _directContainer(
  _WaitingAdapter adapter, {
  List<FileUploadState> tray = const [],
}) {
  final profile = DirectConnectionProfile(
    id: 'profile-one',
    name: 'Local provider',
    adapterKey: kOllamaAdapterKey,
    baseUrl: 'http://localhost:11434',
  );
  final models = DirectModelRegistry();
  final model = models.replaceProfileModels(profile, [
    DirectRemoteModel(id: 'model-one', isMultimodal: true),
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
      attachedFilesProvider.overrideWith(() => _Tray(tray)),
      webSearchEnabledProvider.overrideWith(_NoWebSearch.new),
      imageGenerationEnabledProvider.overrideWith(_NoImageGeneration.new),
      codeInterpreterEnabledProvider.overrideWith(_NoCodeInterpreter.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

final class _Tray extends AttachedFilesNotifier {
  _Tray(this.files);

  final List<FileUploadState> files;

  @override
  List<FileUploadState> build() => files;
}

final class _RemapSyncEngine extends SyncEngine {
  _RemapSyncEngine(this.remapper);

  final IdRemapper remapper;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Stream<RemapEvent> get remapEvents => remapper.remapEvents;

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {}
}

final class _SyncWithOpenWebUiPolicy extends DirectHistoryPolicyController {
  @override
  DirectHistoryPolicy build() => DirectHistoryPolicy.syncWithOpenWebUI;
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  // A Direct send, like a Hermes one, returns only when its reply ends. The
  // composer kept the sent words until then, through any tool approval.
  test('a Direct send says its turn started while the reply runs', () async {
    final adapter = _WaitingAdapter();
    final container = _directContainer(adapter);

    final steps = <String>[];
    var sent = false;
    final send = durableSend(
      container,
      'Summarize the synthetic notes',
      null,
      onAssistantPlaceholderCreated: (_) => steps.add('placeholder'),
      onTurnStarted: () => steps.add('started'),
    ).whenComplete(() => sent = true);
    await adapter.asked.future;

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

  // A chat begun with only a picture is named for it, not "New Chat".
  test('a Direct send without words is titled by its files', () async {
    final image = 'data:image/png;base64,${base64Encode([1, 2, 3])}';
    final adapter = _WaitingAdapter();
    final container = _directContainer(
      adapter,
      tray: [
        FileUploadState(
          file: File('/synthetic/tray/chart.png'),
          fileName: 'chart.png',
          fileSize: 3,
          progress: 1,
          status: FileUploadStatus.completed,
          fileId: image,
          isImage: true,
          base64DataUrl: image,
        ),
      ],
    );

    final send = durableSend(container, '', [image]);
    await adapter.asked.future;

    check(adapter.runs).equals(1);
    final asked = adapter.requests.single.messages.last;
    check(asked.parts.single).isA<DirectImagePart>();
    check(container.read(chatMessagesProvider).first.content).equals('');
    check(container.read(activeConversationProvider)?.title)
        .equals('chart.png');

    adapter.events
      ..add(const DirectContentDelta('A bar chart.'))
      ..add(const DirectStreamDone());
    await adapter.finish();
    await send;

    // The image the message is saved with keeps its name after the send.
    final userMessage = container
        .read(chatMessagesProvider)
        .firstWhere((message) => message.role == 'user');
    check(userMessage.files).isNotNull().deepEquals([
      {'type': 'image', 'url': image, 'name': 'chart.png'},
    ]);
  });

  // An image kept on the server is fetched only after the turn is saved,
  // and the chat is named as it is saved, from the name the tray shows.
  test('a Direct send of a server image alone is titled by it', () async {
    final adapter = _WaitingAdapter();
    final container = _directContainer(
      adapter,
      tray: [
        FileUploadState(
          file: File('/synthetic/tray/scan.png'),
          fileName: 'scan.png',
          fileSize: 3,
          progress: 1,
          status: FileUploadStatus.completed,
          fileId: 'file-scan',
          isImage: true,
        ),
      ],
    );

    // No server here to fetch it from: the send stops once the turn is
    // saved.
    await check(durableSend(container, '', ['file-scan']))
        .throws<DirectChatInputException>();

    check(container.read(activeConversationProvider)?.title).equals('scan.png');
  });

  // The phone keeps a chat no account owns open across an Open WebUI
  // account change (the shared reset), its reply with it.
  group('a Direct reply in a chat kept on this device, across an Open WebUI '
      'account change', () {
    test('runs to the end and is stored when the change asks '
        'nothing', () async {
      final adapter = _WaitingAdapter();
      final container = _directContainer(adapter);
      final send = durableSend(container, 'Tell me about currents', null);
      await adapter.asked.future;
      adapter.events.add(const DirectContentDelta('First half'));
      await pumpEventQueue();
      final chat = container.read(activeConversationProvider)!;

      resetOpenWebUiAccountState(container);
      check(container.read(activeConversationProvider)?.id).equals(chat.id);

      adapter.events
        ..add(const DirectContentDelta(' and the rest'))
        ..add(const DirectStreamDone());
      await adapter.finish();
      await send;
      final shown = container.read(chatMessagesProvider).last;
      check(shown.content).equals('First half and the rest');
      check(shown.isStreaming).isFalse();
    });

    test('Switch stops reply stops it, keeping the words that came, and the '
        'chat stays open', () async {
      final adapter = _WaitingAdapter();
      final container = _directContainer(adapter);
      final send = durableSend(container, 'Tell me about tides', null);
      await adapter.asked.future;
      adapter.events.add(const DirectContentDelta('Words that came'));
      await pumpEventQueue();
      final chat = container.read(activeConversationProvider)!;

      // What the phone does once the user agrees to switch.
      container.read(accountChangeStopRepliesProvider)();
      await send;
      resetOpenWebUiAccountState(container);

      check(container.read(activeConversationProvider)?.id).equals(chat.id);
      final shown = container.read(chatMessagesProvider).last;
      check(shown.content).equals('Words that came');
      check(shown.isStreaming).isFalse();
      await adapter.finish();
    });
  });
  test(
    'a Direct send rejected for an unsupported image never fires onTurnStarted',
    () async {
      final image = 'data:image/png;base64,${base64Encode([1, 2, 3])}';
      final adapter = _WaitingAdapter();
      final profile = DirectConnectionProfile(
        id: 'profile-text-only',
        name: 'Text-only provider',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
      );
      final models = DirectModelRegistry();
      final textOnlyModel = models.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'text-only', isMultimodal: false),
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
          selectedModelProvider.overrideWithValue(textOnlyModel),
          reviewerModeProvider.overrideWithValue(false),
          directConnectionProfilesProvider.overrideWith(
            () => _FixedProfiles(profile),
          ),
          directModelRegistryProvider.overrideWithValue(models),
          directRunRegistryProvider.overrideWithValue(DirectRunRegistry()),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry([adapter]),
          ),
          attachedFilesProvider.overrideWith(
            () => _Tray([
              FileUploadState(
                file: File('/synthetic/tray/photo.png'),
                fileName: 'photo.png',
                fileSize: 3,
                progress: 1,
                status: FileUploadStatus.completed,
                fileId: image,
                isImage: true,
                base64DataUrl: image,
              ),
            ]),
          ),
          webSearchEnabledProvider.overrideWith(_NoWebSearch.new),
          imageGenerationEnabledProvider.overrideWith(_NoImageGeneration.new),
          codeInterpreterEnabledProvider.overrideWith(_NoCodeInterpreter.new),
        ],
      );
      addTearDown(container.dispose);

      var turnStarted = false;
      await check(
        durableSend(container, 'Describe this photo', [
          image,
        ], onTurnStarted: () => turnStarted = true),
      ).throws<DirectChatInputException>();

      check(turnStarted).isFalse();
      check(adapter.runs).equals(0);
    },
  );

  test(
    'stored Direct sends keep placeholder ownership across turns and recovery',
    () async {
      final adapter = _WaitingAdapter();
      final container = _directContainer(adapter);

      ChatSendPlaceholderHandle? turn1Handle;
      var turn1OwnedAtStart = false;
      final turn1 = durableSend(
        container,
        'First stored Direct prompt',
        null,
        onAssistantPlaceholderCreated: (handle) => turn1Handle = handle,
        onTurnStarted: () {
          turn1OwnedAtStart = turn1Handle?.ownsActiveChat(container) ?? false;
        },
      );
      await adapter.asked.future;

      final activeAfterTurn1 = container.read(activeConversationProvider);
      check(activeAfterTurn1).isNotNull();
      check(turn1OwnedAtStart).isTrue();
      check(turn1Handle!.ownsActiveChat(container)).isTrue();
      check(
        container.read(directRunRegistryProvider).hasLiveIntent((
          ownerConversationId: directRunOwnerScopeForTest(
            container,
            activeAfterTurn1!,
          ),
          assistantMessageId: turn1Handle!.assistantMessageId,
        )),
      ).isTrue();

      adapter.events
        ..add(const DirectContentDelta('First reply.'))
        ..add(const DirectStreamDone());
      await adapter.finish();
      await turn1;

      adapter.prepareNextRun();
      ChatSendPlaceholderHandle? turn2Handle;
      var turn2OwnedAtStart = false;
      final turn2 = durableSend(
        container,
        'Second stored Direct prompt',
        null,
        onAssistantPlaceholderCreated: (handle) => turn2Handle = handle,
        onTurnStarted: () {
          turn2OwnedAtStart = turn2Handle?.ownsActiveChat(container) ?? false;
        },
      );
      await adapter.asked.future;

      check(turn2OwnedAtStart).isTrue();
      check(turn2Handle!.ownsActiveChat(container)).isTrue();

      // Recovery on a stored Direct chat relies on ownsActiveChat(ref).
      recoverFailedChatSend(container, StateError('dropped'), turn2Handle);
      final assistant = container
          .read(chatMessagesProvider)
          .firstWhere((m) => m.id == turn2Handle!.assistantMessageId);
      check(assistant.isStreaming).isFalse();
      check(assistant.error).isNotNull();

      adapter.events.add(const DirectStreamDone());
      await adapter.finish();
      await turn2;
    },
  );

  test(
    'temporary Direct sends keep placeholder ownership across turns',
    () async {
      final adapter = _WaitingAdapter();
      final container = _directContainer(adapter);
      container.read(temporaryChatEnabledProvider.notifier).set(true);

      ChatSendPlaceholderHandle? turn1Handle;
      var turn1OwnedAtStart = false;
      final turn1 = durableSend(
        container,
        'First temporary Direct prompt',
        null,
        onAssistantPlaceholderCreated: (handle) => turn1Handle = handle,
        onTurnStarted: () {
          turn1OwnedAtStart = turn1Handle?.ownsActiveChat(container) ?? false;
        },
      );
      await adapter.asked.future;
      check(turn1OwnedAtStart).isTrue();
      check(turn1Handle!.ownsActiveChat(container)).isTrue();

      adapter.events
        ..add(const DirectContentDelta('Temporary reply.'))
        ..add(const DirectStreamDone());
      await adapter.finish();
      await turn1;

      adapter.prepareNextRun();
      ChatSendPlaceholderHandle? turn2Handle;
      var turn2OwnedAtStart = false;
      final turn2 = durableSend(
        container,
        'Second temporary Direct prompt',
        null,
        onAssistantPlaceholderCreated: (handle) => turn2Handle = handle,
        onTurnStarted: () {
          turn2OwnedAtStart = turn2Handle?.ownsActiveChat(container) ?? false;
        },
      );
      await adapter.asked.future;
      check(turn2OwnedAtStart).isTrue();
      check(turn2Handle!.ownsActiveChat(container)).isTrue();

      adapter.events
        ..add(const DirectContentDelta('Second temporary reply.'))
        ..add(const DirectStreamDone());
      await adapter.finish();
      await turn2;
    },
  );

  test('Open WebUI-stored Direct chat remap keeps placeholder ownership and '
      'supports discard', () async {
    final adapter = _WaitingAdapter();
    final profile = DirectConnectionProfile(
      id: 'profile-owui',
      name: 'Local provider',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    );
    final models = DirectModelRegistry();
    final model = models.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model-owui', isMultimodal: true),
    ]).single;
    final openWebUiDb = AppDatabase(NativeDatabase.memory());
    addTearDown(openWebUiDb.close);
    final remapper = IdRemapper(openWebUiDb);
    addTearDown(remapper.dispose);
    final remapEngine = _RemapSyncEngine(remapper);

    final container = ProviderContainer(
      overrides: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        appDatabaseProvider.overrideWithValue(openWebUiDb),
        directLocalDatabaseProvider.overrideWith((ref) {
          final database = AppDatabase(NativeDatabase.memory());
          ref.onDispose(() => unawaited(database.close()));
          return database;
        }),
        syncEngineProvider.overrideWith(() => remapEngine),
        isAuthenticatedProvider2.overrideWithValue(true),
        directHistoryPolicyProvider.overrideWith(_SyncWithOpenWebUiPolicy.new),
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
        attachedFilesProvider.overrideWith(() => _Tray(const [])),
        webSearchEnabledProvider.overrideWith(_NoWebSearch.new),
        imageGenerationEnabledProvider.overrideWith(_NoImageGeneration.new),
        codeInterpreterEnabledProvider.overrideWith(_NoCodeInterpreter.new),
      ],
    );
    addTearDown(container.dispose);

    ChatSendPlaceholderHandle? handle;
    final send = durableSend(
      container,
      'Synced Direct prompt',
      null,
      onAssistantPlaceholderCreated: (created) => handle = created,
    );
    await adapter.asked.future;

    final localActive = container.read(activeConversationProvider)!;
    check(chatStorageKindOf(localActive)).equals(ChatStorageKind.openWebUi);
    check(handle!.ownsActiveChat(container)).isTrue();

    // Remap the Open WebUI chat id in place while the Direct run is live.
    // Awaiting the remap event is the milestone: the run's own listener rebinds
    // registry and owner synchronously as it is delivered.
    const serverId = 'server-direct-42';
    final remapDelivered = remapper.remapEvents.first;
    await remapper.remapChat(
      localId: localActive.id,
      serverId: serverId,
      serverCreatedAt: 1,
      serverUpdatedAt: 2,
    );
    await remapDelivered;
    final remappedActive = withChatStorageProvenance(
      localActive.copyWith(id: serverId),
      ChatStorageKind.openWebUi,
    );
    container.read(activeConversationProvider.notifier).set(remappedActive);

    check(handle!.ownsActiveChat(container)).isTrue();
    check(
      container.read(directRunRegistryProvider).hasLiveIntent((
        ownerConversationId: directRunOwnerScopeForTest(
          container,
          remappedActive,
        ),
        assistantMessageId: handle!.assistantMessageId,
      )),
    ).isTrue();

    // discardUncommittedChatSend also relies on handle._owns(ref, active).
    discardUncommittedChatSend(container, handle);
    check(
      container
          .read(chatMessagesProvider)
          .where((m) => m.id == handle!.assistantMessageId),
    ).isEmpty();

    adapter.events.add(const DirectStreamDone());
    await adapter.finish();
    await send;
  });
}
