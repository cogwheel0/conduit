import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
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
  List<ChatMessage> build() => const <ChatMessage>[];
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

class _Voice extends ChatVoiceModeController {
  @override
  ChatVoiceModeSnapshot build() => const ChatVoiceModeSnapshot(
    phase: ChatVoiceModePhase.idle,
    isCollapsed: true,
  );
}

void main() {
  testWidgets('the new chat greets with a bold Title 1 line that fades out '
      'the moment Send is tapped, and comes back if nothing is sent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(
          ApiService(
            serverConfig: const ServerConfig(
              id: 'greeting',
              name: 'Example server',
              url: 'https://greeting.example.test',
            ),
            workerManager: WorkerManager(),
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
        chatVoiceModeControllerProvider.overrideWith(_Voice.new),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat)
              .copyWith(platform: TargetPlatform.iOS),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final emptyState = find.byKey(
      const ValueKey('chat-empty-state-scroll-view'),
    );
    expect(emptyState, findsOneWidget);
    // Title 1: 28 pt, bold, as the large titles are.
    final greeting = tester
        .widgetList<Text>(
          find.descendant(of: emptyState, matching: find.byType(Text)),
        )
        .firstWhere((text) => text.style?.fontSize == 28);
    expect(greeting.style!.fontWeight, FontWeight.w700);

    double presence() => tester
        .widget<FadeTransition>(
          find
              .ancestor(of: emptyState, matching: find.byType(FadeTransition))
              .first,
        )
        .opacity
        .value;
    expect(presence(), 1);

    // Send is tapped: the greeting is gone within a tenth of a second,
    // before a message leaving the composer could reach it.
    tester
        .widget<ModernChatInput>(find.byType(ModernChatInput))
        .onSendStarted!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(presence(), 0);

    // Nothing was sent after all: the greeting comes back.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(presence(), 1);
  });
}
