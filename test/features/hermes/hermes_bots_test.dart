import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_bot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('projects a bot roster row', () {
    final bot = HermesBot.fromJson({
      'name': 'researcher',
      'description': 'Reads papers',
      'has_avatar': true,
      'ui_meta': {
        'hermes-bots': {'title': 'Research', 'chat': 'session-7'},
      },
      'last_session': {
        'preview': 'Found three candidates',
        'last_active': 1700000000,
      },
    });

    check(bot).isNotNull();
    check(bot!.name).equals('researcher');
    check(bot.title).equals('Research');
    check(bot.chatSessionId).equals('session-7');
    check(bot.preview).equals('Found three candidates');
    check(bot.hasAvatar).isTrue();
    check(bot.lastActive).isNotNull();
  });

  test('falls back to the profile name and tolerates missing meta', () {
    final bot = HermesBot.fromJson({'name': 'default'});

    check(bot).isNotNull();
    check(bot!.title).equals('default');
    check(bot.chatSessionId).isNull();
    check(bot.preview).isNull();
    check(bot.hasAvatar).isFalse();
  });

  test('rejects rows that cannot scope an RPC profile', () {
    // The name is interpolated into `profile` params; only valid profile ids
    // may become a bot.
    check(HermesBot.fromJson({'name': '../escape'})).isNull();
    check(HermesBot.fromJson({'name': 'Upper'})).isNull();
    check(HermesBot.fromJson({'name': ''})).isNull();
    check(HermesBot.fromJson(const {})).isNull();
  });

  test('ignores a hostile pinned chat id instead of routing to it', () {
    final bot = HermesBot.fromJson({
      'name': 'bot',
      'ui_meta': {
        'hermes-bots': {'chat': '../../etc/passwd'},
      },
    });

    check(bot).isNotNull();
    check(bot!.chatSessionId).isNull();
  });

  test('parses a real pre-Bot-Mode profiles.list row (Hermes 0.20.1)', () {
    // Captured verbatim from a live gateway that predates Bot Mode: no
    // ui_meta, no bot_mode_protocol flag. The row still has to parse, because
    // the same shape is what a Bot-Mode gateway returns for an un-themed bot.
    final bot = HermesBot.fromJson({
      'name': 'default',
      'path': '/data/.hermes',
      'is_default': true,
      'model': 'openai/gpt-5.5',
      'provider': 'auto',
      'description': '',
      'skill_count': 36,
      'last_session': {
        'id': '20260818_064357_f15a11',
        'title': 'Show approval prompt',
        'preview': 'Can you show me an approval prompt',
        'started_at': 1787035437.2407894,
        'last_active': 1787035453.3102949,
        'message_count': 4,
      },
      'has_avatar': false,
    });

    check(bot).isNotNull();
    check(bot!.name).equals('default');
    check(bot.title).equals('default');
    check(bot.description).isNull();
    check(bot.chatSessionId).isNull();
    check(bot.preview).equals('Can you show me an approval prompt');
    check(bot.hasAvatar).isFalse();
    check(bot.lastActive).isNotNull();
  });

  test('prefers the caller-pinned session over the newest one', () {
    final bot = HermesBot.fromJson({
      'name': 'bot',
      'preferred_session': {'preview': 'pinned chat'},
      'last_session': {'preview': 'some other chat'},
    });

    check(bot!.preview).equals('pinned chat');
  });
}
