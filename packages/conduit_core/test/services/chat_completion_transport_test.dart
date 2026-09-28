import 'package:checks/checks.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:test/test.dart';

void main() {
  group('ChatCompletionSession', () {
    test('resumeSocket session is socket-only with no stream or abort', () {
      final session = ChatCompletionSession.resumeSocket(
        messageId: 'assistant-1',
        conversationId: 'chat-1',
      );

      // Feature C: resume maps to taskSocket transport but carries no HTTP body
      // and no abort handle, and forces a null session id so the streaming
      // helper binds the server's foreign message_id by chat_id.
      check(session.transport).equals(ChatCompletionTransport.taskSocket);
      check(session.messageId).equals('assistant-1');
      check(session.conversationId).equals('chat-1');
      check(session.byteStream).isNull();
      check(session.abort).isNull();
      check(session.sessionId).isNull();
    });

    test(
      'resumeSocket carries the discovered task id for stoppable metadata',
      () {
        final session = ChatCompletionSession.resumeSocket(
          messageId: 'assistant-1',
          conversationId: 'chat-1',
          taskId: 'task-42',
        );

        // The task id must survive so dispatchChatTransport writes stoppable
        // metadata onto the resumed message (stop/delete can cancel the server
        // task, not just the local socket subscription).
        check(session.taskId).equals('task-42');
        check(session.sessionId).isNull();
      },
    );
  });
}
