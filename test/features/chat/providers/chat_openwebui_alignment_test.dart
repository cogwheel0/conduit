import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpenWebUI selection alignment', () {
    test('extractToolIdsForApiForTest strips direct server selections', () {
      final toolIds = extractToolIdsForApiForTest(const [
        'calculator',
        'direct_server:0',
        'search',
        'direct_server:tool-server',
      ]);

      check(toolIds).deepEquals(const ['calculator', 'search']);
    });

    test(
      'filterSelectedConfiguredToolServersForTest matches by index or id',
      () {
        final filtered = filterSelectedConfiguredToolServersForTest(
          rawServers: const [
            {
              'name': 'Indexed server',
              'url': 'https://indexed.example',
              'path': '/openapi.json',
              'config': {'enable': true},
            },
            {
              'id': 'server-2',
              'name': 'Id server',
              'url': 'https://id.example',
              'path': '/openapi.json',
              'config': {'enable': true},
            },
            {
              'id': 'disabled',
              'name': 'Disabled server',
              'url': 'https://disabled.example',
              'path': '/openapi.json',
              'config': {'enable': false},
            },
          ],
          selectedToolIds: const [
            'direct_server:0',
            'direct_server:server-2',
            'direct_server:disabled',
          ],
        );

        check(filtered).deepEquals(const [
          {
            'name': 'Indexed server',
            'url': 'https://indexed.example',
            'path': '/openapi.json',
            'config': {'enable': true},
          },
          {
            'id': 'server-2',
            'name': 'Id server',
            'url': 'https://id.example',
            'path': '/openapi.json',
            'config': {'enable': true},
          },
        ]);
      },
    );

    test(
      'resolveTerminalIdForRequestForTest only uses the explicit selection',
      () {
        check(resolveTerminalIdForRequestForTest(null)).isNull();
        check(
          resolveTerminalIdForRequestForTest('  terminal-1  '),
        ).equals('terminal-1');
      },
    );
  });

  group('OpenWebUI message alignment', () {
    test('durable attachments preserve data URL images separately', () {
      const dataUrl = 'data:image/png;base64,AA==';

      final files = buildDurableFilesForTest(const [dataUrl, 'file-123']);

      check(files).deepEquals(const [
        {'type': 'image', 'url': dataUrl},
        {'type': 'file', 'id': 'file-123', 'url': 'file-123'},
      ]);
    });

    test('durable attachments classify uploaded image ids by content type', () {
      final files = buildDurableFilesForTest(
        const ['image-file', 'document-file'],
        contentTypes: const {
          'image-file': 'image/png',
          'document-file': 'application/pdf',
        },
      );

      check(files).deepEquals(const [
        {
          'type': 'image',
          'id': 'image-file',
          'url': 'image-file',
          'content_type': 'image/png',
        },
        {
          'type': 'file',
          'id': 'document-file',
          'url': 'document-file',
          'content_type': 'application/pdf',
        },
      ]);
    });

    test('headless landing detects structured non-text assistant output', () {
      final now = DateTime.utc(2026, 1, 1);

      check(
        headlessAssistantLandedForTest(
          ChatMessage(
            id: 'a1',
            role: 'assistant',
            content: '',
            timestamp: now,
            output: const [
              {'type': 'tool_calls'},
            ],
          ),
        ),
      ).isTrue();
      check(
        headlessAssistantLandedForTest(
          ChatMessage(
            id: 'a2',
            role: 'assistant',
            content: '',
            timestamp: now,
            metadata: const {'responseDone': true},
          ),
        ),
      ).isFalse();
    });

    test('temporary chats keep full outbound history', () {
      final messages = buildChatCompletionMessagesForTest(
        conversationMessages: const [
          {'role': 'system', 'content': 'System'},
          {'role': 'user', 'content': 'Hello'},
          {'role': 'assistant', 'content': 'Hi'},
        ],
        isTemporary: true,
      );

      check(messages).deepEquals(const [
        {'role': 'system', 'content': 'System'},
        {'role': 'user', 'content': 'Hello'},
        {'role': 'assistant', 'content': 'Hi'},
      ]);
    });

    test('persisted chats send only system messages', () {
      final messages = buildChatCompletionMessagesForTest(
        conversationMessages: const [
          {'role': 'system', 'content': 'System'},
          {'role': 'user', 'content': 'Hello'},
          {'role': 'assistant', 'content': 'Hi'},
        ],
        isTemporary: false,
      );

      check(messages).deepEquals(const [
        {'role': 'system', 'content': 'System'},
      ]);
    });
  });
}
