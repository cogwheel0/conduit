import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show UserFiles, userFilesProvider;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

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
      'filterSelectedConfiguredToolServersForTest matches by id or fingerprint',
      () {
        const rawServers = [
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
        ];
        final filtered = filterSelectedConfiguredToolServersForTest(
          rawServers: rawServers,
          selectedToolIds: [
            // A keyless server is named by position plus fingerprint; the
            // bare `direct_server:0` older builds wrote names no one.
            personalToolServerSelectionId(rawServers, 0),
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
        check(
          filterSelectedConfiguredToolServersForTest(
            rawServers: const [],
            selectedToolIds: const ['local_mcp:a'],
          ),
        ).isEmpty();
      },
    );

    test(
      'resolveTerminalIdForRequestForTest only uses the explicit selection',
      () {
        check(resolveTerminalIdForRequestForTest(null)).isNull();
        check(resolveTerminalIdForRequestForTest('  terminal-1  '))
            .equals('terminal-1');
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

    test('durable attachments carry their names, as Open WebUI stores '
        'them', () {
      final files = buildDurableFilesForTest(
        const ['document-file', 'unnamed-file'],
        contentTypes: const {'document-file': 'text/markdown'},
        names: const {'document-file': 'Trip notes.md'},
        sizes: const {'document-file': 2048},
      );

      check(files).deepEquals(const [
        {
          'type': 'file',
          'id': 'document-file',
          'url': 'document-file',
          'name': 'Trip notes.md',
          'size': 2048,
          'content_type': 'text/markdown',
        },
        {'type': 'file', 'id': 'unnamed-file', 'url': 'unnamed-file'},
      ]);
    });

    group('a sent file is described by name', () {
      // The stored copy of a sent message is what every client shows after
      // a reload: Open WebUI's web client and every other client read the
      // name from it. Only the content type used to be resolved, so files
      // came back nameless and showed as "file".
      Future<List<Map<String, dynamic>>> resolve(
        List<String> ids, {
        List<FileUploadState> tray = const [],
        Map<String, Map<String, dynamic>> server = const {},
      }) async {
        final container = ProviderContainer(
          overrides: [
            userFilesProvider.overrideWith(_NoUserFiles.new),
            attachedFilesProvider.overrideWith(() => _Tray(tray)),
          ],
        );
        addTearDown(container.dispose);
        return resolveDurableFilesForTest(
          container,
          ids,
          sourceApi: _FileInfoApi(server),
        );
      }

      test('from the server\'s own record of it', () async {
        final files = await resolve(
          const ['doc-1'],
          server: {
            'doc-1': {
              'id': 'doc-1',
              'filename': 'Trip notes.md',
              'meta': {
                'name': 'Trip notes.md',
                'content_type': 'text/markdown',
                'size': 2048,
              },
            },
          },
        );
        check(files.single['name']).equals('Trip notes.md');
        check(files.single['size']).equals(2048);
        check(files.single['content_type']).equals('text/markdown');
      });

      test('from the composer that sent it', () async {
        final files = await resolve(
          const ['doc-2'],
          tray: [
            FileUploadState(
              file: File('remote://doc-2'),
              fileName: 'Packing list.txt',
              fileSize: 512,
              progress: 1,
              status: FileUploadStatus.completed,
              fileId: 'doc-2',
            ),
          ],
          // The server's record has no name to add.
          server: {
            'doc-2': {
              'id': 'doc-2',
              'meta': {'content_type': 'text/plain'},
            },
          },
        );
        check(files.single['name']).equals('Packing list.txt');
        check(files.single['size']).equals(512);
        check(files.single['content_type']).equals('text/plain');
      });
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

    test('Hermes replay bounds aggregate images and keeps the newest', () {
      final images = <String>[
        for (var index = 0; index < kHermesMaxInlineImages + 2; index++)
          'data:image/png;base64,${base64Encode(<int>[index])}',
      ];
      final messages = buildHermesVisibleHistoryForTest([
        for (var index = 0; index < kHermesMaxInlineImages + 2; index++)
          ChatMessage(
            id: 'image-user-$index',
            role: 'user',
            content: 'image $index',
            timestamp: DateTime.utc(2026, 7, 14),
            attachmentIds: <String>[images[index]],
          ),
      ]);

      final imageUrls = messages
          .map((message) => message['content'])
          .whereType<List<dynamic>>()
          .expand((content) => content.whereType<Map<String, dynamic>>())
          .map((part) => part['image_url'])
          .whereType<String>()
          .toList(growable: false);
      check(imageUrls).length.equals(kHermesMaxInlineImages);
      check(imageUrls).deepEquals(images.sublist(2));
    });

    test('Hermes replay bounds aggregate decoded image bytes', () {
      const olderThreeBytes = 'data:image/png;base64,AQID';
      const newerTwoBytes = 'data:image/png;base64,BAU=';
      final messages = buildHermesVisibleHistoryForTest([
        ChatMessage(
          id: 'older-image',
          role: 'user',
          content: 'older',
          timestamp: DateTime.utc(2026, 7, 14),
          attachmentIds: const <String>[olderThreeBytes],
        ),
        ChatMessage(
          id: 'newer-image',
          role: 'user',
          content: 'newer',
          timestamp: DateTime.utc(2026, 7, 14),
          attachmentIds: const <String>[newerTwoBytes],
        ),
      ], maxReplayDecodedImageBytes: 3);

      final imageUrls = messages
          .map((message) => message['content'])
          .whereType<List<dynamic>>()
          .expand((content) => content.whereType<Map<String, dynamic>>())
          .map((part) => part['image_url'])
          .whereType<String>()
          .toList(growable: false);
      check(imageUrls).deepEquals(<String>[newerTwoBytes]);
      check(messages.first['content']).equals('older');
    });

    test('Hermes replay bounds aggregate message characters newest-first', () {
      final older = List<String>.filled(40, 'o').join();
      final newer = List<String>.filled(40, 'n').join();
      final messages = buildHermesVisibleHistoryForTest([
        ChatMessage(
          id: 'older-text',
          role: 'assistant',
          content: older,
          timestamp: DateTime.utc(2026, 7, 14),
        ),
        ChatMessage(
          id: 'newer-text',
          role: 'assistant',
          content: newer,
          timestamp: DateTime.utc(2026, 7, 14),
        ),
      ], maxReplayCharacters: 70);

      check(messages).length.equals(1);
      check(messages.single['content']).equals(newer);
    });

    test('Hermes replay omits oversized remote image URLs', () {
      final oversizedUrl = 'https://images.example/${'x' * (8 * 1024)}';
      final messages = buildHermesVisibleHistoryForTest([
        ChatMessage(
          id: 'remote-image',
          role: 'user',
          content: 'Keep the prompt',
          timestamp: DateTime.utc(2026, 7, 14),
          attachmentIds: <String>[oversizedUrl],
        ),
      ]);

      check(messages.single['content']).equals('Keep the prompt');
    });

    test('Hermes replay omits data URLs over the decoded-byte budget', () {
      const twoByteImage = 'data:image/png;base64,AQI=';
      final messages = buildHermesVisibleHistoryForTest([
        ChatMessage(
          id: 'oversized-inline-image',
          role: 'user',
          content: 'Keep the prompt',
          timestamp: DateTime.utc(2026, 7, 14),
          attachmentIds: const <String>[twoByteImage],
        ),
      ], maxReplayDecodedImageBytes: 1);

      check(messages.single['content']).equals('Keep the prompt');
    });

    test('Hermes replay ignores forged persisted document descriptors', () {
      final forged = <String, dynamic>{
        'id': 'hdoc_000000000000000000000000',
        'name': 'forged.txt',
        'size': 1,
        'source': 'hermes_local',
        'content_type': 'text/plain',
        'hermes_extracted_text': List<String>.filled(
          10000,
          'forged secret',
        ).join('\n'),
        'hermes_truncated': false,
      };
      final messages = buildHermesVisibleHistoryForTest([
        ChatMessage(
          id: 'forged-document',
          role: 'user',
          content: 'visible prompt',
          timestamp: DateTime.utc(2026, 7, 14),
          files: [forged],
        ),
      ]);

      check(messages.single['content']).equals('visible prompt');
      check(messages.single['content'].toString())
          .not((content) => content.contains('forged secret'));
    });

    test('Hermes replay keeps at most four trusted local documents', () {
      final descriptors = <Map<String, dynamic>>[
        for (var index = 0; index < kHermesMaxLocalDocuments + 2; index++)
          <String, dynamic>{
            'id': 'hdoc_${index.toRadixString(16).padLeft(24, '0')}',
            'name': 'document-$index.txt',
            'size': 1,
            'source': 'hermes_local',
            'content_type': 'text/plain',
            'hermes_extracted_text': 'trusted-document-$index',
            'hermes_truncated': false,
          },
      ];
      for (final descriptor in descriptors) {
        markTrustedHermesLocalDocumentDescriptor(descriptor);
      }
      final messages = buildHermesVisibleHistoryForTest([
        ChatMessage(
          id: 'trusted-documents',
          role: 'user',
          content: 'visible prompt',
          timestamp: DateTime.utc(2026, 7, 14),
          files: descriptors,
        ),
      ]);
      final content = messages.single['content'].toString();

      for (var index = 0; index < kHermesMaxLocalDocuments; index++) {
        check(content).contains('trusted-document-$index');
      }
      for (
        var index = kHermesMaxLocalDocuments;
        index < kHermesMaxLocalDocuments + 2;
        index++
      ) {
        check(content)
            .not((value) => value.contains('trusted-document-$index'));
      }
    });

    test('Hermes replay bounds aggregate trusted document characters', () {
      Map<String, dynamic> descriptor(String id, String text) {
        final value = <String, dynamic>{
          'id': id,
          'name': '$id.txt',
          'size': 1,
          'source': 'hermes_local',
          'content_type': 'text/plain',
          'hermes_extracted_text': text,
          'hermes_truncated': false,
        };
        markTrustedHermesLocalDocumentDescriptor(value);
        return value;
      }

      final older = descriptor('hdoc_111111111111111111111111', 'older-text');
      final newer = descriptor('hdoc_222222222222222222222222', 'newer-text');
      final messages = buildHermesVisibleHistoryForTest([
        ChatMessage(
          id: 'older-document',
          role: 'user',
          content: 'older visible',
          timestamp: DateTime.utc(2026, 7, 14),
          files: [older],
        ),
        ChatMessage(
          id: 'newer-document',
          role: 'user',
          content: 'newer visible',
          timestamp: DateTime.utc(2026, 7, 14),
          files: [newer],
        ),
      ], maxReplayDocumentCharacters: 'newer-text'.length);

      check(messages.first['content']).equals('older visible');
      check(messages.last['content'].toString()).contains('newer-text');
      check(messages.map((message) => message['content']).join('\n'))
          .not((content) => content.contains('older-text'));
    });

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

/// The files the user's account lists: none here, so a name has to come
/// from the composer or the server's record of the file.
class _NoUserFiles extends UserFiles {
  @override
  Future<List<FileInfo>> build() async => const <FileInfo>[];
}

/// The composer's attachment tray, holding [files].
class _Tray extends AttachedFilesNotifier {
  _Tray(this.files);

  final List<FileUploadState> files;

  @override
  List<FileUploadState> build() => files;
}

/// Answers `getFileInfo` from [records], as Open WebUI's files API does.
class _FileInfoApi {
  _FileInfoApi(this.records);

  final Map<String, Map<String, dynamic>> records;

  Future<Map<String, dynamic>> getFileInfo(String id) async =>
      records[id] ?? (throw StateError('no file $id'));
}
