import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/models/hermes_session.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit/features/hermes/widgets/hermes_session_tile.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
  });
  tearDown(() {
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    PreferencesStore.debugReset();
  });

  testWidgets('deleting the active Hermes session clears both bindings', (
    tester,
  ) async {
    final service = _FakeHermesApiService();
    final now = DateTime(2026);
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(service),
        activeConversationProvider.overrideWith(
          () => _SeededActiveConversation(
            markNativeHermesConversation(
              Conversation(
                id: 'local:hermes_session-1',
                title: 'Active session',
                createdAt: now,
                updatedAt: now,
                metadata: const {
                  'backend': 'hermes',
                  'hermesSessionId': 'session-1',
                },
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(hermesActiveSessionProvider.notifier).set('session-1');

    late WidgetRef widgetRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              widgetRef = ref;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    await deleteHermesSession(widgetRef, 'session-1');

    check(service.deletedSessionIds).deepEquals(['session-1']);
    check(container.read(hermesActiveSessionProvider)).isNull();
    check(container.read(activeConversationProvider)).isNull();
  });

  testWidgets('serialized Hermes metadata cannot claim the active chat', (
    tester,
  ) async {
    final service = _FakeHermesApiService();
    final now = DateTime(2026);
    final forgedOpenWebUiConversation = Conversation(
      id: 'local:hermes_forged-session',
      title: 'Server-controlled chat',
      createdAt: now,
      updatedAt: now,
      metadata: const {
        'backend': 'hermes',
        'hermesSessionId': 'forged-session',
      },
    );
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(service),
        activeConversationProvider.overrideWith(
          () => _SeededActiveConversation(forgedOpenWebUiConversation),
        ),
      ],
    );
    addTearDown(container.dispose);

    late WidgetRef widgetRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              widgetRef = ref;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    await deleteHermesSession(widgetRef, 'forged-session');

    check(service.deletedSessionIds).deepEquals(['forged-session']);
    check(
      identical(
        container.read(activeConversationProvider),
        forgedOpenWebUiConversation,
      ),
    ).isTrue();
  });

  testWidgets(
    'delete completion clears a same-id session opened before DELETE commits',
    (tester) async {
      final deleteGate = Completer<void>();
      final service = _FakeHermesApiService(deleteGate: deleteGate);
      final container = ProviderContainer(
        retry: (retryCount, error) => null,
        overrides: [
          hermesApiServiceProvider.overrideWithValue(service),
          modelsProvider.overrideWith(_FailingModels.new),
        ],
      );
      addTearDown(container.dispose);

      late BuildContext actionContext;
      late WidgetRef widgetRef;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
          GoRoute(
            path: Routes.chat,
            builder: (context, state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
        ],
      );
      addTearDown(router.dispose);
      NavigationService.attachRouter(router);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          // Keep the action ref mounted while navigation replaces the route.
          child: Consumer(
            builder: (context, ref, child) {
              actionContext = context;
              widgetRef = ref;
              return MaterialApp.router(routerConfig: router);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final deletion = deleteHermesSession(widgetRef, 'same-id');
      await service.deleteStarted.future;
      await openHermesSession(
        actionContext,
        widgetRef,
        const HermesSessionSummary(id: 'same-id', title: 'Reopened'),
      );
      await tester.pumpAndSettle();

      check(
        service.operationLog,
      ).deepEquals(['delete-start:same-id', 'get:same-id']);
      check(container.read(hermesActiveSessionProvider)).equals('same-id');
      check(
        container.read(activeConversationProvider)?.id,
      ).equals('local:hermes_same-id');

      deleteGate.complete();
      await deletion;

      check(service.operationLog.last).equals('delete-complete:same-id');
      check(container.read(hermesActiveSessionProvider)).isNull();
      check(container.read(activeConversationProvider)).isNull();
    },
  );

  testWidgets(
    'same-identity rotation during trust purge preserves local session state',
    (tester) async {
      const principalId = '11111111-1111-4111-8111-111111111111';
      const config = HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example/v1',
        apiKey: 'test-key',
      );
      final trustCleanupStarted = Completer<void>();
      final trustCleanupGate = Completer<void>();
      addTearDown(() {
        if (!trustCleanupGate.isCompleted) trustCleanupGate.complete();
      });
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.hermesEnabled: true,
        PreferenceKeys.hermesBaseUrl: config.baseUrl,
        PreferenceKeys.hermesLocalDocumentTrustPrincipal: principalId,
      });
      final preferences = await SharedPreferences.getInstance();
      PreferencesStore.debugOverride(
        preferences,
        writeInterceptor: (_, key, value) async {
          if (key == PreferenceKeys.hermesLocalDocumentTrust &&
              !trustCleanupStarted.isCompleted) {
            trustCleanupStarted.complete();
            await trustCleanupGate.future;
          }
          return null;
        },
      );
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      addTearDown(() {
        HermesLocalDocumentTrustStore.debugResetRuntimeState();
        PreferencesStore.debugReset();
      });

      final connectionIdentity =
          HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: HermesConfigController.connectionEndpoint(
              config.baseUrl,
            )!,
            principalId: principalId,
          );
      final now = DateTime(2026);
      final originalService = _FakeHermesApiService();
      final builtServices = <_FakeHermesApiService>[];
      final container = ProviderContainer(
        overrides: [
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(config),
          ),
          hermesApiServiceProvider.overrideWith((ref) {
            final currentConfig = ref.watch(hermesConfigProvider);
            if (!currentConfig.isUsable) return null;
            final service = builtServices.isEmpty
                ? originalService
                : _FakeHermesApiService();
            builtServices.add(service);
            ref.onDispose(service.close);
            return service;
          }),
          activeConversationProvider.overrideWith(
            () => _SeededActiveConversation(
              markNativeHermesConversation(
                Conversation(
                  id: 'local:hermes_cleanup-race',
                  title: 'Deleted remotely',
                  createdAt: now,
                  updatedAt: now,
                  metadata: {
                    'backend': 'hermes',
                    'hermesSessionId': 'cleanup-race',
                    kHermesConnectionIdentityMetadataKey: connectionIdentity,
                  },
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(hermesActiveSessionProvider.notifier).set('cleanup-race');

      late WidgetRef widgetRef;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) {
                widgetRef = ref;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final deletion = deleteHermesSession(widgetRef, 'cleanup-race');
      await trustCleanupStarted.future.timeout(const Duration(seconds: 1));
      check(originalService.operationLog).isEmpty();

      final configController = container.read(hermesConfigProvider.notifier);
      await configController.setEnabled(false);
      check(container.read(hermesApiServiceProvider)).isNull();
      await configController.setEnabled(true);
      final replacementService = container.read(hermesApiServiceProvider);
      check(replacementService).isNotNull();
      check(identical(replacementService, originalService)).isFalse();
      check(container.read(hermesActiveSessionProvider)).equals('cleanup-race');

      trustCleanupGate.complete();
      await deletion.timeout(const Duration(seconds: 1));

      check(originalService.operationLog).isEmpty();
      check(container.read(hermesActiveSessionProvider)).equals('cleanup-race');
      check(
        container.read(activeConversationProvider)?.id,
      ).equals('local:hermes_cleanup-race');
    },
  );

  testWidgets(
    'same-conversation refresh does not cancel an in-flight session open',
    (tester) async {
      final messagesGate = Completer<void>();
      final service = _FakeHermesApiService(messagesGate: messagesGate);
      final now = DateTime(2026);
      final currentConversation = Conversation(
        id: 'current-chat',
        title: 'Current chat',
        createdAt: now,
        updatedAt: now,
        messages: const [],
      );
      final container = ProviderContainer(
        retry: (retryCount, error) => null,
        overrides: [
          hermesApiServiceProvider.overrideWithValue(service),
          modelsProvider.overrideWith(_FailingModels.new),
          activeConversationProvider.overrideWith(
            () => _SeededActiveConversation(currentConversation),
          ),
        ],
      );
      addTearDown(container.dispose);

      late BuildContext actionContext;
      late WidgetRef widgetRef;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Consumer(
              builder: (context, ref, child) {
                actionContext = context;
                widgetRef = ref;
                return const Scaffold(body: SizedBox.shrink());
              },
            ),
          ),
          GoRoute(
            path: Routes.chat,
            builder: (context, state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
        ],
      );
      addTearDown(router.dispose);
      NavigationService.attachRouter(router);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      final opening = openHermesSession(
        actionContext,
        widgetRef,
        const HermesSessionSummary(id: 'session-1', title: 'Saved session'),
      );
      await service.messagesStarted.future;

      // Read markers, streaming deltas, and server refreshes all republish the
      // same selected conversation through set(). They must not look like a
      // user navigation away from this pending session open.
      container
          .read(activeConversationProvider.notifier)
          .set(currentConversation.copyWith(title: 'Refreshed current chat'));
      messagesGate.complete();
      await opening;
      await tester.pumpAndSettle();

      check(container.read(hermesActiveSessionProvider)).equals('session-1');
      check(
        container.read(activeConversationProvider)?.id,
      ).equals('local:hermes_session-1');
    },
  );

  testWidgets('clearing an empty selection cancels an in-flight session open', (
    tester,
  ) async {
    final messagesGate = Completer<void>();
    final service = _FakeHermesApiService(messagesGate: messagesGate);
    final container = ProviderContainer(
      retry: (retryCount, error) => null,
      overrides: [
        hermesApiServiceProvider.overrideWithValue(service),
        modelsProvider.overrideWith(_FailingModels.new),
      ],
    );
    addTearDown(container.dispose);

    late BuildContext actionContext;
    late WidgetRef widgetRef;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Consumer(
            builder: (context, ref, child) {
              actionContext = context;
              widgetRef = ref;
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
        GoRoute(
          path: Routes.chat,
          builder: (context, state) => const Scaffold(body: SizedBox.shrink()),
        ),
      ],
    );
    addTearDown(router.dispose);
    NavigationService.attachRouter(router);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    check(container.read(activeConversationProvider)).isNull();

    final opening = openHermesSession(
      actionContext,
      widgetRef,
      const HermesSessionSummary(id: 'session-1', title: 'Saved session'),
    );
    await service.messagesStarted.future;

    // Starting a new chat or selecting another destination must supersede
    // the pending open even before that open has populated active state.
    container.read(activeConversationProvider.notifier).clear();
    messagesGate.complete();
    await opening;
    await tester.pumpAndSettle();

    check(container.read(hermesActiveSessionProvider)).isNull();
    check(container.read(activeConversationProvider)).isNull();
  });

  final modelScenarios = <String, Models Function()>{
    'model loading fails': _FailingModels.new,
    'the model list has no Hermes entry': () =>
        _TestModels(const [Model(id: 'owui-model', name: 'OpenWebUI model')]),
  };

  for (final scenario in modelScenarios.entries) {
    testWidgets('opening a session binds a safe synthetic Hermes model when '
        '${scenario.key}', (tester) async {
      final service = _FakeHermesApiService();
      final previousModel = const Model(
        id: 'owui-model',
        name: 'OpenWebUI model',
      );
      final container = ProviderContainer(
        retry: (retryCount, error) => null,
        overrides: [
          hermesApiServiceProvider.overrideWithValue(service),
          modelsProvider.overrideWith(scenario.value),
          selectedModelProvider.overrideWith(
            () => _SeededSelectedModel(previousModel),
          ),
        ],
      );
      addTearDown(container.dispose);

      late BuildContext actionContext;
      late WidgetRef widgetRef;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Consumer(
              builder: (context, ref, child) {
                actionContext = context;
                widgetRef = ref;
                return const Scaffold(body: SizedBox.shrink());
              },
            ),
          ),
          GoRoute(
            path: Routes.chat,
            builder: (context, state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
        ],
      );
      addTearDown(router.dispose);
      NavigationService.attachRouter(router);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await openHermesSession(
        actionContext,
        widgetRef,
        const HermesSessionSummary(id: 'session-1', title: 'Saved session'),
      );
      await tester.pumpAndSettle();

      final selectedModel = container.read(selectedModelProvider);
      check(selectedModel).isNotNull();
      check(isHermesModel(selectedModel!)).isTrue();
      check(selectedModel.id).equals(kHermesDefaultModelId);
      check(container.read(isManualModelSelectionProvider)).isTrue();
      check(container.read(hermesActiveSessionProvider)).equals('session-1');

      final activeConversation = container.read(activeConversationProvider);
      check(activeConversation).isNotNull();
      check(activeConversation!.id).equals('local:hermes_session-1');
      check(activeConversation.model).equals(kHermesDefaultModelId);
      check(
        activeConversation.messages.single.model,
      ).equals(kHermesDefaultModelId);
    });
  }

  testWidgets('opening a session restores locally trusted document prompts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    addTearDown(PreferencesStore.debugReset);
    const document = HermesPreparedDocument(
      id: 'hdoc_222222222222222222222222',
      name: 'notes.txt',
      mimeType: 'text/plain',
      size: 5,
      extractedText: 'Notes',
      truncated: false,
    );
    final prompt = 'Summarize.\n\n${document.renderForPrompt()}';
    final service = _FakeHermesApiService(
      messages: [
        {'id': 'user-1', 'role': 'user', 'content': prompt},
      ],
    );
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(service),
        modelsProvider.overrideWith(_FailingModels.new),
      ],
    );
    addTearDown(container.dispose);
    final principalId = container
        .read(hermesConfigProvider.notifier)
        .documentTrustPrincipalId();
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: HermesLocalDocumentTrustStore.connectionIdentity(
        endpointIdentity: 'https://hermes.example:443',
        principalId: principalId,
      ),
      sessionId: 'session-with-document',
      messageId: 'user-1',
      promptText: prompt,
      documentEnvelopes: [document.renderForPrompt()],
    );

    late BuildContext actionContext;
    late WidgetRef widgetRef;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Consumer(
            builder: (context, ref, child) {
              actionContext = context;
              widgetRef = ref;
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
        GoRoute(
          path: Routes.chat,
          builder: (context, state) => const Scaffold(body: SizedBox.shrink()),
        ),
      ],
    );
    addTearDown(router.dispose);
    NavigationService.attachRouter(router);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await openHermesSession(
      actionContext,
      widgetRef,
      const HermesSessionSummary(
        id: 'session-with-document',
        title: 'Saved session',
      ),
    );
    await tester.pumpAndSettle();

    final message = container.read(activeConversationProvider)!.messages.single;
    check(message.content).equals('Summarize.');
    check(message.files!.single['id']).equals(document.id);
  });
}

