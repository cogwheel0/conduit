import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('localEchoRowForMessage', () {
    final message = ChatMessage(
      id: 'assistant-1',
      role: 'assistant',
      content: 'Answer',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      model: 'gpt-4o',
      isStreaming: false,
      metadata: const <String, dynamic>{'modelName': 'GPT-4o'},
      output: const <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': 'Answer'},
      ],
      files: const <Map<String, dynamic>>[
        <String, dynamic>{'type': 'image', 'url': 'https://x/img.png'},
      ],
      embeds: const <Map<String, dynamic>>[
        <String, dynamic>{'html': '<iframe></iframe>'},
      ],
      usage: const <String, dynamic>{'total_tokens': 42},
      sources: const <ChatSourceReference>[
        ChatSourceReference(
          id: 'src-1',
          title: 'Docs',
          url: 'https://example.com',
          snippet: 'Snippet text',
          type: 'web_search',
        ),
      ],
      statusHistory: const <ChatStatusUpdate>[
        ChatStatusUpdate(description: 'Searching', done: true),
      ],
      codeExecutions: const <ChatCodeExecution>[
        ChatCodeExecution(
          id: 'exec-1',
          name: 'run',
          language: 'python',
          code: 'print(1)',
          result: ChatCodeExecutionResult(output: '1'),
        ),
      ],
      followUps: const <String>['Next?'],
      error: const ChatMessageError(content: 'boom'),
    );

    test('carries every durable field the sync outbox must replay', () {
      // The outbox rebuilds the full chat blob from these rows and the server
      // replaces each message object wholesale — a key missing here is a key
      // wiped from the server copy on the next push.
      final payload = localEchoRowForMessage('chat-1', message).payload;

      const durableKeys = {
        'id',
        'parentId',
        'childrenIds',
        'role',
        'content',
        'timestamp',
        'isStreaming',
        'done',
        'model',
        'metadata',
        'output',
        'files',
        'embeds',
        'usage',
        'sources',
        'statusHistory',
        'code_executions',
        'followUps',
        'error',
      };
      check(durableKeys.difference(payload.keys.toSet())).isEmpty();
    });

    test('persists sources and code executions in the server shape', () {
      // The OWUI web client reads citation-shaped `sources` and snake_case
      // `code_executions`; client-model shapes would break that client for
      // any chat synced from Conduit.
      final payload = localEchoRowForMessage('chat-1', message).payload;

      final source =
          (payload['sources'] as List).single as Map<String, dynamic>;
      check(source['source']).isA<Map<String, dynamic>>();
      check(source['document']).isA<List<dynamic>>();
      check(source.containsKey('snippet')).isFalse();

      final execution =
          (payload['code_executions'] as List).single as Map<String, dynamic>;
      check(execution['id']).equals('exec-1');
      check((execution['result'] as Map<String, dynamic>)['output'])
          .equals('1');
      check(payload.containsKey('codeExecutions')).isFalse();
    });
  });
}
