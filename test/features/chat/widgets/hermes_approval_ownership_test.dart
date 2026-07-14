import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _GatedApprovalService extends HermesApiService {
  _GatedApprovalService(this.gate)
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'test-key',
        ),
      );

  final Completer<void> gate;
  final List<(String, String, bool)> decisions = [];
  final StreamController<HermesRunEvent> events =
      StreamController<HermesRunEvent>(sync: true);
  final Completer<void> runEventsStarted = Completer<void>();

  @override
  Future<String> createSession({String? title, CancelToken? cancelToken}) =>
      Future<String>.error(
        StateError('Approval ownership tests must bind an existing session.'),
      );

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    CancelToken? cancelToken,
  }) async => 'approval-run';

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
  Future<void> resolveApproval(
    String runId, {
    required String approvalId,
    required bool approved,
  }) async {
    decisions.add((runId, approvalId, approved));
    await gate.future;
  }

  @override
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {}
}

class _FixedHermesConfigController extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    apiKey: 'test-key',
    sessionKey: 'test-session',
  );

  @override
  Future<String> ensureSessionKey() async => 'test-session';
}

class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

class _RemapSyncEngine extends SyncEngine {
  final StreamController<RemapEvent> events =
      StreamController<RemapEvent>.broadcast(sync: true);

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Stream<RemapEvent> get remapEvents => events.stream;
}

class _TestTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

Map<String, dynamic> _boundHermesSessionMetadata(
  ProviderContainer container,
  String sessionId,
) {
  final endpointIdentity = HermesConfigController.connectionEndpoint(
    'https://hermes.example',
  )!;
  return <String, dynamic>{
    'hermesSessionId': sessionId,
    kHermesConnectionIdentityMetadataKey:
        HermesLocalDocumentTrustStore.connectionIdentity(
          endpointIdentity: endpointIdentity,
          principalId: container
              .read(hermesConfigProvider.notifier)
              .documentTrustPrincipalId(),
        ),
  };
}

ChatMessage _approvalMessage({
  required String runId,
  required String approvalId,
}) => ChatMessage(
  id: 'assistant',
  role: 'assistant',
  content: '',
  timestamp: DateTime(2026),
  // Approval pauses generation; the ownership race is independent of the
  // streaming animation and keeping this settled avoids unrelated UI timers.
  isStreaming: false,
  metadata: <String, dynamic>{
    'transport': kHermesTransport,
    'hermesApproval': <String, dynamic>{
      'state': 'pending',
      'runId': runId,
      'approvalId': approvalId,
      'summary': 'Continue?',
    },
  },
);

Future<void> _seedDurableAssistantOwner(
  AppDatabase database, {
  required String chatId,
  required ChatMessage assistant,
}) async {
  await database.chatsDao.upsertEnvelopeStub(
    id: chatId,
    title: 'Persisted approval chat',
    createdAt: 1,
    updatedAt: 1,
  );
  await database.messagesDao.upsertLocalEcho(
    MessageRowData(
      id: assistant.id,
      chatId: chatId,
      role: assistant.role,
      content: assistant.content,
      model: assistant.model,
      createdAt: assistant.timestamp.millisecondsSinceEpoch ~/ 1000,
      orderIndex: 0,
      payload: <String, dynamic>{
        'id': assistant.id,
        'role': assistant.role,
        'content': assistant.content,
        'timestamp': assistant.timestamp.millisecondsSinceEpoch ~/ 1000,
        'isStreaming': assistant.isStreaming,
        'metadata': assistant.metadata,
      },
    ),
  );
}

