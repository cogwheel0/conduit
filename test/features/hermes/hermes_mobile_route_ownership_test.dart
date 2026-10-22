import 'dart:async';

import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_route_stack.dart';
import 'package:conduit/features/hermes/widgets/hermes_mobile_shell.dart';
import 'package:conduit/features/hermes/widgets/hermes_conversation_stage.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Sessions extends HermesSessionsController {
  @override
  Future<List<HermesSessionSummary>> build() async => const [
    HermesSessionSummary(id: 'one', title: 'Conversation one'),
  ];
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];
}

class _BackendSelection extends Notifier<HermesBackendService?> {
  @override
  HermesBackendService? build() => null;
  void select(HermesBackendService backend) => state = backend;
}

final _backendSelectionProvider =
    NotifierProvider<_BackendSelection, HermesBackendService?>(
      _BackendSelection.new,
    );

class _ReplacementBackend extends Fake implements HermesBackendService {
  @override
  final config = const HermesConfig(
    enabled: true,
    baseUrl: 'http://replacement.invalid',
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final panel in ['tool activity', 'bot workspace']) {
    testWidgets(
      'Android Back dismisses nested $panel before the conversation',
      (tester) async {
        final container = await _pump(tester);
        await tester.tap(find.text('Open $panel'));
        await tester.pumpAndSettle();
        expect(find.text('Visible $panel'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Visible $panel'), findsNothing);
        expect(
          container.read(hermesMobileNavigationProvider).conversation,
          isTrue,
        );
        expect(find.text('Conversation one'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          container.read(hermesMobileNavigationProvider).conversation,
          isFalse,
        );
        expect(
          find.byKey(const ValueKey('messages-tab-chats')),
          findsOneWidget,
        );
        // The retained child navigator cannot resurrect its dismissed panel.
        container
            .read(hermesMobileNavigationProvider.notifier)
            .showConversation();
        await tester.pumpAndSettle();
        expect(find.text('Visible $panel'), findsNothing);
        expect(find.text('Conversation one'), findsOneWidget);
      },
    );
  }

  for (final change in ['section', 'conversation', 'draft']) {
    testWidgets(
      '$change changes clear nested panels and retain the chat state',
      (tester) async {
        final container = await _pump(tester);
        await tester.enterText(
          find.byKey(const ValueKey('draft-input')),
          'Unsent',
        );
        await tester.tap(find.text('Open bot workspace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open workspace sheet'));
        await tester.pumpAndSettle();
        final navigation = container.read(
          hermesMobileNavigationProvider.notifier,
        );
        switch (change) {
          case 'section':
            navigation.select(HermesWorkArea.files);
            await tester.pumpAndSettle();
            navigation.showConversation();
          case 'conversation':
            container
                .read(activeConversationProvider.notifier)
                .set(_conversation('two'));
          case 'draft':
            navigation.newConversation();
        }
        await tester.pumpAndSettle();
        expect(find.text('Visible workspace sheet'), findsNothing);
        expect(find.text('Visible bot workspace'), findsNothing);
        expect(
          find.text(
            change == 'conversation' ? 'Conversation two' : 'Conversation one',
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('draft-input')))
              .controller!
              .text,
          'Unsent',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'configuration footer is above navigation and Cancel keeps the conversation',
    (tester) async {
      final container = await _pump(tester);
      await tester.tap(find.text('Open configuration'));
      await tester.pumpAndSettle();
      final footer = find.byKey(const ValueKey('configuration-cancel'));
      expect(footer, findsOneWidget);
      await tester.tap(footer);
      await tester.pumpAndSettle();
      expect(footer, findsNothing);
      expect(
        container.read(hermesMobileNavigationProvider).conversation,
        isTrue,
      );
      expect(
        container.read(hermesMobileNavigationProvider).area,
        HermesWorkArea.chat,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['section', 'conversation', 'draft', 'backend']) {
    testWidgets(
      '$change changes dismiss a root bot editor with its workspace',
      (tester) async {
        final container = await _pump(tester);
        await tester.tap(find.text('Open bot workspace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open identity editor'));
        await tester.pumpAndSettle();
        expect(find.text('Visible identity editor'), findsOneWidget);

        final navigation = container.read(
          hermesMobileNavigationProvider.notifier,
        );
        switch (change) {
          case 'section':
            navigation.select(HermesWorkArea.files);
            await tester.pumpAndSettle();
            navigation.showConversation();
          case 'conversation':
            container
                .read(activeConversationProvider.notifier)
                .set(_conversation('two'));
          case 'draft':
            navigation.newConversation();
          case 'backend':
            container
                .read(_backendSelectionProvider.notifier)
                .select(_ReplacementBackend());
        }
        await tester.pumpAndSettle();
        expect(find.text('Visible identity editor'), findsNothing);
        expect(find.text('Visible bot workspace'), findsNothing);
        expect(
          find.text(
            change == 'conversation' ? 'Conversation two' : 'Conversation one',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'notification owner change preserves a newer unrelated root route',
    (tester) async {
      final container = await _pump(tester);
      await tester.tap(find.text('Open bot workspace'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open identity editor'));
      await tester.pumpAndSettle();
      final root = Navigator.of(
        tester.element(find.text('Visible identity editor')),
        rootNavigator: true,
      );
      unawaited(
        root.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('New root destination')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Completion notification navigation replaces the active conversation.
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('two'));
      await tester.pumpAndSettle();
      expect(find.text('New root destination'), findsOneWidget);
      root.pop();
      await tester.pumpAndSettle();
      expect(find.text('Visible identity editor'), findsNothing);
      expect(find.text('Visible bot workspace'), findsNothing);
      expect(find.text('Conversation two'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'owner change before modal registration never builds the old editor',
    (tester) async {
      await _pump(tester);
      final content = tester.state<_ContentState>(
        find.byType(_ConversationContent),
      );
      await tester.tap(find.text('Open stale configuration'));
      await tester.pumpAndSettle();
      expect(content.staleEditorBuilds, 0);
      expect(find.text('Stale configuration'), findsNothing);
      expect(find.text('Conversation two'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving the shell removes its root bot editor', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Open bot workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open identity editor'));
    await tester.pumpAndSettle();
    final router = GoRouter.of(
      tester.element(find.text('Visible bot workspace', skipOffstage: false)),
    );
    router.go('/outside');
    await tester.pumpAndSettle();
    expect(find.text('Outside shell'), findsOneWidget);
    expect(find.text('Visible identity editor'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('root route Back delegates to the child sheet', (tester) async {
    final container = await _pump(tester);
    await tester.tap(find.text('Open tool activity'));
    await tester.pumpAndSettle();
    await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Visible tool activity'), findsNothing);
    expect(container.read(hermesMobileNavigationProvider).conversation, isTrue);
  });

  testWidgets('leaving and reentering the shell retains its new base route', (
    tester,
  ) async {
    final container = await _pump(tester);
    final router = GoRouter.of(tester.element(find.text('Open bot workspace')));
    router.go('/outside');
    await tester.pumpAndSettle();
    expect(find.text('Outside shell'), findsOneWidget);
    router.go('/chat');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open tool activity'));
    await tester.pumpAndSettle();
    container.read(hermesMobileNavigationProvider.notifier).newConversation();
    await tester.pumpAndSettle();
    expect(find.text('Visible tool activity'), findsNothing);
    expect(find.text('Conversation one'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a nested pop guard consumes Back without leaving its conversation',
    (tester) async {
      final container = await _pump(tester);
      final stack = container.read(hermesMobileRouteStackProvider);
      var guarded = 0;
      unawaited(
        stack.navigatorKey.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => PopScope(
              canPop: false,
              onPopInvokedWithResult: (_, _) => guarded++,
              child: const Scaffold(body: Text('Guarded workspace')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(guarded, 1);
      expect(find.text('Guarded workspace'), findsOneWidget);
      expect(
        container.read(hermesMobileNavigationProvider).conversation,
        isTrue,
      );
      container
          .read(hermesMobileNavigationProvider.notifier)
          .select(HermesWorkArea.files);
      await tester.pumpAndSettle();
      container
          .read(hermesMobileNavigationProvider.notifier)
          .showConversation();
      await tester.pumpAndSettle();
      expect(find.text('Guarded workspace'), findsNothing);
    },
  );

  testWidgets('nested panel owns predictive Back before the stage reveal', (
    tester,
  ) async {
    final container = await _pump(tester, conversation: false);
    final row = tester.element(find.text('Conversation one'));
    final link = HermesConversationLinkScope.read(row)!;
    link.begin('one', 'Conversation one', 1);
    link.finish(1, resolved: true);
    container.read(hermesMobileNavigationProvider.notifier).showConversation();
    await tester.pumpAndSettle();
    final stage = tester.state(
      find.byType(HermesConversationStage),
    ) as WidgetsBindingObserver;
    final gesture = PredictiveBackEvent.fromMap({
      'progress': 0.0,
      'swipeEdge': 0,
    });
    // Establish that this fixture has valid geometry for a conversation reveal.
    expect(stage.handleStartBackGesture(gesture), isTrue);
    stage.handleCancelBackGesture();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open tool activity'));
    await tester.pumpAndSettle();
    expect(stage.handleStartBackGesture(gesture), isFalse);
  });
}

Conversation _conversation(String id) => Conversation(
  id: 'local:$id',
  title: 'Conversation $id',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  metadata: {'hermesSessionId': id},
);

class _ConversationContent extends ConsumerStatefulWidget {
  const _ConversationContent();
  @override
  ConsumerState<_ConversationContent> createState() => _ContentState();
}

class _ContentState extends ConsumerState<_ConversationContent> {
  final draft = TextEditingController();
  int staleEditorBuilds = 0;
  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        HermesConversationHeaderTitle(
          id:
              ref.watch(activeConversationProvider)!.metadata['hermesSessionId']
                  as String?,
          child: Text(ref.watch(activeConversationProvider)!.title),
        ),
        TextField(key: const ValueKey('draft-input'), controller: draft),
        TextButton(
          onPressed: () => unawaited(
            showCompactConfigurationSheet<void>(
              context,
              (sheetContext) => SizedBox(
                height: 160,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: TextButton(
                    key: const ValueKey('configuration-cancel'),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
            ),
          ),
          child: const Text('Open configuration'),
        ),
        TextButton(
          onPressed: () {
            unawaited(
              showCompactConfigurationSheet<void>(context, (_) {
                staleEditorBuilds++;
                return const Text('Stale configuration');
              }),
            );
            ref
                .read(activeConversationProvider.notifier)
                .set(_conversation('two'));
          },
          child: const Text('Open stale configuration'),
        ),
        TextButton(
          onPressed: () => unawaited(
            ThemedSheets.showSurface<void>(
              context: context,
              builder: (_) => const Text('Visible tool activity'),
            ),
          ),
          child: const Text('Open tool activity'),
        ),
        TextButton(
          onPressed: () => unawaited(
            Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (context) => Scaffold(
                  body: Column(
                    children: [
                      const Text('Visible bot workspace'),
                      TextButton(
                        onPressed: () => unawaited(
                          showCompactConfigurationSheet<void>(
                            context,
                            (_) => const SizedBox(
                              height: 180,
                              child: Text('Visible identity editor'),
                            ),
                          ),
                        ),
                        child: const Text('Open identity editor'),
                      ),
                      TextButton(
                        onPressed: () => unawaited(
                          ThemedSheets.showSurface<void>(
                            context: context,
                            builder: (_) =>
                                const Text('Visible workspace sheet'),
                          ),
                        ),
                        child: const Text('Open workspace sheet'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          child: const Text('Open bot workspace'),
        ),
      ],
    ),
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  bool conversation = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      hermesMobileLayoutProvider.overrideWithValue(true),
      apiServiceProvider.overrideWithValue(null),
      hermesApiServiceProvider.overrideWith(
        (ref) => ref.watch(_backendSelectionProvider),
      ),
      hermesBotsProvider.overrideWith((_) async => const <HermesBot>[]),
      hermesSessionsProvider.overrideWith(_Sessions.new),
      chatMessagesProvider.overrideWith(_Messages.new),
      hermesCapabilitiesProvider.overrideWith(
        (_) async => const HermesCapabilities(),
      ),
      isChatStreamingProvider.overrideWithValue(false),
    ],
  );
  container.read(activeConversationProvider.notifier).set(_conversation('one'));
  if (conversation) {
    container.read(hermesMobileNavigationProvider.notifier).showConversation();
  }
  final stack = container.read(hermesMobileRouteStackProvider);
  final router = GoRouter(
    initialLocation: '/chat',
    routes: [
      ShellRoute(
        navigatorKey: stack.navigatorKey,
        observers: [stack],
        builder: (_, _, child) => HermesMobileShell(child: child),
        routes: [
          GoRoute(
            path: '/chat',
            builder: (_, _) => const _ConversationContent(),
          ),
        ],
      ),
      GoRoute(
        path: '/outside',
        builder: (_, _) => const Scaffold(body: Text('Outside shell')),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light(TweakcnThemes.conduit),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}
