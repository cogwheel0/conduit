import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/utils/message_targeting.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message({
  required String id,
  required String role,
  required String content,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    timestamp: DateTime.utc(2026, 4, 24),
  );
}

void main() {
  group('resolveAssistantRegenerationTarget', () {
    test('finds the matching assistant and its preceding user by id', () {
      final messages = [
        _message(id: 'u1', role: 'user', content: 'First prompt'),
        _message(id: 'a1', role: 'assistant', content: 'First answer'),
        _message(id: 'u2', role: 'user', content: 'Second prompt'),
        _message(id: 'a2', role: 'assistant', content: 'Updated answer'),
        _message(id: 'u3', role: 'user', content: 'Third prompt'),
        _message(id: 'a3', role: 'assistant', content: 'Third answer'),
      ];

      final target = resolveAssistantRegenerationTarget(messages, 'a2');

      check(target).isNotNull();
      check(target!.assistantIndex).equals(3);
      check(target.assistantMessage.id).equals('a2');
      check(target.userMessage.id).equals('u2');
    });

    test('returns null when the target assistant has no preceding user', () {
      final messages = [
        _message(id: 'a0', role: 'assistant', content: 'Orphaned answer'),
      ];

      final target = resolveAssistantRegenerationTarget(messages, 'a0');

      check(target).isNull();
    });
  });

  group('truncateMessagesAfterId', () {
    final messages = [
      _message(id: 'u1', role: 'user', content: 'First prompt'),
      _message(id: 'a1', role: 'assistant', content: 'First answer'),
      _message(id: 'u2', role: 'user', content: 'Second prompt'),
      _message(id: 'a2', role: 'assistant', content: 'Second answer'),
      _message(id: 'u3', role: 'user', content: 'Third prompt'),
    ];

    test('keeps the target when includeTarget is true', () {
      final truncated = truncateMessagesAfterId(
        messages,
        'a2',
        includeTarget: true,
      );

      check(
        truncated.map((message) => message.id).toList(),
      ).deepEquals(['u1', 'a1', 'u2', 'a2']);
    });

    test('drops the target when includeTarget is false', () {
      final truncated = truncateMessagesAfterId(
        messages,
        'u2',
        includeTarget: false,
      );

      check(
        truncated.map((message) => message.id).toList(),
      ).deepEquals(['u1', 'a1']);
    });
  });
}
