import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/chat_completion_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatCompletionSession', () {
    test('taskSocket session stores task id and has no direct stream', () {
      final session = ChatCompletionSession.taskSocket(
        messageId: 'assistant-1',
        sessionId: 'session-1',
        taskId: 'task-1',
        abort: () async {},
      );

      check(session.transport).equals(ChatCompletionTransport.taskSocket);
      check(session.taskId).equals('task-1');
      check(session.byteStream).isNull();
      check(session.abort).isNotNull();
    });

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

    test('resumeSocket carries the discovered task id for stoppable metadata', () {
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
    });

    test('httpStream session stores byte stream and abort handle', () {
      final session = ChatCompletionSession.httpStream(
        messageId: 'assistant-2',
        sessionId: 'session-2',
        conversationId: 'chat-9',
        byteStream: const Stream<List<int>>.empty(),
        abort: () async {},
      );

      check(session.transport).equals(ChatCompletionTransport.httpStream);
      check(session.conversationId).equals('chat-9');
      check(session.byteStream).isNotNull();
      check(session.abort).isNotNull();
    });

    test('jsonCompletion session stores final payload and no task id', () {
      final session = ChatCompletionSession.jsonCompletion(
        messageId: 'assistant-3',
        sessionId: 'session-3',
        jsonPayload: {
          'choices': [
            {
              'message': {'content': 'done'},
            },
          ],
        },
      );

      check(session.transport).equals(ChatCompletionTransport.jsonCompletion);
      check(session.taskId).isNull();
      check(session.jsonPayload).isNotNull();
    });
  });
}
