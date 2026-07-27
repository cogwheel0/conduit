import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/views/chat_timeline_render_model.dart';
import 'package:conduit/features/chat/views/chat_turn_render_state.dart';
import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts the latest completed assistant as the stable tail turn', () {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Question',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Answer',
        timestamp: DateTime(2026),
      ),
    ];

    final timeline = ChatTimelineRenderModel.fromMessages(messages);

    expect(timeline.historyMessages.map((message) => message.id), ['user-1']);
    expect(timeline.tailAssistant?.id, 'assistant-1');
    expect(timeline.tailAssistantSourceIndex, 1);
    expect(timeline.tailAssistantPhase, ChatTurnPhase.completed);
    expect(timeline.runningFooterHost, isNull);
    check(
      timeline.listIndexByMessageId,
    ).deepEquals({'user-1': 0, 'assistant-1': 1});
    check(timeline.listItemCount).equals(2);
    check(timeline.messageIds).deepEquals(['user-1', 'assistant-1']);
    check(timeline.sourceIndexByRenderIndex).deepEquals([0, 1]);
    check(timeline.tailAssistantRenderIndex).equals(1);
    check(timeline.messageAtListIndex(0)?.id).equals('user-1');
    check(timeline.messageAtListIndex(1)?.id).equals('assistant-1');
    check(timeline.indexForMessageId('user-1')).equals(0);
    check(timeline.indexForMessageId('assistant-1')).equals(1);
    check(timeline.messageAtListIndex(-1)).isNull();
    check(timeline.messageAtListIndex(2)).isNull();
    check(timeline.indexForMessageId('missing')).isNull();
  });

  test('extracts the active tail assistant from stable history', () {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Question',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-live',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026),
        isStreaming: true,
      ),
    ];

    final timeline = ChatTimelineRenderModel.fromMessages(messages);

    expect(timeline.historyMessages.map((message) => message.id), ['user-1']);
    expect(timeline.tailAssistant?.id, 'assistant-live');
    expect(timeline.tailAssistantSourceIndex, 1);
    expect(timeline.tailAssistantPhase, ChatTurnPhase.running);
    expect(timeline.runningFooterHost?.messageId, 'assistant-live');
    check(
      timeline.listIndexByMessageId,
    ).deepEquals({'user-1': 0, 'assistant-live': 1});
    check(timeline.listItemCount).equals(2);
    check(timeline.tailAssistantRenderIndex).equals(1);
  });

  test(
    'duplicate ids keep the first render row and complete source history',
    () {
      final duplicate = ChatMessage(
        id: 'duplicate',
        role: 'user',
        content: 'First',
        timestamp: DateTime(2026),
      );
      final historyDuplicate = ChatTimelineRenderModel.fromMessages([
        duplicate,
        duplicate.copyWith(content: 'Malformed duplicate'),
      ]);
      check(historyDuplicate.messageIds).deepEquals(['duplicate']);
      check(historyDuplicate.sourceIndexByRenderIndex).deepEquals([0]);
      check(historyDuplicate.listIndexByMessageId).deepEquals({'duplicate': 0});
      check(historyDuplicate.listItemCount).equals(1);
      check(historyDuplicate.historyMessages).length.equals(2);
      check(historyDuplicate.messageAtListIndex(0)?.content).equals('First');
      check(historyDuplicate.messageAtListIndex(1)).isNull();

      final tailDuplicate = ChatTimelineRenderModel.fromMessages([
        duplicate,
        ChatMessage(
          id: 'distinct',
          role: 'user',
          content: 'Newest prompt',
          timestamp: DateTime(2026),
        ),
        ChatMessage(
          id: 'duplicate',
          role: 'assistant',
          content: 'Malformed live tail',
          timestamp: DateTime(2026),
          isStreaming: true,
        ),
      ]);
      check(tailDuplicate.messageIds).deepEquals(['duplicate', 'distinct']);
      check(
        tailDuplicate.listIndexByMessageId,
      ).deepEquals({'duplicate': 0, 'distinct': 1});
      check(tailDuplicate.sourceIndexByRenderIndex).deepEquals([0, 1]);
      check(tailDuplicate.listItemCount).equals(2);
      check(tailDuplicate.tailAssistant?.content).equals('Malformed live tail');
      check(tailDuplicate.tailAssistantRenderIndex).isNull();
      check(tailDuplicate.indexForMessageId('duplicate')).equals(0);

      final uniqueTailAfterDuplicate = ChatTimelineRenderModel.fromMessages([
        duplicate,
        duplicate.copyWith(content: 'Malformed duplicate'),
        ChatMessage(
          id: 'assistant-live',
          role: 'assistant',
          content: 'Valid live tail',
          timestamp: DateTime(2026),
          isStreaming: true,
        ),
      ]);
      check(
        uniqueTailAfterDuplicate.messageIds,
      ).deepEquals(['duplicate', 'assistant-live']);
      check(
        uniqueTailAfterDuplicate.sourceIndexByRenderIndex,
      ).deepEquals([0, 2]);
      check(uniqueTailAfterDuplicate.tailAssistantSourceIndex).equals(2);
      check(uniqueTailAfterDuplicate.tailAssistantRenderIndex).equals(1);
      check(
        uniqueTailAfterDuplicate.indexForMessageId('assistant-live'),
      ).equals(1);
      check(uniqueTailAfterDuplicate.sourceIndexAtRenderIndex(1)).equals(2);
      check(uniqueTailAfterDuplicate.sourceIndexAtRenderIndex(-1)).isNull();
      check(uniqueTailAfterDuplicate.sourceIndexAtRenderIndex(2)).isNull();
    },
  );

  test('keeps the same tail slot when a stream completes', () {
    final streamingMessages = <ChatMessage>[
      ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Question',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-live',
        role: 'assistant',
        content: 'Partial',
        timestamp: DateTime(2026),
        isStreaming: true,
      ),
    ];
    final completedMessages = [
      streamingMessages.first,
      streamingMessages.last.copyWith(
        content: 'Complete answer',
        isStreaming: false,
      ),
    ];

    final streaming = ChatTimelineRenderModel.fromMessages(streamingMessages);
    final completed = ChatTimelineRenderModel.fromMessages(completedMessages);

    expect(streaming.historyMessages.map((message) => message.id), ['user-1']);
    expect(completed.historyMessages.map((message) => message.id), ['user-1']);
    expect(streaming.tailAssistant?.id, completed.tailAssistant?.id);
    expect(
      streaming.tailAssistantSourceIndex,
      completed.tailAssistantSourceIndex,
    );
    expect(streaming.tailAssistantPhase, ChatTurnPhase.running);
    expect(completed.tailAssistantPhase, ChatTurnPhase.completed);
  });

  test('does not extract non-assistant or non-tail streaming rows', () {
    final streamingUser = ChatMessage(
      id: 'user-streaming',
      role: 'user',
      content: 'Question',
      timestamp: DateTime(2026),
      isStreaming: true,
    );
    final historicalStreamingAssistant = ChatMessage(
      id: 'assistant-streaming',
      role: 'assistant',
      content: 'Historical stream',
      timestamp: DateTime(2026),
      isStreaming: true,
    );
    final finalUser = ChatMessage(
      id: 'user-final',
      role: 'user',
      content: 'Next question',
      timestamp: DateTime(2026),
    );

    final userTailTimeline = ChatTimelineRenderModel.fromMessages([
      streamingUser,
    ]);
    final nonTailTimeline = ChatTimelineRenderModel.fromMessages([
      historicalStreamingAssistant,
      finalUser,
    ]);

    expect(userTailTimeline.tailAssistant, isNull);
    expect(userTailTimeline.historyMessages.single.id, 'user-streaming');
    expect(nonTailTimeline.tailAssistant, isNull);
    expect(nonTailTimeline.historyMessages.map((message) => message.id), [
      'assistant-streaming',
      'user-final',
    ]);
    check(
      nonTailTimeline.listIndexByMessageId,
    ).deepEquals({'assistant-streaming': 0, 'user-final': 1});
    check(
      nonTailTimeline.messageIds,
    ).deepEquals(['assistant-streaming', 'user-final']);
  });

  test(
    'routes a failed tail assistant to the completed (non-running) footer',
    () {
      final messages = <ChatMessage>[
        ChatMessage(
          id: 'user-1',
          role: 'user',
          content: 'Question',
          timestamp: DateTime(2026),
        ),
        ChatMessage(
          id: 'assistant-failed',
          role: 'assistant',
          content: 'Partial',
          timestamp: DateTime(2026),
          // error must take precedence over the streaming flag.
          isStreaming: true,
          error: const ChatMessageError(content: 'boom'),
        ),
      ];

      final timeline = ChatTimelineRenderModel.fromMessages(messages);

      expect(timeline.tailAssistant?.id, 'assistant-failed');
      expect(timeline.tailAssistantPhase, ChatTurnPhase.failed);
      expect(timeline.runningFooterHost, isNull);
    },
  );

  test(
    'chatTurnPhaseForMessage treats responseDone as completed while streaming',
    () {
      final streaming = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Partial',
        timestamp: DateTime(2026),
        isStreaming: true,
      );

      expect(chatTurnPhaseForMessage(streaming), ChatTurnPhase.running);
      expect(
        chatTurnPhaseForMessage(
          streaming.copyWith(metadata: const {'responseDone': true}),
        ),
        ChatTurnPhase.completed,
      );
      // The explicit override still wins for the running case.
      expect(
        chatTurnPhaseForMessage(streaming, isStreaming: false),
        ChatTurnPhase.completed,
      );
    },
  );

  test('does not promote an archived-variant assistant to the live tail', () {
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Question',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'assistant-archived',
        role: 'assistant',
        content: 'Stale archived answer',
        timestamp: DateTime(2026),
        metadata: const {'archivedVariant': true},
      ),
    ];

    final timeline = ChatTimelineRenderModel.fromMessages(messages);

    expect(timeline.tailAssistant, isNull);
    expect(timeline.tailAssistantSourceIndex, isNull);
    expect(timeline.runningFooterHost, isNull);
    expect(timeline.historyMessages.map((message) => message.id), [
      'user-1',
      'assistant-archived',
    ]);
    check(
      timeline.listIndexByMessageId,
    ).deepEquals({'user-1': 0, 'assistant-archived': 1});
  });

  test('fromMessages([]) yields an empty, tail-less timeline', () {
    final timeline = ChatTimelineRenderModel.fromMessages(const []);

    expect(timeline.historyMessages, isEmpty);
    expect(timeline.tailAssistant, isNull);
    expect(timeline.tailAssistantSourceIndex, isNull);
    expect(timeline.tailAssistantPhase, ChatTurnPhase.none);
    expect(timeline.runningFooterHost, isNull);
    expect(timeline.hasTailAssistant, isFalse);
    expect(timeline.hasRunningTurn, isFalse);
    check(timeline.listIndexByMessageId).isEmpty();
    check(timeline.messageIds).isEmpty();
    check(timeline.listItemCount).equals(0);
    check(timeline.tailAssistantRenderIndex).isNull();
  });

  test(
    'chatTurnPhaseShowsCompletedFooter is true only for completed and failed',
    () {
      expect(chatTurnPhaseShowsCompletedFooter(ChatTurnPhase.none), isFalse);
      expect(chatTurnPhaseShowsCompletedFooter(ChatTurnPhase.running), isFalse);
      expect(
        chatTurnPhaseShowsCompletedFooter(ChatTurnPhase.completed),
        isTrue,
      );
      expect(chatTurnPhaseShowsCompletedFooter(ChatTurnPhase.failed), isTrue);
    },
  );

  test(
    'chatTurnPhaseForMessage returns none for null and non-assistant messages',
    () {
      expect(chatTurnPhaseForMessage(null), ChatTurnPhase.none);

      // A non-assistant message is never a turn, even while streaming.
      final user = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hi',
        timestamp: DateTime(2026),
        isStreaming: true,
      );
      expect(chatTurnPhaseForMessage(user), ChatTurnPhase.none);
    },
  );
}
