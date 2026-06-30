import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/views/chat_timeline_render_model.dart';
import 'package:conduit/features/chat/views/chat_turn_render_state.dart';
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
    expect(timeline.historyIndexByMessageKey, {'message-user-1': 0});
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
    expect(timeline.historyIndexByMessageKey, {'message-user-1': 0});
  });

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
    expect(nonTailTimeline.historyIndexByMessageKey, {
      'message-assistant-streaming': 0,
      'message-user-final': 1,
    });
  });

  test('routes a failed tail assistant to the completed (non-running) footer', () {
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
  });

  test('chatTurnPhaseForMessage treats responseDone as completed while streaming', () {
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
  });

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
    expect(timeline.historyIndexByMessageKey, {
      'message-user-1': 0,
      'message-assistant-archived': 1,
    });
  });
}
