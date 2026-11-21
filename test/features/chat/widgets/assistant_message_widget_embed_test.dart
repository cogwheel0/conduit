import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/web_content_embed.dart';
import 'package:conduit/shared/widgets/web_embed_media_player.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/web_embed/web_embed_media_account.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _page =
    '<h3>Clip</h3>'
    '<audio controls title="Morning note" '
    'src="/api/v1/files/a1/content"></audio>';

class _InactiveTts extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _NoMessages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const <ChatMessage>[];
}

final class _Active extends ActiveConversationNotifier {
  _Active(this._conversation);

  final Conversation _conversation;

  @override
  Conversation? build() => _conversation;
}

Conversation _chat(String id) => Conversation(
  id: id,
  title: 'Chat',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// A reply whose tool showed [_page], in [conversation], while an Open WebUI
/// account is signed in.
Future<void> _pumpReply(
  WidgetTester tester,
  Conversation conversation, {
  Map<String, dynamic> metadata = const {},
}) async {
  // A scope of its own for each reply.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        chatMessagesProvider.overrideWith(_NoMessages.new),
        reviewerModeProvider.overrideWithValue(false),
        webEmbedMediaAccountProvider.overrideWithValue(
          WebEmbedMediaAccount(
            server: const ServerConfig(
              id: 'synthetic',
              name: 'Synthetic',
              url: 'https://chat.example.test',
            ),
            session: Object(),
          ),
        ),
        activeConversationProvider.overrideWith(() => _Active(conversation)),
        textToSpeechControllerProvider.overrideWith(_InactiveTts.new),
        streamingHapticsEnabledProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AssistantMessageWidget(
              message: ChatMessage(
                id: 'assistant-embed',
                role: 'assistant',
                content: '',
                timestamp: DateTime(2026),
                metadata: {'responseDone': true, ...metadata},
                embeds: const [
                  {'src': _page},
                ],
              ),
              showFollowUps: false,
              animateOnMount: false,
              onCopy: () {},
              onRegenerate: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

String _framePage(WidgetTester tester) =>
    tester.widget<WebContentFrame>(find.byType(WebContentFrame)).source;

void main() {
  testWidgets("an Open WebUI chat's reply plays its server media itself", (
    tester,
  ) async {
    await _pumpReply(tester, _chat('c1'));

    check(find.byType(WebEmbedMediaPlayer).evaluate()).length.equals(1);
    check(_framePage(tester))
      ..contains('<h3>Clip</h3>')
      ..not((it) => it.contains('/api/v1/files/'));
  });

  testWidgets("another backend's reply keeps its page as written", (
    tester,
  ) async {
    await _pumpReply(tester, _chat('${kHermesSessionConversationIdPrefix}s1'));
    check(find.byType(WebEmbedMediaPlayer).evaluate()).isEmpty();
    check(_framePage(tester)).equals(_page);

    // A reply a direct connection ran, in an Open WebUI chat.
    await _pumpReply(tester, _chat('c1'), metadata: {'transport': 'direct'});
    check(find.byType(WebEmbedMediaPlayer).evaluate()).isEmpty();
    check(_framePage(tester)).equals(_page);

    // A Hermes turn, in an Open WebUI chat.
    await _pumpReply(tester, _chat('c1'), metadata: {'transport': 'hermesRun'});
    check(find.byType(WebEmbedMediaPlayer).evaluate()).isEmpty();
    check(_framePage(tester)).equals(_page);
  });
}
