import 'dart:async';

import 'package:checks/checks.dart';
import 'package:qonduit/core/services/chat_completion_transport.dart';
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
