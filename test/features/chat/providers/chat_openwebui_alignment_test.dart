import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

    test(
      'unknown image filename extensions do not block server MIME lookup',
      () {
        check(mimeTypeFromFileNameForTest('photo.png')).equals('image/png');
        check(mimeTypeFromFileNameForTest('camera-original.heic')).isNull();
        check(mimeTypeFromFileNameForTest('scan.tiff')).isNull();
        check(mimeTypeFromFileNameForTest('modern.avif')).isNull();
      },
    );

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
      check(
        headlessAssistantLandedForTest(
          ChatMessage(
            id: 'a3',
            role: 'assistant',
            content: '',
            timestamp: now,
            metadata: const {'parentId': 'u1', 'childrenIds': <String>[]},
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

    test(
      'direct assistant history stays raw when switching to OpenWebUI',
      () async {
        const raw =
            '  literal <tag data="a&b"> & &lt;entity&gt; '
            '`Map<String, String> m = {"x": "a&b"};`  ';
        const presentation =
            'literal &lt;tag data=&quot;a&amp;b&quot;&gt; &amp; '
            '&amp;lt;entity&amp;gt; `Map<String, String> m = {"x": "a&b"};`';
        final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
          messages: [
            ChatMessage(
              id: 'direct-assistant',
              role: 'assistant',
              content: presentation,
              timestamp: DateTime.utc(2026, 7, 14),
              metadata: const <String, dynamic>{
                'transport': kDirectTransport,
                kDirectRawAssistantContentMetadataKey: raw,
              },
            ),
            ChatMessage(
              id: 'next-user',
              role: 'user',
              content: 'Continue with OpenWebUI',
              timestamp: DateTime.utc(2026, 7, 14),
            ),
          ],
        );

        check(messages.first['content']).equals(raw);
        check(messages.first['content']).not((it) => it.equals(presentation));
      },
    );

    test('direct assistant history stays raw when switching to Hermes', () {
      const raw =
          '  literal <tag data="a&b"> & &lt;entity&gt; '
          '`Map<String, String> m = {"x": "a&b"};`  ';
      const presentation =
          'literal &lt;tag data=&quot;a&amp;b&quot;&gt; &amp; '
          '&amp;lt;entity&amp;gt; `Map<String, String> m = {"x": "a&b"};`';
      final messages = buildHermesVisibleHistoryForTest([
        ChatMessage(
          id: 'direct-assistant',
          role: 'assistant',
          content: presentation,
          timestamp: DateTime.utc(2026, 7, 14),
          metadata: const <String, dynamic>{
            'transport': kDirectTransport,
            kDirectRawAssistantContentMetadataKey: raw,
          },
        ),
        ChatMessage(
          id: 'next-user',
          role: 'user',
          content: 'Continue with Hermes',
          timestamp: DateTime.utc(2026, 7, 14),
        ),
      ]);
      final assistant = messages.firstWhere(
        (message) => message['role'] == 'assistant',
      );

      check(assistant['content']).equals(raw);
      check(assistant['content']).not((it) => it.equals(presentation));
    });

    test(
      'Hermes history omits images when the current server lacks support',
      () {
        const image = 'data:image/png;base64,AQID';
        final messages = buildHermesVisibleHistoryForTest([
          ChatMessage(
            id: 'prior-image-user',
            role: 'user',
            content: 'What is shown?',
            timestamp: DateTime.utc(2026, 7, 14),
            attachmentIds: const [image],
            files: const [
              {'type': 'image', 'url': image},
            ],
          ),
        ], inputImagesSupported: false);

        check(messages.single['content']).equals('What is shown?');
      },
    );

    test('Hermes history waits for image capability resolution', () async {
      const image = 'data:image/png;base64,AQID';
      final capabilities = Completer<HermesCapabilities>();
      final container = ProviderContainer(
        overrides: [
          hermesCapabilitiesProvider.overrideWith((ref) => capabilities.future),
        ],
      );
      addTearDown(container.dispose);

      final history = buildHermesVisibleHistoryAfterCapabilityResolutionForTest(
        container,
        [
          ChatMessage(
            id: 'prior-image-user',
            role: 'user',
            content: 'What is shown?',
            timestamp: DateTime.utc(2026, 7, 14),
            attachmentIds: const [image],
            files: const [
              {'type': 'image', 'url': image},
            ],
          ),
        ],
      );
      var completed = false;
      unawaited(history.whenComplete(() => completed = true));
      await Future<void>.delayed(Duration.zero);
      check(completed).isFalse();

      capabilities.complete(const HermesCapabilities(inputImages: true));
      final messages = await history;
      final content = messages.single['content'] as List<dynamic>;
      check(
        content.whereType<Map<String, dynamic>>().any(
          (part) => part['image_url'] == image,
        ),
      ).isTrue();
    });
  });
}
