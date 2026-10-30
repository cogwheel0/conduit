import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/features/chat/widgets/live_connection_button.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => List.generate(
    20,
    (i) => ChatMessage(
      id: 'panel-$i',
      role: i.isEven ? 'user' : 'assistant',
      content: i.isEven ? 'How should I fold panel $i?' : 'Fold the blue strip along its center seam. Align both corners, then press the fold flat. Keep the lower edge level with the board.',
      timestamp: DateTime.utc(2026, 10, 1, 0, i),
      model: 'fixture-model',
    ),
  );
}

class _Active extends ActiveConversationNotifier {
  _Active(this.conversation);
  final Conversation? conversation;
  @override
  Conversation? build() => conversation;
}

class _Temporary extends TemporaryChatEnabled {
  @override
  bool build() => true;
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'fixture-model', name: 'Fixture model'),
  ];
}

class _SelectedModel extends SelectedModel {
  @override
  Model? build() => const Model(id: 'fixture-model', name: 'Fixture model');
}

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const [];
}

class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const [];
}

class _Speech extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _Connectivity extends Fake implements ConnectivityService {
  @override
  Stream<ConnectivityStatus> get statusStream => const Stream.empty();
  @override
  ConnectivityStatus get currentStatus => ConnectivityStatus.online;
  @override
  bool get isOnline => true;
  @override
  bool get isAppForeground => true;
  @override
  int get lastLatencyMs => 0;
}

void main() {
  for (final chatId in [null, 'saved-chat', 'local:paper']) {
    testWidgets(
      'connection warning keeps the model picker at 2x text for $chatId',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
        PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
        addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        final container = ProviderContainer(
          overrides: [
            apiServiceProvider.overrideWithValue(
              ApiService(
                serverConfig: const ServerConfig(
                  id: 'connection',
                  name: 'Example server',
                  url: 'https://connection.example.test',
                ),
                workerManager: WorkerManager(),
              ),
            ),
            if (chatId?.startsWith('local:') == true)
              temporaryChatEnabledProvider.overrideWith(_Temporary.new),
            activeConversationProvider.overrideWith(
              () => _Active(
                chatId == null
                    ? null
                    : Conversation(
                        id: chatId,
                        title: 'Paper folds',
                        createdAt: DateTime.utc(2026),
                        updatedAt: DateTime.utc(2026),
                      ),
              ),
            ),
            appDatabaseProvider.overrideWith((ref) => null),
            connectivityServiceProvider.overrideWithValue(_Connectivity()),
            isAuthenticatedProvider2.overrideWithValue(false),
            reviewerModeProvider.overrideWithValue(false),
            selectedModelProvider.overrideWith(_SelectedModel.new),
            chatMessagesProvider.overrideWith(_Messages.new),
            optimizedStorageServiceProvider.overrideWithValue(_Storage()),
            isChatStreamingProvider.overrideWith((ref) => false),
            conversationsProvider.overrideWith(_Conversations.new),
            modelsProvider.overrideWith(_Models.new),
            foldersProvider.overrideWith(_Folders.new),
            toolsListProvider.overrideWith(_Tools.new),
            textToSpeechControllerProvider.overrideWith(_Speech.new),
            liveConnectionDisconnectedProvider.overrideWith(
              (ref) => Stream.value(true),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(TweakcnThemes.t3Chat)
                  .copyWith(platform: TargetPlatform.iOS),
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const ChatPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('live-connection-retry')),
          findsOneWidget,
        );
        final model = find.byType(ConduitAdaptiveAppBarModelSelector);
        expect(model, findsOneWidget);
        expect(tester.getSize(model).width, greaterThan(0));
        final more = tester.widget<ConduitAdaptiveToolbarOverflowButton<int>>(
          find.byType(ConduitAdaptiveToolbarOverflowButton<int>),
        );
        final labels = more.items.whereType<AdaptivePopupMenuItem<int>>().map(
          (entry) => entry.label,
        );
        expect(labels, contains('New Chat'));
        if (chatId == null) {
          expect(labels, contains('Temporary Chat'));
        } else if (chatId.startsWith('local:')) {
          expect(labels, contains('Save Chat'));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
