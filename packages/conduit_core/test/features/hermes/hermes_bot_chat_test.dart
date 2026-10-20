import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/services/hermes_bot_chat.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:test/test.dart';

Conversation _chat(Map<String, Object> metadata, {bool native = true}) {
  final now = DateTime(2026);
  final conversation = Conversation(
    id: 'local:hermes_bot',
    title: 'Bot Chat',
    createdAt: now,
    updatedAt: now,
    metadata: metadata,
  );
  return native ? markNativeHermesConversation(conversation) : conversation;
}

void main() {
  const bot = HermesBot(
    name: 'scout',
    title: 'Scout',
    hasAvatar: true,
    avatarShape: 'cloud',
    avatarColor: '#14b8a6',
    avatarImageKind: 'photo',
  );
  const avatar = 'data:image/png;base64,YQ==';

  test('the metadata round-trips into the chat presentation', () {
    final metadata = hermesBotChatMetadata(bot: bot, avatar: avatar);
    check(metadata).deepEquals({
      kHermesBotTitleMetadataKey: 'Scout',
      kHermesBotAvatarMetadataKey: avatar,
      kHermesBotShapeMetadataKey: 'cloud',
      kHermesBotColorMetadataKey: '#14b8a6',
      kHermesBotImageKindMetadataKey: 'photo',
    });
    check(chatHermesBotPresentation(_chat(metadata))).equals((
      title: 'Scout',
      avatar: avatar,
      shape: 'cloud',
      color: '#14b8a6',
      imageKind: 'photo',
    ));
  });

  test('no bot, no bot metadata', () {
    check(hermesBotChatMetadata()).isEmpty();
    check(hermesBotChatMetadata(avatar: avatar))
        .deepEquals({kHermesBotAvatarMetadataKey: avatar});
  });

  test('only native Hermes chats with a bot title are bot chats', () {
    final metadata = hermesBotChatMetadata(bot: bot, avatar: avatar);
    check(chatHermesBotPresentation(_chat(metadata, native: false))).isNull();
    check(chatHermesBotPresentation(null)).isNull();
    check(chatHermesBotPresentation(_chat({kHermesBotTitleMetadataKey: '  '})))
        .isNull();
  });

  test('defaults the shape and refuses non-image avatars', () {
    final presentation = chatHermesBotPresentation(
      _chat({
        kHermesBotTitleMetadataKey: ' Ledger ',
        kHermesBotAvatarMetadataKey: 'https://tracker.example/pixel.png',
      }),
    );
    check(presentation).equals((
      title: 'Ledger',
      avatar: null,
      shape: 'squircle',
      color: '#8b5cf6',
      imageKind: null,
    ));
  });
}
