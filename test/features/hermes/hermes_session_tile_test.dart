import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/models/hermes_session.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/widgets/hermes_session_tile.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
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
}

class _FakeHermesApiService extends HermesApiService {
  _FakeHermesApiService()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'test-key',
        ),
      );

  final List<String> deletedSessionIds = [];

  @override
  Future<List<Map<String, dynamic>>> listSessions() async => const [];

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(String id) async => [
    {'role': 'assistant', 'content': 'Saved response'},
  ];

  @override
  Future<void> deleteSession(String id, {CancelToken? cancelToken}) async {
    deletedSessionIds.add(id);
  }
}

class _SeededActiveConversation extends ActiveConversationNotifier {
  _SeededActiveConversation(this.initialConversation);

  final Conversation initialConversation;

  @override
  Conversation? build() => initialConversation;
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