void main() {
  testWidgets('a stale button cannot decide a same-id replacement generation', (
    tester,
  ) async {
    final gate = Completer<void>();
    final service = _GatedApprovalService(gate);
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(service),
        hermesCapabilitiesProvider.overrideWith(
          (ref) async => HermesCapabilities.enabledByDefault,
        ),
        textToSpeechControllerProvider.overrideWith(
          _TestTextToSpeechController.new,
        ),
        streamingHapticsEnabledProvider.overrideWithValue(false),
      ],
    );
    var containerDisposed = false;
    addTearDown(() {
      if (!containerDisposed) container.dispose();
    });
    addTearDown(service.close);

    final first = _approvalMessage(
      runId: 'same-run',
      approvalId: 'same-approval',
    );
    final conversation = markNativeHermesConversation(
      Conversation(
        id: 'hermes-chat',
        title: 'Hermes chat',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        messages: [first],
        metadata: const {'backend': 'hermes'},
      ),
    );
    container.read(activeConversationProvider.notifier).set(conversation);
    container.read(chatMessagesProvider.notifier).setMessages([first]);
    final registry = container.read(hermesRunRegistryProvider);
    final key = hermesRunKeyForConversation(
      container,
      conversation: conversation,
      assistantMessageId: first.id,
    );
    final firstToken = CancelToken();
    registry.registerPending(key, cancelToken: firstToken, onCancelled: () {});
    registry.attachRun(
      key,
      cancelToken: firstToken,
      runId: 'same-run',
      subscription: const Stream<void>.empty().listen((_) {}),
      stopRemote: (_) async {},
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: first,
              isStreaming: false,
              animateOnMount: false,
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final replacement = _approvalMessage(
      runId: 'same-run',
      approvalId: 'same-approval',
    );
    final replacementToken = CancelToken();
    registry.registerPending(
      key,
      cancelToken: replacementToken,
      onCancelled: () {},
    );
    registry.attachRun(
      key,
      cancelToken: replacementToken,
      runId: 'same-run',
      subscription: const Stream<void>.empty().listen((_) {}),
      stopRemote: (_) async {},
    );
    container.read(chatMessagesProvider.notifier).setMessages([replacement]);

    // Deliberately do not pump: this taps the callback rendered for the old
    // generation after the registry and message owner were replaced.
    await tester.tap(find.text('Approve'));
    await tester.pump();

    check(service.decisions).isEmpty();
    final current = container.read(chatMessagesProvider).single;
    check(
      (current.metadata!['hermesApproval'] as Map)['state'],
    ).equals('pending');

    await registry.cancel(key);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    containerDisposed = true;
    await tester.pump();
  });

  testWidgets('an in-flight decision cannot settle a replacement approval', (
    tester,
  ) async {
    final gate = Completer<void>();
    final service = _GatedApprovalService(gate);
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(service),
        hermesCapabilitiesProvider.overrideWith(
          (ref) async => HermesCapabilities.enabledByDefault,
        ),
        textToSpeechControllerProvider.overrideWith(
          _TestTextToSpeechController.new,
        ),
        streamingHapticsEnabledProvider.overrideWithValue(false),
      ],
    );
    var containerDisposed = false;
    addTearDown(() {
      if (!containerDisposed) container.dispose();
    });
    addTearDown(service.close);

    final first = _approvalMessage(runId: 'run-a', approvalId: 'approval-a');
    final conversation = markNativeHermesConversation(
      Conversation(
        id: 'hermes-chat',
        title: 'Hermes chat',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        messages: [first],
        metadata: const {'backend': 'hermes'},
      ),
    );
    container.read(activeConversationProvider.notifier).set(conversation);
    container.read(chatMessagesProvider.notifier).setMessages([first]);
    final registry = container.read(hermesRunRegistryProvider);
    final key = hermesRunKeyForConversation(
      container,
      conversation: conversation,
      assistantMessageId: first.id,
    );
    final firstToken = CancelToken();
    registry.registerPending(key, cancelToken: firstToken, onCancelled: () {});
    registry.attachRun(
      key,
      cancelToken: firstToken,
      runId: 'run-a',
      subscription: const Stream<void>.empty().listen((_) {}),
      stopRemote: (_) async {},
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: first,
              isStreaming: false,
              animateOnMount: false,
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Approve'));
    // The widget has not rebuilt yet, so the second button is still callable.
    // The metadata state transition itself must provide the single-flight CAS.
    await tester.tap(find.text('Deny'));
    await tester.pump();

    check(service.decisions).deepEquals([('run-a', 'approval-a', true)]);
    final resolving = container.read(chatMessagesProvider).single;
    check(
      (resolving.metadata!['hermesApproval'] as Map)['state'],
    ).equals('resolving');

    final replacement = _approvalMessage(
      runId: 'run-b',
      approvalId: 'approval-b',
    );
    final replacementToken = CancelToken();
    registry.registerPending(
      key,
      cancelToken: replacementToken,
      onCancelled: () {},
    );
    registry.attachRun(
      key,
      cancelToken: replacementToken,
      runId: 'run-b',
      subscription: const Stream<void>.empty().listen((_) {}),
      stopRemote: (_) async {},
    );
    container.read(chatMessagesProvider.notifier).setMessages([replacement]);

    gate.complete();
    await tester.pump();
    await tester.pump();

    final current = container.read(chatMessagesProvider).single;
    final approval = current.metadata!['hermesApproval'] as Map;
    check(approval['runId']).equals('run-b');
    check(approval['approvalId']).equals('approval-b');
    check(approval['state']).equals('pending');

    await registry.cancel(key);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    containerDisposed = true;
    // Flush Riverpod's zero-duration scheduler task after explicit disposal.
    await tester.pump();
  });

  for (final succeeds in <bool>[true, false]) {
    testWidgets(
      'disposed offscreen approval ${succeeds ? 'success' : 'failure'} '
      'settles its owner projection',
      (tester) async {
        final gate = Completer<void>();
        final service = _GatedApprovalService(gate);
        final container = ProviderContainer(
          overrides: [
            hermesApiServiceProvider.overrideWithValue(service),
            hermesConfigProvider.overrideWith(_FixedHermesConfigController.new),
            hermesCapabilitiesProvider.overrideWith(
              (ref) async => HermesCapabilities.enabledByDefault,
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            textToSpeechControllerProvider.overrideWith(
              _TestTextToSpeechController.new,
            ),
            streamingHapticsEnabledProvider.overrideWithValue(false),
          ],
        );
        var resourcesDisposed = false;
        Future<void> disposeResources() async {
          if (resourcesDisposed) return;
          resourcesDisposed = true;
          for (final cancellation
              in container.read(hermesRunRegistryProvider).cancelAll()) {
            await cancellation
                .timeout(const Duration(seconds: 1))
                .catchError((_) {});
          }
          container.dispose();
          await service.events.close().timeout(const Duration(seconds: 1));
          service.close();
        }

        addTearDown(disposeResources);
        final placeholder =
            _approvalMessage(
              runId: 'approval-run',
              approvalId: 'approval-offscreen',
            ).copyWith(
              isStreaming: true,
              metadata: const <String, dynamic>{'transport': kHermesTransport},
            );
        final owner = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes_approval-owner',
            title: 'Approval owner',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            messages: <ChatMessage>[placeholder],
            metadata: const <String, dynamic>{
              'backend': 'hermes',
              'hermesSessionId': 'approval-owner',
            },
          ),
        );
        container.read(activeConversationProvider.notifier).set(owner);
        container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
          placeholder,
        ]);
        final dispatch = dispatchHermesRunFromChatForTest(
          container,
          assistantMessageId: placeholder.id,
          input: 'ask for approval',
          existingMessages: const <ChatMessage>[],
        );
        await service.runEventsStarted.future.timeout(
          const Duration(seconds: 1),
        );
        service.events.add(
          const HermesApprovalRequested(
            approvalId: 'approval-offscreen',
            summary: 'Continue?',
          ),
        );
        await tester.pump();
        final pending = container.read(chatMessagesProvider).single;

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(TweakcnThemes.t3Chat),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: AssistantMessageWidget(
                  message: pending,
                  isStreaming: true,
                  animateOnMount: false,
                  onDelete: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Approve'));
        await tester.pump();
        check(service.decisions).deepEquals(<(String, String, bool)>[
          ('approval-run', 'approval-offscreen', true),
        ]);

        container
            .read(activeConversationProvider.notifier)
            .set(
              Conversation(
                id: 'other-chat',
                title: 'Other',
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
                messages: const <ChatMessage>[],
                metadata: const <String, dynamic>{'backend': 'hermes'},
              ),
            );
        // Dispose the card while resolveApproval is still awaiting its HTTP
        // result. Projection settlement must not read the dead WidgetRef.
        await tester.pumpWidget(const SizedBox.shrink());
        if (succeeds) {
          gate.complete();
        } else {
          gate.completeError(StateError('approval failed'));
        }
        await tester.pump();
        await tester.pump();

        container.read(activeConversationProvider.notifier).set(owner);
        await tester.pump();
        final restored = container.read(chatMessagesProvider).single;
        final restoredApproval = restored.metadata![kHermesApprovalMeta] as Map;
        check(
          restoredApproval['state'],
        ).equals(succeeds ? 'approved' : 'pending');

        service.events.add(const HermesRunDone());
        await dispatch.timeout(const Duration(seconds: 1));
        await disposeResources();
        // Riverpod schedules provider disposal at zero duration. Drain it while
        // the widget binding is still available so no timer escapes the test.
        await tester.pump();
      },
    );
  }

  for (final succeeds in <bool>[true, false]) {
    testWidgets('approval ${succeeds ? 'success' : 'rollback'} after terminal '
        'persists without owner readoption', (tester) async {
      final gate = Completer<void>();
      final service = _GatedApprovalService(gate);
      final database = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
          appDatabaseProvider.overrideWithValue(database),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
          hermesApiServiceProvider.overrideWithValue(service),
          hermesConfigProvider.overrideWith(_FixedHermesConfigController.new),
          hermesProjectionRetentionLimitsProvider.overrideWithValue((
            maxProjections: 1,
            maxBytes: 256,
          )),
          hermesCapabilitiesProvider.overrideWith(
            (ref) async => HermesCapabilities.enabledByDefault,
          ),
          textToSpeechControllerProvider.overrideWith(
            _TestTextToSpeechController.new,
          ),
          streamingHapticsEnabledProvider.overrideWithValue(false),
        ],
      );
      var disposed = false;
      Future<void> disposeResources() async {
        if (disposed) return;
        disposed = true;
        for (final cancellation
            in container.read(hermesRunRegistryProvider).cancelAll()) {
          await cancellation.catchError((_) {});
        }
        container.dispose();
        await tester.pump(const Duration(milliseconds: 1));
        unawaited(service.events.close().catchError((_) {}));
        await tester.runAsync(database.close);
        service.close();
      }

      addTearDown(disposeResources);
      final placeholder = ChatMessage(
        id: 'terminal-approval-assistant',
        role: 'assistant',
        content: 'oversized approval payload ${'x' * 2048}',
        timestamp: DateTime(2026),
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
      final owner = withChatStorageProvenance(
        Conversation(
          id: 'terminal-approval-chat',
          title: 'Terminal approval',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          messages: <ChatMessage>[placeholder],
        ),
        ChatStorageKind.openWebUi,
      );
      await _seedDurableAssistantOwner(
        database,
        chatId: owner.id,
        assistant: placeholder,
      );
      container.read(activeConversationProvider.notifier).set(owner);
      container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
        placeholder,
      ]);
      final dispatch = dispatchHermesRunFromChatForTest(
        container,
        assistantMessageId: placeholder.id,
        assistantSeed: placeholder,
        input: 'decide after terminal',
        existingMessages: <ChatMessage>[
          ChatMessage(
            id: 'terminal-approval-history',
            role: 'assistant',
            content: 'Earlier',
            timestamp: DateTime(2026),
            metadata: _boundHermesSessionMetadata(
              container,
              'terminal-approval-session',
            ),
          ),
        ],
      );
      await service.runEventsStarted.future.timeout(const Duration(seconds: 1));
      service.events.add(
        const HermesApprovalRequested(
          approvalId: 'terminal-approval-id',
          summary: 'Continue?',
        ),
      );
      await tester.pump();
      final pending = container.read(chatMessagesProvider).single;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: AssistantMessageWidget(
                  message: pending,
                  isStreaming: true,
                  animateOnMount: false,
                  onDelete: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Approve'));
      await tester.pump();
      await tester.tap(find.text('Approve'));
      await tester.pump();

      // Settle and persist the run while resolveApproval is still awaiting
      // HTTP. The later decision must trigger its own owner-bound snapshot.
      service.events.add(const HermesRunDone());
      await dispatch.timeout(const Duration(seconds: 1));
      final resolvingRow = await database.messagesDao.getMessage(
        owner.id,
        placeholder.id,
      );
      final resolvingPayload =
          jsonDecode(resolvingRow!.payload) as Map<String, dynamic>;
      check(
        ((resolvingPayload['metadata'] as Map)[kHermesApprovalMeta]
            as Map)['state'],
      ).equals('resolving');

      await tester.pumpWidget(const SizedBox.shrink());
      if (succeeds) {
        gate.complete();
      } else {
        gate.completeError(StateError('approval failed'));
      }
      final expectedState = succeeds ? 'approved' : 'pending';
      String? durableState;
      String? durableContent;
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump();
        final row = await database.messagesDao.getMessage(
          owner.id,
          placeholder.id,
        );
        durableContent = row!.content;
        final payload = jsonDecode(row.payload) as Map<String, dynamic>;
        durableState =
            ((payload['metadata'] as Map)[kHermesApprovalMeta] as Map)['state']
                as String?;
        if (durableState == expectedState) break;
      }
      check(durableState).equals(expectedState);
      check(durableContent).equals(placeholder.content);
      await disposeResources();
    });
  }

  testWidgets('approval settlement follows an in-flight OpenWebUI remap', (
    tester,
  ) async {
    final gate = Completer<void>();
    final service = _GatedApprovalService(gate);
    final database = AppDatabase(NativeDatabase.memory());
    final syncEngine = _RemapSyncEngine();
    final authEpoch = Object();
    final container = ProviderContainer(
      overrides: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        appDatabaseProvider.overrideWithValue(database),
        apiServiceProvider.overrideWithValue(null),
        socketServiceProvider.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(authEpoch),
        syncEngineProvider.overrideWith(() => syncEngine),
        hermesApiServiceProvider.overrideWithValue(service),
        hermesConfigProvider.overrideWith(_FixedHermesConfigController.new),
        hermesCapabilitiesProvider.overrideWith(
          (ref) async => HermesCapabilities.enabledByDefault,
        ),
        textToSpeechControllerProvider.overrideWith(
          _TestTextToSpeechController.new,
        ),
        streamingHapticsEnabledProvider.overrideWithValue(false),
      ],
    );
    var resourcesDisposed = false;
    Future<void> disposeResources() async {
      if (resourcesDisposed) return;
      resourcesDisposed = true;
      for (final cancellation
          in container.read(hermesRunRegistryProvider).cancelAll()) {
        await cancellation.catchError((_) {});
      }
      container.dispose();
      // Drift deliberately defers query-cache cleanup with zero-delay timers.
      // Advance widget time once after disposal before awaiting database close,
      // as required by Drift's widget-test shutdown contract.
      await tester.pump(const Duration(milliseconds: 1));
      // The run-stream listener and Drift lease have already been revoked.
      // Their test-owned close futures can remain pending after the final
      // listener disappears, so initiate cleanup without turning those
      // orphaned completion contracts into part of the dispatch assertion.
      unawaited(service.events.close().catchError((_) {}));
      await tester.runAsync(() async {
        await syncEngine.events.close();
        await database.close();
      });
      service.close();
    }

    addTearDown(disposeResources);
    final placeholder = ChatMessage(
      id: 'remapped-approval-assistant',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      isStreaming: true,
      metadata: const <String, dynamic>{'transport': kHermesTransport},
    );
    const serverId = 'server-approval-remap';
    // SyncEngine publishes RemapEvent only after the durable rewrite commits.
    // This focused fake drives that event manually, so establish the exact
    // destination message owner promised by the event before publishing it.
    await _seedDurableAssistantOwner(
      database,
      chatId: serverId,
      assistant: placeholder,
    );
    final localOwner = withChatStorageProvenance(
      Conversation(
        id: 'local:approval-remap',
        title: 'Approval remap',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        messages: <ChatMessage>[placeholder],
      ),
      ChatStorageKind.openWebUi,
    );
    container.read(activeConversationProvider.notifier).set(localOwner);
    container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
      placeholder,
    ]);
    final dispatch = dispatchHermesRunFromChatForTest(
      container,
      assistantMessageId: placeholder.id,
      input: 'approve across remap',
      existingMessages: <ChatMessage>[
        ChatMessage(
          id: 'remap-history',
          role: 'assistant',
          content: 'Earlier',
          timestamp: DateTime(2026),
          metadata: _boundHermesSessionMetadata(
            container,
            'approval-remap-session',
          ),
        ),
      ],
    );
    var dispatchSettled = false;
    Object? dispatchError;
    dispatch.then<void>(
      (_) => dispatchSettled = true,
      onError: (Object error, StackTrace _) {
        dispatchError = error;
        dispatchSettled = true;
      },
    );
    await service.runEventsStarted.future.timeout(const Duration(seconds: 1));
    service.events.add(
      const HermesApprovalRequested(
        approvalId: 'approval-remap-id',
        summary: 'Continue after remap?',
      ),
    );
    await tester.pump();
    final pending = container.read(chatMessagesProvider).single;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AssistantMessageWidget(
              message: pending,
              isStreaming: true,
              animateOnMount: false,
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Approve'));
    await tester.pump();

    container
        .read(activeConversationProvider.notifier)
        .remapIdInPlace(fromId: localOwner.id, toId: serverId);
    syncEngine.events.add(
      const RemapEvent(
        fromId: 'local:approval-remap',
        toId: serverId,
        entityKind: 'chat',
      ),
    );
    gate.complete();
    await tester.pump();
    await tester.pump();
    final remappedOwner = container.read(activeConversationProvider)!;

    container
        .read(activeConversationProvider.notifier)
        .set(
          Conversation(
            id: 'other-after-remap',
            title: 'Other',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            metadata: const <String, dynamic>{'backend': 'hermes'},
          ),
        );
    await tester.pumpWidget(const SizedBox.shrink());
    container.read(activeConversationProvider.notifier).set(remappedOwner);
    await tester.pump();
    final restored = container.read(chatMessagesProvider).single;
    final approval = restored.metadata![kHermesApprovalMeta] as Map;
    check(approval['state']).equals('approved');

    service.events.add(const HermesRunDone());
    for (var pump = 0; pump < 10 && !dispatchSettled; pump++) {
      await tester.pump();
    }
    check(dispatchSettled).isTrue();
    if (dispatchError case final error?) throw error;
    await dispatch;
    await disposeResources();
  });
}
