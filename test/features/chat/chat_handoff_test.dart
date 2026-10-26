import 'package:conduit/features/chat/services/chat_handoff_prompt.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/services/flutter_ui_requests.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_handoff_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _general = Model(id: 'general', name: 'General');
const _coder = Model(id: 'coder', name: 'Code Assistant');

void main() {
  testWidgets('the native question names the model and returns the answer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: NavigationService.navigatorKey,
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(),
      ),
    );

    for (final (button, answer) in [
      ('Stay here', false),
      ('Start new chat', true),
    ]) {
      final asked = confirmChatHandoff(
        const FlutterUiRequests(),
        'Code Assistant',
      );
      await tester.pumpAndSettle();
      expect(find.text('Switch to Code Assistant?'), findsOneWidget);
      expect(
        find.text(
          'Your server suggests continuing in a new chat with Code '
          'Assistant. Any suggested message waits in the composer until '
          'you send it.',
        ),
        findsOneWidget,
      );

      // A stray tap outside is not an answer.
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Switch to Code Assistant?'), findsOneWidget);

      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(await asked, answer);
      expect(find.text('Switch to Code Assistant?'), findsNothing);
    }
  });

  testWidgets('agreeing fills a new chat composer and sends nothing', (
    tester,
  ) async {
    final sent = <String>[];
    final container = await _pumpChat(tester, onSend: sent.add);
    final reply = container
        .read(chatHandoffCoordinatorProvider)
        .handle(
          chatId: 'chat-1',
          messageId: 'message-1',
          data: const {'model_id': 'coder', 'prompt': 'Review this diff'},
        );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start new chat'));
    await tester.pumpAndSettle();

    expect(await reply, {'handled': true});
    expect(_composerText(tester), 'Review this diff');
    expect(sent, isEmpty);
    expect(container.read(activeConversationProvider), isNull);
    expect(container.read(chatMessagesProvider), isEmpty);
    expect(container.read(selectedModelProvider), _coder);
  });

  testWidgets('declining leaves the chat and composer as they were', (
    tester,
  ) async {
    final sent = <String>[];
    final container = await _pumpChat(tester, onSend: sent.add);
    await tester.enterText(find.byType(TextField), 'My own draft');
    final reply = container
        .read(chatHandoffCoordinatorProvider)
        .handle(
          chatId: 'chat-1',
          messageId: 'message-1',
          data: const {'model_id': 'coder', 'prompt': 'Review this diff'},
        );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Stay here'));
    await tester.pumpAndSettle();

    expect(await reply, {'handled': false, 'reason': 'declined'});
    expect(_composerText(tester), 'My own draft');
    expect(sent, isEmpty);
    expect(container.read(activeConversationProvider)?.id, 'chat-1');
    expect(container.read(selectedModelProvider), _general);
  });
}

String _composerText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

/// The composer on chat-1 with General selected, answering handoffs with the
/// app's own question and opener.
Future<ProviderContainer> _pumpChat(
  WidgetTester tester, {
  required ValueChanged<String> onSend,
}) async {
  final api = _Api();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedModelProvider.overrideWith(_SeededSelectedModel.new),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        apiServiceProvider.overrideWithValue(api),
        authTokenProvider3.overrideWithValue('token'),
        isAuthenticatedProvider2.overrideWithValue(true),
        appSettingsProvider.overrideWith(_Settings.new),
        isChatStreamingProvider.overrideWithValue(false),
        webSearchAvailableProvider.overrideWithValue(false),
        imageGenerationAvailableProvider.overrideWithValue(false),
        temporaryChatEnforcedProvider.overrideWithValue(false),
        userPermissionsProvider.overrideWith((ref) async => const {}),
        chatHandoffCoordinatorProvider.overrideWith(
          (ref) => ChatHandoffCoordinator(
            isActiveChat: (chatId) =>
                ref.read(activeConversationProvider)?.id == chatId,
            findModel: (modelId) =>
                openWebUiHandoffModel(const [_general, _coder], modelId),
            confirm: (modelName) =>
                confirmChatHandoff(const FlutterUiRequests(), modelName),
            open: (model, prompt) => openChatHandoff(ref, model, prompt),
          ),
        ),
      ],
      child: MaterialApp(
        navigatorKey: NavigationService.navigatorKey,
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ModernChatInput(onSendMessage: onSend)),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(
    tester.element(find.byType(ModernChatInput)),
  );
}

final class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(sendOnEnter: true);
}

final class _SeededSelectedModel extends SelectedModel {
  @override
  Model build() => _general;
}

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'chat-1',
    title: 'Routing',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

final class _Api extends ApiService {
  _Api()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      const <String, dynamic>{};
}
