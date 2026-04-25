import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/voice_call/application/assistant_turn_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveAssistantTransportDecision', () {
    test('binds the first remote id to the local placeholder', () {
      final decision = resolveAssistantTransportDecision(
        incomingMessageId: 'remote-assistant-id',
        activeAssistantMessageId: 'local-placeholder-id',
        localAssistantMessageId: 'local-placeholder-id',
        boundRemoteAssistantMessageId: null,
        assistantResponseFinalized: false,
        ignoredAssistantMessageIds: const <String>{},
      );

      expect(decision.shouldProcess, isTrue);
      expect(decision.boundRemoteAssistantMessage, isTrue);
      expect(decision.activeAssistantMessageId, 'remote-assistant-id');
      expect(decision.boundRemoteAssistantMessageId, 'remote-assistant-id');
    });

    test('binds the remote id even after an id-less prefix arrived', () {
      final prefixDecision = resolveAssistantTransportDecision(
        incomingMessageId: null,
        activeAssistantMessageId: 'local-placeholder-id',
        localAssistantMessageId: 'local-placeholder-id',
        boundRemoteAssistantMessageId: null,
        assistantResponseFinalized: false,
        ignoredAssistantMessageIds: const <String>{},
      );

      expect(prefixDecision.shouldProcess, isTrue);
      expect(prefixDecision.activeAssistantMessageId, 'local-placeholder-id');

      final decision = resolveAssistantTransportDecision(
        incomingMessageId: 'remote-assistant-id',
        activeAssistantMessageId: prefixDecision.activeAssistantMessageId,
        localAssistantMessageId: 'local-placeholder-id',
        boundRemoteAssistantMessageId:
            prefixDecision.boundRemoteAssistantMessageId,
        assistantResponseFinalized: false,
        ignoredAssistantMessageIds: const <String>{},
      );

      expect(decision.shouldProcess, isTrue);
      expect(decision.boundRemoteAssistantMessage, isTrue);
      expect(decision.activeAssistantMessageId, 'remote-assistant-id');
      expect(decision.boundRemoteAssistantMessageId, 'remote-assistant-id');
    });

    test('ignores message id switches after a remote id is already bound', () {
      final decision = resolveAssistantTransportDecision(
        incomingMessageId: 'different-id',
        activeAssistantMessageId: 'remote-current-id',
        localAssistantMessageId: 'local-placeholder-id',
        boundRemoteAssistantMessageId: 'remote-current-id',
        assistantResponseFinalized: false,
        ignoredAssistantMessageIds: const <String>{},
      );

      expect(decision.shouldProcess, isFalse);
      expect(decision.boundRemoteAssistantMessage, isFalse);
      expect(decision.activeAssistantMessageId, 'remote-current-id');
    });

    test('ignores id-less events after the assistant turn is finalized', () {
      final decision = resolveAssistantTransportDecision(
        incomingMessageId: null,
        activeAssistantMessageId: 'local-placeholder-id',
        localAssistantMessageId: 'local-placeholder-id',
        boundRemoteAssistantMessageId: null,
        assistantResponseFinalized: true,
        ignoredAssistantMessageIds: const <String>{},
      );

      expect(decision.shouldProcess, isFalse);
      expect(decision.boundRemoteAssistantMessage, isFalse);
      expect(decision.activeAssistantMessageId, 'local-placeholder-id');
    });

    test('ignores id-less events once the active turn ids are retired', () {
      final decision = resolveAssistantTransportDecision(
        incomingMessageId: null,
        activeAssistantMessageId: 'remote-current-id',
        localAssistantMessageId: 'local-placeholder-id',
        boundRemoteAssistantMessageId: 'remote-current-id',
        assistantResponseFinalized: false,
        ignoredAssistantMessageIds: const <String>{
          'local-placeholder-id',
          'remote-current-id',
        },
      );

      expect(decision.shouldProcess, isFalse);
      expect(decision.boundRemoteAssistantMessage, isFalse);
      expect(decision.activeAssistantMessageId, 'remote-current-id');
      expect(decision.boundRemoteAssistantMessageId, 'remote-current-id');
    });
  });

  group('resolveAssistantMessageForTurn', () {
    test(
      'falls back to the assistant whose parent matches the active user',
      () {
        final resolved = resolveAssistantMessageForTurn(
          messages: <ChatMessage>[
            _userMessage(id: 'user-1', at: DateTime(2026, 1, 1, 10)),
            _assistantMessage(
              id: 'assistant-old',
              content: 'Older reply',
              at: DateTime(2026, 1, 1, 10, 0, 1),
              parentId: 'user-1',
            ),
            _userMessage(id: 'user-2', at: DateTime(2026, 1, 1, 10, 1)),
            _assistantMessage(
              id: 'assistant-new',
              content: 'Fresh reply',
              at: DateTime(2026, 1, 1, 10, 1, 1),
              parentId: 'user-2',
            ),
          ],
          activeAssistantMessageId: 'missing-placeholder-id',
          activeUserMessageId: 'user-2',
          assistantTurnStartedAt: DateTime(2026, 1, 1, 10, 1),
        );

        expect(resolved?.id, 'assistant-new');
        expect(resolved?.content, 'Fresh reply');
      },
    );

    test('falls back to assistants created after the turn started', () {
      final resolved = resolveAssistantMessageForTurn(
        messages: <ChatMessage>[
          _assistantMessage(
            id: 'assistant-old',
            content: 'Older reply',
            at: DateTime(2026, 1, 1, 10),
          ),
          _assistantMessage(
            id: 'assistant-new',
            content: 'Fresh reply',
            at: DateTime(2026, 1, 1, 10, 0, 10),
          ),
        ],
        activeAssistantMessageId: 'missing-placeholder-id',
        activeUserMessageId: null,
        assistantTurnStartedAt: DateTime(2026, 1, 1, 10, 0, 5),
      );

      expect(resolved?.id, 'assistant-new');
      expect(resolved?.content, 'Fresh reply');
    });
  });

  group('resolveAssistantRecoveryCandidate', () {
    test('prefers the remote reply over stale local placeholder content', () {
      final recovered = resolveAssistantRecoveryCandidate(
        localMessages: <ChatMessage>[
          _userMessage(id: 'user-2', at: DateTime(2026, 1, 1, 10, 1)),
          _assistantMessage(
            id: 'local-placeholder-id',
            content:
                '<details type="tool_calls" done="true">'
                '<summary>Tool Executed</summary></details>',
            at: DateTime(2026, 1, 1, 10, 1, 1),
            parentId: 'user-2',
          ),
        ],
        remoteMessages: <ChatMessage>[
          _userMessage(id: 'user-2', at: DateTime(2026, 1, 1, 10, 1)),
          _assistantMessage(
            id: 'remote-assistant-id',
            content: 'Fresh reply',
            at: DateTime(2026, 1, 1, 10, 1, 5),
            parentId: 'user-2',
          ),
        ],
        activeAssistantMessageId: 'local-placeholder-id',
        activeUserMessageId: 'user-2',
        assistantTurnStartedAt: DateTime(2026, 1, 1, 10, 1),
      );

      expect(recovered.authoritative, isTrue);
      expect(recovered.message?.id, 'remote-assistant-id');
      expect(recovered.message?.content, 'Fresh reply');
    });

    test(
      'falls back to local content when the remote tracked placeholder is empty',
      () {
        final recovered = resolveAssistantRecoveryCandidate(
          localMessages: <ChatMessage>[
            _userMessage(id: 'user-2', at: DateTime(2026, 1, 1, 10, 1)),
            _assistantMessage(
              id: 'local-placeholder-id',
              content: 'Fresh reply',
              at: DateTime(2026, 1, 1, 10, 1, 1),
              parentId: 'user-2',
            ),
          ],
          remoteMessages: <ChatMessage>[
            _userMessage(id: 'user-2', at: DateTime(2026, 1, 1, 10, 1)),
            _assistantMessage(
              id: 'local-placeholder-id',
              content: '',
              at: DateTime(2026, 1, 1, 10, 1, 1),
              parentId: 'user-2',
            ),
          ],
          activeAssistantMessageId: 'local-placeholder-id',
          activeUserMessageId: 'user-2',
          assistantTurnStartedAt: DateTime(2026, 1, 1, 10, 1),
        );

        expect(recovered.authoritative, isFalse);
        expect(recovered.message?.id, 'local-placeholder-id');
        expect(recovered.message?.content, 'Fresh reply');
      },
    );
  });

  group('hasExceededAssistantWaitBudget', () {
    test('measures patience from the last assistant activity', () {
      expect(
        hasExceededAssistantWaitBudget(
          assistantTurnStartedAt: DateTime(2026, 1, 1, 10),
          lastAssistantActivityAt: DateTime(2026, 1, 1, 10, 0, 20),
          now: DateTime(2026, 1, 1, 10, 0, 40),
          patience: const Duration(seconds: 24),
        ),
        isFalse,
      );
    });

    test('falls back to the turn start when no activity was observed', () {
      expect(
        hasExceededAssistantWaitBudget(
          assistantTurnStartedAt: DateTime(2026, 1, 1, 10),
          lastAssistantActivityAt: null,
          now: DateTime(2026, 1, 1, 10, 0, 25),
          patience: const Duration(seconds: 24),
        ),
        isTrue,
      );
    });
  });
}

ChatMessage _userMessage({required String id, required DateTime at}) {
  return ChatMessage(id: id, role: 'user', content: 'Prompt', timestamp: at);
}

ChatMessage _assistantMessage({
  required String id,
  required String content,
  required DateTime at,
  String? parentId,
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: at,
    metadata: parentId == null ? null : <String, dynamic>{'parentId': parentId},
  );
}
