import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:conduit/features/hermes/models/hermes_bot.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/model_avatar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('shouldShowChatModelDropdown', () {
    test('keeps switching available for Hermes in a mixed setup', () {
      check(
        shouldShowChatModelDropdown(
          selectedModel: hermesSyntheticModel(),
          isHermesOnly: false,
        ),
      ).isTrue();
    });

    test('hides switching for the single-agent Hermes-only setup', () {
      check(
        shouldShowChatModelDropdown(
          selectedModel: hermesSyntheticModel(),
          isHermesOnly: true,
        ),
      ).isFalse();
    });

    test('hides switching for a bot in a mixed setup', () {
      check(
        shouldShowChatModelDropdown(
          selectedModel: hermesSyntheticModel(),
          isHermesOnly: false,
          isHermesBot: true,
        ),
      ).isFalse();
    });

    test('shows switching for OpenWebUI or an empty selection', () {
      const openWebUiModel = Model(id: 'gpt', name: 'GPT');

      check(
        shouldShowChatModelDropdown(
          selectedModel: openWebUiModel,
          isHermesOnly: true,
        ),
      ).isTrue();
      check(
        shouldShowChatModelDropdown(selectedModel: null, isHermesOnly: true),
      ).isTrue();
    });
  });

  test('temporary chat action is hidden for Hermes', () {
    check(
      shouldShowTemporaryChatAction(isHermes: true, activeConversation: null),
    ).isFalse();
    check(
      shouldShowTemporaryChatAction(isHermes: false, activeConversation: null),
    ).isTrue();
  });

  test('bot chat uses its bot title in the model pill', () {
    const avatar = 'data:image/png;base64,YQ==';
    final now = DateTime(2026);
    final conversation = markNativeHermesConversation(
      Conversation(
        id: 'local:hermes_bot',
        title: 'Bot Chat',
        createdAt: now,
        updatedAt: now,
        metadata: const {
          kHermesBotTitleMetadataKey: 'Research',
          kHermesBotAvatarMetadataKey: avatar,
        },
      ),
    );

    check(chatHermesBotTitle(conversation)).equals('Research');
    check(chatHermesBotPresentation(conversation)?.avatar).equals(avatar);
    check(
      chatHermesBotTitle(
        conversation.copyWith(metadata: conversation.metadata),
      ),
    ).isNull();
  });

  test('bot chat uses the bot identity for assistant headers', () {
    const avatar = 'data:image/png;base64,YQ==';
    final summary = debugBuildChatListLayoutSummaryForTesting(
      [
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'Hello',
          timestamp: DateTime(2026),
          model: kHermesDefaultModelId,
        ),
      ],
      models: [hermesSyntheticModel()],
      hermesBot: (
        title: 'Research',
        avatar: avatar,
        shape: 'squircle',
        color: '#8b5cf6',
        imageKind: 'photo',
      ),
    );

    check(summary.single.displayModelName).equals('Research');
    check(summary.single.modelIconUrl).equals(avatar);
  });

  testWidgets('bot chat toolbar shows its avatar, name, and activity', (
    tester,
  ) async {
    const avatar =
        'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: debugBuildHermesBotToolbarTitleForTesting(
              bot: (
                title: 'Research',
                avatar: avatar,
                shape: 'squircle',
                color: '#8b5cf6',
                imageKind: 'shape',
              ),
              maxWidth: 240,
              active: true,
            ),
          ),
        ),
      ),
    );

    check(find.text('Research').evaluate().length).equals(1);
    final modelAvatar = tester.widget<ModelAvatar>(
      find.descendant(
        of: find.byKey(const ValueKey('hermes-bot-toolbar-avatar')),
        matching: find.byType(ModelAvatar),
      ),
    );
    check(modelAvatar.imageUrl).equals(avatar);
    check(
      find.byKey(const ValueKey('hermes-bot-activity-dot')).evaluate().length,
    ).equals(1);
    check(
      tester.widget<FadeTransition>(find.byType(FadeTransition)).opacity.value,
    ).equals(1);
  });

  group('chatLocalFilePickerExtensions', () {
    test('filters Hermes to supported local documents without PDF', () {
      final extensions = chatLocalFilePickerExtensions(hermesSyntheticModel())!;

      check(extensions).contains('txt');
      check(extensions).contains('docx');
      check(extensions).not((it) => it.contains('pdf'));
    });

    test('leaves Desktop Hermes picker unrestricted', () {
      check(
        chatLocalFilePickerExtensions(
          hermesSyntheticModel(),
          desktopHermes: true,
        ),
      ).isNull();
    });

    test('leaves the OpenWebUI picker unrestricted', () {
      const openWebUiModel = Model(id: 'gpt', name: 'GPT');

      check(chatLocalFilePickerExtensions(openWebUiModel)).isNull();
      check(chatLocalFilePickerExtensions(null)).isNull();
    });
  });
}
