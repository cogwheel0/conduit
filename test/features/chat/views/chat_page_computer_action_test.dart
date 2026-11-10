import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/terminal/widgets/computer_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'model-1', name: 'Model 1'),
  ];
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const <Folder>[];
}

class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[];
}

class _SelectedModel extends SelectedModel {
  @override
  Model? build() => const Model(id: 'model-1', name: 'Model 1');
}

class _Active extends ActiveConversationNotifier {
  _Active(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const <ChatMessage>[];
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

ApiService _api() => ApiService(
  serverConfig: const ServerConfig(
    id: 'page',
    name: 'page',
    url: 'https://page.example.test',
  ),
  workerManager: WorkerManager(),
);

Conversation _chat() => withChatStorageProvenance(
  Conversation(
    id: 'stored-chat',
    title: 'A chat',
    createdAt: DateTime.utc(2026, 7, 13),
    updatedAt: DateTime.utc(2026, 7, 13),
  ),
  ChatStorageKind.openWebUi,
);

class _Computer extends Mock implements ComputerService {}

void main() {
  setUpAll(() => registerFallbackValue(ComputerSurface.desktop));

  for (final available in [false, true]) {
    testWidgets(
      'the header opens the Computer only when the chat terminal offers one '
      '(available: $available)',
      (tester) async {
        final service = _Computer();
        // The viewer is still connecting when the test looks at it.
        when(() => service.open(any()))
            .thenAnswer((_) => Completer<ComputerConnection?>().future);
        final originalErrorWidgetBuilder = ErrorWidget.builder;
        final originalFlutterErrorOnError = FlutterError.onError;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          ErrorWidget.builder = originalErrorWidgetBuilder;
          FlutterError.onError = originalFlutterErrorOnError;
        });
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(_Settings.new),
            apiServiceProvider.overrideWithValue(_api()),
            appDatabaseProvider.overrideWith((ref) => null),
            isAuthenticatedProvider2.overrideWithValue(false),
            reviewerModeProvider.overrideWithValue(false),
            selectedModelProvider.overrideWith(_SelectedModel.new),
            activeConversationProvider.overrideWith(() => _Active(_chat())),
            chatMessagesProvider.overrideWith(_Messages.new),
            optimizedStorageServiceProvider.overrideWithValue(_Storage()),
            isChatStreamingProvider.overrideWith((ref) => false),
            conversationsProvider.overrideWith(_Conversations.new),
            modelsProvider.overrideWith(_Models.new),
            foldersProvider.overrideWith(_Folders.new),
            toolsListProvider.overrideWith(_Tools.new),
            currentUserProvider2.overrideWithValue(
              const User(
                id: 'me',
                username: 'me',
                email: 'me@example.test',
                role: 'user',
              ),
            ),
            computerAvailableProvider.overrideWithValue(available),
            computerServiceProvider.overrideWith((ref) async => service),
            computerCapabilitiesProvider.overrideWith(
              (ref) async => const ComputerCapabilities(desktop: true),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.listen(computerServiceProvider, (_, _) {});
        container.listen(computerCapabilitiesProvider, (_, _) {});
        await container.read(computerCapabilitiesProvider.future);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(TweakcnThemes.t3Chat),
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const ChatPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final button = find.byKey(const ValueKey('chat-computer-button'));
        if (!available) {
          expect(button, findsNothing);
          return;
        }
        expect(find.bySemanticsLabel('Computer'), findsOneWidget);
        // The outline display, in the header glyphs' outline family; not the
        // filled desktopcomputer screen.
        check(
          tester.widget<ConduitAdaptiveAppBarIconButton>(button).iosSymbol,
        ).equals('display');
        await tester.tap(button);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(find.byType(ComputerPage), findsOneWidget);
        verify(() => service.open(ComputerSurface.desktop)).called(1);
      },
    );
  }
}
