import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

final class _FixedHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    apiKey: 'test-key',
    sessionKey: 'test-session-key',
  );

  @override
  Future<String> ensureSessionKey() async => 'test-session-key';
}

final class _RemapSyncEngine extends SyncEngine {
  final StreamController<RemapEvent> _events =
      StreamController<RemapEvent>.broadcast(sync: true);

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Stream<RemapEvent> get remapEvents => _events.stream;

  bool get hasListener => _events.hasListener;

  void emit(RemapEvent event) => _events.add(event);

  Future<void> closeEvents() => _events.close();
}

final class _LiveHermesApi extends HermesApiService {
  _LiveHermesApi()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'test-key',
          sessionKey: 'test-session-key',
        ),
        dio: Dio(),
      );

  final StreamController<HermesRunEvent> events =
      StreamController<HermesRunEvent>(sync: true);
  final Completer<void> runEventsStarted = Completer<void>();
  final List<String> stoppedRuns = <String>[];

  @override
  Future<String> createSession({String? title, CancelToken? cancelToken}) =>
      Future<String>.error(
        StateError('The remap test must bind its existing Hermes session.'),
      );

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async => 'live-run';

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) {
    if (!runEventsStarted.isCompleted) runEventsStarted.complete();
    return events.stream;
  }

  @override
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {
    stoppedRuns.add(runId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a live Hermes run remains stoppable after OpenWebUI remaps its chat',
    () async {
      const localId = 'local:hermes-openwebui';
      const serverId = 'server-chat-id';
      const assistantId = 'assistant-id';
      final database = AppDatabase(NativeDatabase.memory());
      final authEpoch = Object();
      final syncEngine = _RemapSyncEngine();
      final service = _LiveHermesApi();
      final container = ProviderContainer(
        overrides: [
          openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
          appDatabaseProvider.overrideWithValue(database),
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          openWebUiAuthSessionEpochProvider.overrideWithValue(authEpoch),
          hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
          hermesApiServiceProvider.overrideWithValue(service),
          syncEngineProvider.overrideWith(() => syncEngine),
        ],
      );
      addTearDown(() async {
        for (final cancellation
            in container.read(hermesRunRegistryProvider).cancelAll()) {
          await cancellation.catchError((_) {});
        }
        container.dispose();
        await service.events.close();
        await syncEngine.closeEvents();
        await database.close();
      });

      final now = DateTime.utc(2026, 7, 13);
      final endpointIdentity = HermesConfigController.connectionEndpoint(
        service.config.baseUrl,
      )!;
      final connectionIdentity =
          HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: endpointIdentity,
            principalId: container
                .read(hermesConfigProvider.notifier)
                .documentTrustPrincipalId(),
          );
      final previousAssistant = ChatMessage(
        id: 'previous-assistant',
        role: 'assistant',
        content: 'Earlier response',
        timestamp: now,
        metadata: <String, dynamic>{
          'hermesSessionId': 'session-1',
          kHermesConnectionIdentityMetadataKey: connectionIdentity,
        },
      );
      final placeholder = ChatMessage(
        id: assistantId,
        role: 'assistant',
        content: '',
        timestamp: now,
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
      final localConversation = withChatStorageProvenance(
        Conversation(
          id: localId,
          title: 'OpenWebUI chat',
          createdAt: now,
          updatedAt: now,
          messages: <ChatMessage>[previousAssistant, placeholder],
        ),
        ChatStorageKind.openWebUi,
      );
      container
          .read(activeConversationProvider.notifier)
          .set(localConversation);
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(localConversation.messages);

      final dispatch = dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: assistantId,
        input: 'Continue through the remap',
        existingMessages: <ChatMessage>[previousAssistant],
      );
      await service.runEventsStarted.future.timeout(const Duration(seconds: 1));
      final trackedWhileLive = syncEngine.hasListener;

      container
          .read(activeConversationProvider.notifier)
          .remapIdInPlace(fromId: localId, toId: serverId);
      syncEngine.emit(
        const RemapEvent(fromId: localId, toId: serverId, entityKind: 'chat'),
      );
      service.events.add(const HermesTokenDelta('Scoped after remap'));
      await Future<void>.delayed(Duration.zero);
      container.read(chatMessagesProvider.notifier).syncStreamingBuffer();
      final remappedCallbackStayedScoped = container
          .read(chatMessagesProvider)
          .where((message) => message.id == assistantId)
          .single
          .content
          .contains('Scoped after remap');
      container.read(stopGenerationProvider)();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final stoppedThroughRemappedKey = service.stoppedRuns.contains(
        'live-run',
      );

      if (!stoppedThroughRemappedKey) {
        final localKey = hermesRunKey(
          ownerConversationId: openWebUiChatMutationOwnerScope(localId),
          assistantMessageId: assistantId,
          backendIdentity: HermesRunBackendIdentity.openWebUi(
            database: database,
            api: null,
            authSessionEpoch: authEpoch,
          ),
        );
        final cleanup = container
            .read(hermesRunRegistryProvider)
            .cancel(localKey);
        await dispatch.timeout(const Duration(seconds: 1));
        await cleanup?.timeout(const Duration(seconds: 1));
      } else {
        await dispatch.timeout(const Duration(seconds: 1));
      }
      await Future<void>.delayed(Duration.zero);

      check(trackedWhileLive).isTrue();
      check(remappedCallbackStayedScoped).isTrue();
      check(stoppedThroughRemappedKey).isTrue();
      check(syncEngine.hasListener).isFalse();
    },
  );

  test('remap collision cancels only the moving generation', () async {
    final registry = HermesRunRegistry();
    final sourceKey = legacyHermesRunKey('local-assistant');
    final destinationKey = legacyHermesRunKey('server-assistant');
    final sourceToken = CancelToken();
    final destinationToken = CancelToken();
    final sourceEvents = StreamController<void>();
    final destinationEvents = StreamController<void>();
    final stopped = <String>[];
    var sourceCancelled = 0;
    var destinationCancelled = 0;
    addTearDown(() async {
      for (final cancellation in registry.cancelAll()) {
        await cancellation.catchError((_) {});
      }
      await sourceEvents.close();
      await destinationEvents.close();
    });

    registry.registerPending(
      sourceKey,
      cancelToken: sourceToken,
      onCancelled: () => sourceCancelled++,
    );
    registry.attachRun(
      sourceKey,
      cancelToken: sourceToken,
      runId: 'source-run',
      subscription: sourceEvents.stream.listen((_) {}),
      stopRemote: (runId) async => stopped.add(runId),
    );
    registry.registerPending(
      destinationKey,
      cancelToken: destinationToken,
      onCancelled: () => destinationCancelled++,
    );
    registry.attachRun(
      destinationKey,
      cancelToken: destinationToken,
      runId: 'destination-run',
      subscription: destinationEvents.stream.listen((_) {}),
      stopRemote: (runId) async => stopped.add(runId),
    );

    final rebound = registry.rebindIfVacant(
      sourceKey,
      destinationKey,
      cancelToken: sourceToken,
    );
    final cancellation = registry.cancelOwned(
      sourceKey,
      cancelToken: sourceToken,
    );
    await cancellation;

    check(rebound).isFalse();
    check(sourceCancelled).equals(1);
    check(sourceToken.isCancelled).isTrue();
    check(stopped).deepEquals(<String>['source-run']);
    check(destinationCancelled).equals(0);
    check(destinationToken.isCancelled).isFalse();
    check(registry.runIdFor(destinationKey)).equals('destination-run');
    check(
      registry.owns(destinationKey, cancelToken: destinationToken),
    ).isTrue();
  });

  test(
    'a stale remap generation cannot move or cancel its replacement',
    () async {
      final registry = HermesRunRegistry();
      final localKey = legacyHermesRunKey('local-generation');
      final serverKey = legacyHermesRunKey('server-generation');
      final staleToken = CancelToken();
      final currentToken = CancelToken();
      final staleEvents = StreamController<void>();
      final currentEvents = StreamController<void>();
      addTearDown(() async {
        for (final cancellation in registry.cancelAll()) {
          await cancellation.catchError((_) {});
        }
        await staleEvents.close();
        await currentEvents.close();
      });

      registry.registerPending(
        localKey,
        cancelToken: staleToken,
        onCancelled: () {},
      );
      registry.attachRun(
        localKey,
        cancelToken: staleToken,
        runId: 'stale-run',
        subscription: staleEvents.stream.listen((_) {}),
        stopRemote: (_) async {},
      );
      registry.registerPending(
        localKey,
        cancelToken: currentToken,
        onCancelled: () {},
      );
      registry.attachRun(
        localKey,
        cancelToken: currentToken,
        runId: 'current-run',
        subscription: currentEvents.stream.listen((_) {}),
        stopRemote: (_) async {},
      );

      check(
        registry.rebindIfVacant(localKey, serverKey, cancelToken: staleToken),
      ).isFalse();
      check(registry.cancelOwned(localKey, cancelToken: staleToken)).isNull();
      check(registry.runIdFor(localKey)).equals('current-run');
      check(registry.owns(localKey, cancelToken: currentToken)).isTrue();

      check(
        registry.rebindIfVacant(localKey, serverKey, cancelToken: currentToken),
      ).isTrue();
      check(registry.runIdFor(localKey)).isNull();
      check(registry.runIdFor(serverKey)).equals('current-run');
    },
  );

  test(
    'remap tracking ignores unrelated events and detaches cleanly',
    () async {
      final events = StreamController<RemapEvent>.broadcast(sync: true);
      var currentId = 'local:owned';
      final remaps = <String>[];
      final subscription = trackHermesConversationRemaps(
        events: events.stream,
        currentConversationId: () => currentId,
        onRemap: (fromId, toId) {
          remaps.add('$fromId->$toId');
          currentId = toId;
        },
      );

      events
        ..add(
          const RemapEvent(
            fromId: 'local:owned',
            toId: 'folder-id',
            entityKind: 'folder',
          ),
        )
        ..add(
          const RemapEvent(
            fromId: 'local:other',
            toId: 'server-other',
            entityKind: 'chat',
          ),
        )
        ..add(
          const RemapEvent(
            fromId: 'local:owned',
            toId: 'server-owned',
            entityKind: 'chat',
          ),
        );
      check(remaps).deepEquals(<String>['local:owned->server-owned']);

      await subscription.cancel();
      check(events.hasListener).isFalse();
      events.add(
        const RemapEvent(
          fromId: 'server-owned',
          toId: 'server-later',
          entityKind: 'chat',
        ),
      );
      check(remaps).deepEquals(<String>['local:owned->server-owned']);
      await events.close();
    },
  );
}
