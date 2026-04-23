import 'package:checks/checks.dart';
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