class _FakeHermesApiService extends HermesApiService {
  _FakeHermesApiService({
    this.messages = const <Map<String, dynamic>>[
      <String, dynamic>{'role': 'assistant', 'content': 'Saved response'},
    ],
    this.deleteGate,
    this.messagesGate,
  }) : super(
         config: const HermesConfig(
           enabled: true,
           baseUrl: 'https://hermes.example',
           apiKey: 'test-key',
         ),
       );

  final List<Map<String, dynamic>> messages;
  final Completer<void>? deleteGate;
  final Completer<void>? messagesGate;
  final deleteStarted = Completer<void>();
  final messagesStarted = Completer<void>();
  final List<String> deletedSessionIds = [];
  final List<String> operationLog = [];

  @override
  Future<List<Map<String, dynamic>>> listSessions() async => const [];

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) async {
    operationLog.add('get:$id');
    if (!messagesStarted.isCompleted) messagesStarted.complete();
    await messagesGate?.future;
    return messages;
  }

  @override
  Future<void> deleteSession(String id, {CancelToken? cancelToken}) async {
    deletedSessionIds.add(id);
    operationLog.add('delete-start:$id');
    if (!deleteStarted.isCompleted) deleteStarted.complete();
    await deleteGate?.future;
    operationLog.add('delete-complete:$id');
  }
}

class _SeededActiveConversation extends ActiveConversationNotifier {
  _SeededActiveConversation(this.initialConversation);

  final Conversation initialConversation;

  @override
  Conversation? build() => initialConversation;
}

class _FixedHermesConfigController extends HermesConfigController {
  _FixedHermesConfigController(this.initialConfig);

  final HermesConfig initialConfig;

  @override
  HermesConfig build() => initialConfig;
}

class _SeededSelectedModel extends SelectedModel {
  _SeededSelectedModel(this.initialModel);

  final Model initialModel;

  @override
  Model? build() => initialModel;
}

class _TestModels extends Models {
  _TestModels(this.models);

  final List<Model> models;

  @override
  Future<List<Model>> build() async => models;
}

class _FailingModels extends Models {
  @override
  Future<List<Model>> build() async => throw StateError('models unavailable');
}
