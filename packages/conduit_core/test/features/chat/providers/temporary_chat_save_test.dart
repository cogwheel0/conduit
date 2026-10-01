import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/temporary_chat_save.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

ChatMessage _message(String role, String content) => ChatMessage(
  id: '$role-${content.length}',
  role: role,
  content: content,
  timestamp: DateTime(2026),
);

void main() {
  group('temporaryChatTitle', () {
    test('uses the first user message', () {
      check(
        temporaryChatTitle([
          _message('assistant', 'Hello there'),
          _message('user', 'Plan my week'),
        ]),
      ).equals('Plan my week');
    });

    test('cuts long messages at 50 characters', () {
      final long = 'x' * 60;
      check(temporaryChatTitle([_message('user', long)]))
          .equals('${'x' * 50}...');
    });

    test('falls back to the first message, then New Chat', () {
      check(temporaryChatTitle([_message('assistant', 'Only reply')]))
          .equals('Only reply');
      check(temporaryChatTitle([_message('user', '')])).equals('New Chat');
      check(temporaryChatTitle(const [])).equals('New Chat');
    });
  });
}
