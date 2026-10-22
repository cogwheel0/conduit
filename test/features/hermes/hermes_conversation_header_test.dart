import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/features/hermes/widgets/hermes_conversation_stage.dart';
import 'package:conduit/features/hermes/widgets/hermes_messages_home.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => [hermesSyntheticModel()];
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const [];
}

class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const [];
}

class _Selected extends SelectedModel {
  @override
  Model? build() => hermesSyntheticModel();
}

class _Active extends ActiveConversationNotifier {
  _Active(this.chat);
  final Conversation chat;
  @override
  Conversation? build() => chat;
}

class _Messages extends ChatMessagesNotifier {
  _Messages(this.messages);
  final List<ChatMessage> messages;
  @override
  List<ChatMessage> build() => messages;
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  for (final reduced in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('regular-chat title remains in the actual header after entry '
          'reduced=$reduced scale=$scale', (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const title = 'Selected conversation with a long descriptive title';
        final at = DateTime(2026, 10, 17);
        final messages = [
          ChatMessage(
            id: 'u',
            role: 'user',
            content: 'A harmless fixture.',
            timestamp: at,
          ),
          ChatMessage(
            id: 'a',
            role: 'assistant',
            content: 'The fixture reply.',
            timestamp: at,
          ),
        ];
        final chat = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes_example',
            title: title,
            createdAt: at,
            updatedAt: at,
            messages: messages,
            metadata: const {'backend': 'hermes', 'hermesSessionId': 'example'},
          ),
        );
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(_Settings.new),
            apiServiceProvider.overrideWithValue(null),
            appDatabaseProvider.overrideWith((_) => null),
            isAuthenticatedProvider2.overrideWithValue(false),
            reviewerModeProvider.overrideWithValue(false),
            selectedModelProvider.overrideWith(_Selected.new),
            activeConversationProvider.overrideWith(() => _Active(chat)),
            chatMessagesProvider.overrideWith(() => _Messages(messages)),
            optimizedStorageServiceProvider.overrideWithValue(_Storage()),
            isChatStreamingProvider.overrideWithValue(false),
            isOnlineProvider.overrideWithValue(true),
            conversationsProvider.overrideWith(_Conversations.new),
            modelsProvider.overrideWith(_Models.new),
            foldersProvider.overrideWith(_Folders.new),
            toolsListProvider.overrideWith(_Tools.new),
            currentUserProvider2.overrideWithValue(
              const User(
                id: 'audit',
                username: 'Audit',
                email: 'audit@example.test',
                role: 'user',
              ),
            ),
            hermesMobileLayoutProvider.overrideWithValue(true),
            hermesApiServiceProvider.overrideWithValue(null),
            hermesCapabilitiesProvider.overrideWith(
              (_) async => const HermesCapabilities(),
            ),
          ],
        );
        addTearDown(container.dispose);
        final logical = ValueNotifier(false);
        addTearDown(logical.dispose);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        });
        container.read(hermesActiveSessionProvider.notifier).set('example');
        container.read(composerAutofocusEnabledProvider.notifier).set(false);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(TweakcnThemes.conduit),
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(390, 844),
                  disableAnimations: reduced,
                  textScaler: TextScaler.linear(scale),
                ),
                child: Material(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: logical,
                    builder: (_, detail, _) => HermesConversationStage(
                      chatArea: true,
                      logicalDetail: detail,
                      selectedId: 'example',
                      history: Builder(
                        builder: (context) => ListView(
                          children: [
                            HermesMessageRow(
                              conversationId: 'example',
                              title: title,
                              onOpen: () async {
                                final link = HermesConversationLinkScope.of(
                                  context,
                                )!;
                                link.begin('example', title, 7);
                                link.finish(7, resolved: true);
                                container
                                    .read(
                                      hermesMobileNavigationProvider.notifier,
                                    )
                                    .showConversation();
                                logical.value = true;
                              },
                            ),
                          ],
                        ),
                      ),
                      detail: const ChatPage(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        await tester.tap(find.text(title));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(tester.takeException(), isNull);
        final carrier = find.byKey(
          const ValueKey('conversation-carrier-example'),
        );
        expect(
          carrier,
          findsNothing,
          reason: 'The entry animation has settled.',
        );
        final header = find.byType(HermesConversationHeaderTitle);
        final headerRect = tester.getRect(header);
        final headerOpacity = tester
            .widget<Opacity>(
              find.descendant(of: header, matching: find.byType(Opacity)).first,
            )
            .opacity;
        final titleInAppBar = find.descendant(
          of: find.byType(AppBar),
          matching: find.text(title),
        );
        expect(
          titleInAppBar,
          findsOneWidget,
          reason:
              'Selected identity must survive entry into the real ChatPage. '
              'Actual header rect=$headerRect, opacity=$headerOpacity. '
              'A zero-sized child is distinct from a stuck animation opacity.',
        );
        expect(headerRect.width, greaterThan(0));
        expect(headerRect.height, greaterThan(0));
      });
    }
  }
}
