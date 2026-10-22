import 'package:test/test.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';

void main() {
  test(
    'Bot Mode uses canonical history instead of the newest regular session',
    () {
      final bot = HermesBot.fromJson({
        'name': 'default',
        'ui_meta': {
          'hermes-bots': {'pinned': true, 'chat': 'regular-chat'},
        },
        'last_session': {
          'id': 'regular-chat',
          'title': 'Website redesign',
          'preview': 'Ordinary reply',
          'last_active': 1791700000,
        },
        'canonical_session': {
          'id': 'dedicated-bot-chat',
          'title': 'Bot Chat',
          'root_title': 'Bot Chat',
          'preview': 'Bot reply',
          'last_active': 1791600000,
        },
      })!;
      expect(bot.title, 'Hermes');
      expect(bot.chatSessionId, 'dedicated-bot-chat');
      expect(bot.preview, 'Bot reply');
      expect(
        bot.lastActive,
        DateTime.fromMillisecondsSinceEpoch(1791600000000),
      );
    },
  );
  test('missing canonical history never borrows regular messages or legacy chat metadata', () {
    final bot = HermesBot.fromJson({
      'name': 'research',
      'ui_meta': {
        'hermes-bots': {'chat': 'ordinary'},
      },
      'last_session': {'id': 'ordinary', 'preview': 'Ordinary reply'},
    })!;
    expect(bot.chatSessionId, isNull);
    expect(bot.preview, isNull);
    expect(bot.lastActive, isNull);
  });
  test('renamed canonical chats keep their Bot Mode classification', () {
    final session = HermesSessionSummary.fromJson({
      'id': 'canonical',
      'title': 'Researcher introduction',
      'root_title': 'Bot Chat',
    })!;
    expect(session.isBotChat, isTrue);
    expect(
      HermesSessionSummary.fromJson({
        'id': 'normal',
        'title': 'Bot Chat',
        'root_title': 'Normal topic',
      })!.isBotChat,
      isFalse,
    );
    expect(
      HermesSessionSummary.fromJson({'id': 'legacy', 'title': 'Bot Chat'})!
          .isBotChat,
      isTrue,
    );
  });
  test('bot display metadata and profile display names take precedence over defaults', () {
    expect(
      HermesBot.fromJson({'name': 'research', 'display_name': 'Researcher'})!
          .title,
      'Researcher',
    );
    expect(
      HermesBot.fromJson({
        'name': 'research',
        'display_name': 'Researcher',
        'ui_meta': {
          'hermes-bots': {'title': 'My researcher'},
        },
      })!.title,
      'My researcher',
    );
  });
}
