import 'dart:convert';

import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('withDirectConversationSystemPrompt', () {
    test('prepends the prompt for send and regenerate history', () {
      final result = withDirectConversationSystemPrompt(
        messages: [_message(id: 'user', role: 'user', content: 'Hello')],
        systemPrompt: '  Be concise.  ',
      );

      expect(result.map((message) => message.role), ['system', 'user']);
      expect(result.first.content, 'Be concise.');
    });

    test('does not duplicate an existing system message', () {
      final result = withDirectConversationSystemPrompt(
        messages: [
          _message(id: 'system', role: 'system', content: 'Existing'),
          _message(id: 'user', role: 'user', content: 'Hello'),
        ],
        systemPrompt: 'Replacement',
      );

      expect(result.where((message) => message.role == 'system'), hasLength(1));
      expect(result.first.content, 'Existing');
    });
  });

  group('buildDirectChatMessages', () {
    test('preserves supported history and resolves protected images', () async {
      final resolvedImage = _imageDataUrl([1, 2, 3]);
      final inlineImage = _imageDataUrl([4, 5, 6]);
      final resolvedIds = <String>[];
      final resolverLimits = <int>[];
      final messages = <ChatMessage>[
        _message(id: 'system', role: 'system', content: '  Be concise.  '),
        _message(
          id: 'archived',
          role: 'assistant',
          content: 'discarded version',
          metadata: const {'archivedVariant': true},
        ),
        _message(id: 'assistant', role: 'assistant', content: 'Earlier answer'),
        _message(
          id: 'user',
          role: 'user',
          content: '  Describe these  ',
          attachmentIds: const ['protected-image', 'missing-image'],
          files: [
            {'type': 'image', 'url': inlineImage},
            {'type': 'image', 'url': inlineImage},
            {'type': 'file', 'id': 'document'},
          ],
        ),
        _message(id: 'tool', role: 'tool', content: 'unsupported role'),
      ];

      final result = await buildDirectChatMessages(
        messages: messages,
        resolveImage: (fileId, maxBytes) async {
          resolvedIds.add(fileId);
          resolverLimits.add(maxBytes);
          return fileId == 'protected-image' ? resolvedImage : null;
        },
      );

      expect(result.map((message) => message.role), [
        'system',
        'assistant',
        'user',
      ]);
      expect(_textParts(result[0]), ['Be concise.']);
      expect(_textParts(result[1]), ['Earlier answer']);
      expect(_textParts(result[2]), ['Describe these']);
      expect(_imageParts(result[2]), [resolvedImage, inlineImage]);
      expect(resolvedIds, ['protected-image', 'missing-image']);
      expect(resolverLimits, [
        kDirectMaxDecodedImageBytes,
        kDirectMaxDecodedImageBytes - 3,
      ]);
    });

    test('retains an image-only user turn', () async {
      final image = _imageDataUrl([7, 8, 9]);

      final result = await buildDirectChatMessages(
        messages: [
          _message(
            id: 'image-only',
            role: 'user',
            content: '   ',
            files: [
              {'type': 'image', 'url': image},
            ],
          ),
        ],
      );

      expect(result, hasLength(1));
      expect(_textParts(result.single), isEmpty);
      expect(_imageParts(result.single), [image]);
    });

    test('deduplicates aliases that resolve to the same image', () async {
      final image = _imageDataUrl([10, 11, 12]);

      final result = await buildDirectChatMessages(
        messages: [
          _message(
            id: 'aliased-images',
            role: 'user',
            content: 'Compare this image',
            attachmentIds: const ['first-id', 'second-id'],
          ),
        ],
        resolveImage: (_, _) async => image,
      );

      expect(_imageParts(result.single), [image]);
    });

    test('rejects more than four images', () async {
      final files = <Map<String, dynamic>>[
        for (var index = 0; index < 5; index++)
          {
            'type': 'image',
            'url': _imageDataUrl([index]),
          },
      ];

      await expectLater(
        buildDirectChatMessages(
          messages: [
            _message(
              id: 'too-many',
              role: 'user',
              content: 'images',
              files: files,
            ),
          ],
        ),
        throwsA(
          isA<DirectChatInputException>().having(
            (error) => error.message,
            'message',
            contains('up to 4 images'),
          ),
        ),
      );
    });

    test('enforces the aggregate decoded image byte limit', () async {
      await expectLater(
        buildDirectChatMessages(
          messages: [
            _message(
              id: 'too-large',
              role: 'user',
              content: 'images',
              files: [
                {
                  'type': 'image',
                  'url': _imageDataUrl([1, 2]),
                },
                {
                  'type': 'image',
                  'url': _imageDataUrl([3, 4]),
                },
              ],
            ),
          ],
          maxDecodedImageBytes: 3,
        ),
        throwsA(
          isA<DirectChatInputException>().having(
            (error) => error.message,
            'message',
            contains('3 bytes or less'),
          ),
        ),
      );
    });

    test('rejects malformed image data URLs', () async {
      await expectLater(
        buildDirectChatMessages(
          messages: [
            _message(
              id: 'bad-image',
              role: 'user',
              content: 'image',
              files: const [
                {'type': 'image', 'url': 'data:image/png;base64,not%base64'},
              ],
            ),
          ],
        ),
        throwsA(isA<DirectChatInputException>()),
      );
    });
  });

  group('DirectStreamingAccumulator', () {
    test('combines reasoning, content, usage, completion, and error', () {
      final accumulator = DirectStreamingAccumulator();

      expect(accumulator.apply(const DirectReasoningDelta('plan')), isTrue);
      expect(accumulator.apply(const DirectReasoningDelta(' more')), isTrue);
      expect(accumulator.apply(const DirectContentDelta('Hello')), isTrue);
      expect(accumulator.apply(const DirectContentDelta(' world')), isTrue);
      expect(
        accumulator.apply(
          DirectUsageUpdate(const {
            'prompt_tokens': 2,
            'completion_tokens': 3,
            'total_tokens': 5,
          }),
        ),
        isTrue,
      );
      expect(
        accumulator.apply(
          const DirectStreamError('provider failed', statusCode: 503),
        ),
        isTrue,
      );

      final streaming = accumulator.render(done: false);
      expect(streaming, contains('type="reasoning"'));
      expect(streaming, contains('done="false"'));
      expect(streaming, contains('<summary>Thinking…</summary>'));
      expect(streaming, contains('&gt; plan more'));
      expect(streaming, endsWith('Hello world'));
      expect(accumulator.reasoning, 'plan more');
      expect(accumulator.text, 'Hello world');
      expect(accumulator.usage?['total_tokens'], 5);
      expect(accumulator.error?.message, 'provider failed');
      expect(accumulator.error?.statusCode, 503);

      expect(accumulator.apply(const DirectStreamDone()), isTrue);
      final completed = accumulator.render(done: true);
      expect(completed, contains('done="true"'));
      expect(completed, contains('<summary>Thought for 0 seconds</summary>'));
      expect(completed, endsWith('Hello world'));
    });

    test('empty deltas do not trigger a renderer update', () {
      final accumulator = DirectStreamingAccumulator();

      expect(accumulator.apply(const DirectContentDelta('')), isFalse);
      expect(accumulator.apply(const DirectReasoningDelta('')), isFalse);
      expect(accumulator.text, isEmpty);
      expect(accumulator.reasoning, isEmpty);
    });
  });
}

ChatMessage _message({
  required String id,
  required String role,
  required String content,
  List<String>? attachmentIds,
  List<Map<String, dynamic>>? files,
  Map<String, dynamic>? metadata,
}) => ChatMessage(
  id: id,
  role: role,
  content: content,
  timestamp: DateTime.utc(2026, 7, 11),
  attachmentIds: attachmentIds,
  files: files,
  metadata: metadata,
);

String _imageDataUrl(List<int> bytes) =>
    'data:image/png;base64,${base64Encode(bytes)}';

List<String> _textParts(DirectChatMessage message) => message.parts
    .whereType<DirectTextPart>()
    .map((part) => part.text)
    .toList(growable: false);

List<String> _imageParts(DirectChatMessage message) => message.parts
    .whereType<DirectImagePart>()
    .map((part) => part.url)
    .toList(growable: false);
