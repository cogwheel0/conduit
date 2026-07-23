import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/direct_replay_output.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeDirectUsageMetadata', () {
    test('creates a detached deeply immutable JSON value', () {
      final shared = <Object?>[1, 'yes'];
      final source = <String, dynamic>{
        'prompt_tokens': 3,
        'details': <String, dynamic>{'cached': shared, 'reused': shared},
      };

      final normalized = normalizeDirectUsageMetadata(source);
      (source['details'] as Map<String, dynamic>)['cached'] = <Object?>[9];

      expect(normalized['prompt_tokens'], 3);
      final details = normalized['details'] as Map<String, dynamic>;
      final cached = details['cached'] as List<dynamic>;
      final reused = details['reused'] as List<dynamic>;
      expect(cached, <Object?>[1, 'yes']);
      expect(reused, <Object?>[1, 'yes']);
      expect(identical(cached, reused), isFalse);
      expect(() => details['new'] = true, throwsUnsupportedError);
      expect(() => cached.add(2), throwsUnsupportedError);
    });

    test('reports string and node costs for the run-wide budget', () {
      final normalized = normalizeDirectUsageMetadataWithCost({
        'prompt': 'cached',
        'details': <Object?>[true, null],
      });

      expect(normalized.stringCharacters, 19);
      expect(normalized.nodes, 5);
      expect(normalized.usage, {
        'prompt': 'cached',
        'details': <Object?>[true, null],
      });
    });

    test(
      'repeated valid usage exhausts aggregate character and work budgets',
      () {
        final stringHeavy = normalizeDirectUsageMetadataWithCost({
          'abc': 'def',
        });
        final characterBudget = DirectStreamBudget(
          maxCharacters: 10,
          maxEvents: 10,
          maxWorkUnits: 100,
        );
        characterBudget
          ..addCharacters(stringHeavy.stringCharacters)
          ..addWork(stringHeavy.nodes);
        expect(
          () => characterBudget.addCharacters(stringHeavy.stringCharacters),
          throwsA(
            isA<DirectProviderException>().having(
              (error) => error.message,
              'message',
              contains('size limit'),
            ),
          ),
        );

        final nodeHeavy = normalizeDirectUsageMetadataWithCost({
          '': <Object?>[true, null],
        });
        final workBudget = DirectStreamBudget(
          maxCharacters: 10,
          maxEvents: 10,
          maxWorkUnits: nodeHeavy.nodes + 1,
        );
        workBudget.addWork(nodeHeavy.nodes);
        expect(
          () => workBudget.addWork(nodeHeavy.nodes),
          throwsA(
            isA<DirectProviderException>().having(
              (error) => error.message,
              'message',
              contains('resource limit'),
            ),
          ),
        );
      },
    );

    test('rejects cyclic, oversized, deep, and huge-integer graphs', () {
      final cycle = <Object?>[];
      cycle.add(cycle);
      Object? deep = 0;
      for (var index = 0; index < kMaxDirectUsageDepth + 1; index++) {
        deep = <Object?>[deep];
      }
      final cases = <Map<String, dynamic>>[
        {'cycle': cycle},
        {'wide': List<Object?>.filled(kMaxDirectUsageContainerEntries + 1, 0)},
        {'deep': deep},
        {'huge_integer': BigInt.one << (kMaxDirectUsageIntegerBitLength + 1)},
      ];

      for (final usage in cases) {
        expect(
          () => normalizeDirectUsageMetadata(usage),
          throwsA(isA<DirectProviderException>()),
        );
      }
    });
  });

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

  group('decodedImageByteLength', () {
    test('counts padded and unpadded base64 without decoding it', () {
      expect(decodedImageByteLength('data:image/png;base64,AA=='), 1);
      expect(decodedImageByteLength('data:image/png;base64,AQI'), 2);
    });

    test('rejects whitespace and malformed padding', () {
      expect(
        () => decodedImageByteLength('data:image/png;base64,AQ I='),
        throwsA(isA<DirectChatInputException>()),
      );
      expect(
        () => decodedImageByteLength('data:image/png;base64,AA=A'),
        throwsA(isA<DirectChatInputException>()),
      );
    });

    test('preflights the decoded-byte limit', () {
      expect(
        () => decodedImageByteLength(
          'data:image/png;base64,AQI=',
          maxDecodedBytes: 1,
        ),
        throwsA(
          isA<DirectChatInputException>().having(
            (error) => error.message,
            'message',
            contains('too large'),
          ),
        ),
      );
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
          attachmentIds: const ['protected-image'],
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
          return resolvedImage;
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
      expect(resolvedIds, ['protected-image']);
      expect(resolverLimits, [kDirectMaxDecodedImageBytes]);
    });

    test(
      'replays the exact trusted provider answer on the second turn',
      () async {
        const rawAssistantAnswer =
            '  literal <tag data="a&b"> & &lt;existing-entity&gt; '
            '`Map<String, String> values = {"x": "a&b"};`  ';
        final accumulator = DirectStreamingAccumulator()
          ..apply(const DirectContentDelta(rawAssistantAnswer))
          ..apply(const DirectStreamDone());
        final presentationContent = accumulator.render(done: true);

        expect(presentationContent, isNot(rawAssistantAnswer));
        expect(
          presentationContent,
          contains('&lt;tag data=&quot;a&amp;b&quot;&gt;'),
        );
        expect(
          presentationContent,
          contains('&amp;lt;existing-entity&amp;gt;'),
        );
        expect(
          presentationContent,
          contains('`Map<String, String> values = {"x": "a&b"};`'),
        );

        final result = await buildDirectChatMessages(
          messages: [
            _message(id: 'user-1', role: 'user', content: 'First turn'),
            _message(
              id: 'assistant-1',
              role: 'assistant',
              content: presentationContent,
              metadata: const <String, dynamic>{
                'transport': kDirectTransport,
                kDirectRawAssistantContentMetadataKey: rawAssistantAnswer,
              },
            ),
            _message(id: 'user-2', role: 'user', content: 'Second turn'),
          ],
        );

        expect(result.map((message) => message.role), [
          'user',
          'assistant',
          'user',
        ]);
        expect(_textParts(result[1]), [rawAssistantAnswer]);
      },
    );

    test('builds a strict Responses mirror for persisted server history', () {
      const raw = '  literal <tag> & `code`  ';
      final output = directProviderReplayOutput(
        assistantMessageId: 'assistant:one',
        rawContent: raw,
      );

      check(output).isNotNull();
      final item = output!.single;
      check(
        item['id'],
      ).equals('$kConduitDirectReplayOutputIdPrefix${'assistant_one'}');
      check(item['type']).equals('message');
      check(item['role']).equals('assistant');
      check(item['status']).equals('completed');
      check(item['content']).isA<List<dynamic>>().deepEquals([
        {'type': 'output_text', 'text': raw},
      ]);
      check(parseConduitDirectReplayOutput(output)?.text).equals(raw);
      final withToolOutput = <Map<String, dynamic>>[
        {
          'type': 'function_call',
          'id': 'ollama-0-0',
          'call_id': 'ollama-0-0',
          'name': 'web_search',
          'arguments': {'query': 'Ollama Cloud'},
          'status': 'completed',
        },
        {
          'type': 'function_call_output',
          'call_id': 'ollama-0-0',
          'output': {'results': <Map<String, dynamic>>[]},
        },
        ...output,
      ];
      check(parseConduitDirectReplayOutput(withToolOutput)?.text).equals(raw);
      check(
        directProviderReplayOutput(
          assistantMessageId: 'assistant-empty',
          rawContent: '   ',
        ),
      ).isNull();
      final incomplete = directProviderReplayOutput(
        assistantMessageId: 'assistant-incomplete',
        rawContent: '',
        useIncompleteAnswerSentinel: true,
      )!;
      check(
        incomplete.single['id'],
      ).isA<String>().startsWith(kConduitDirectNoFinalReplayOutputIdPrefix);
      check(
        parseConduitDirectReplayOutput(incomplete)?.isIncompleteAnswerSentinel,
      ).equals(true);
    });

    test('reasoning-only replay uses safe provider context', () {
      final message = _message(
        id: 'reasoning-only',
        role: 'assistant',
        content: '<details type="reasoning">private</details>',
        output: directProviderReplayOutput(
          assistantMessageId: 'reasoning-only',
          rawContent: '',
          useIncompleteAnswerSentinel: true,
        ),
        metadata: const <String, dynamic>{
          'transport': kDirectTransport,
          kDirectRawAssistantContentMetadataKey: '',
        },
      );

      expect(
        outboundProviderReplayText(message),
        kConduitDirectIncompleteAnswerReplayText,
      );
    });

    test('a valid output mirror supersedes stale raw replay metadata', () {
      final message = _message(
        id: 'updated-mirror',
        role: 'assistant',
        content: '&lt;stale answer&gt;',
        output: directProviderReplayOutput(
          assistantMessageId: 'updated-mirror',
          rawContent: '<current answer>',
        ),
        metadata: const <String, dynamic>{
          'transport': kDirectTransport,
          kDirectRawAssistantContentMetadataKey: '<stale answer>',
        },
      );

      expect(outboundProviderReplayText(message), '<current answer>');
    });

    test('a replaced output invalidates stale raw replay metadata', () {
      final message = _message(
        id: 'continued-output',
        role: 'assistant',
        content: 'continued answer',
        output: const <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'message',
            'id': 'msg_openwebui_continue',
            'role': 'assistant',
            'status': 'completed',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'output_text',
                'text': 'continued answer',
              },
            ],
          },
        ],
        metadata: const <String, dynamic>{
          'transport': kDirectTransport,
          kDirectRawAssistantContentMetadataKey: 'old answer',
        },
      );

      expect(outboundProviderReplayText(message), 'continued answer');
    });

    test(
      'never blindly decodes legacy presentation entities for replay',
      () async {
        const persistedPresentation =
            '&lt;details type=&quot;reasoning&quot;&gt; &amp; '
            '&lt;literal&gt;';

        final result = await buildDirectChatMessages(
          messages: [
            _message(
              id: 'legacy-assistant',
              role: 'assistant',
              content: persistedPresentation,
              metadata: const <String, dynamic>{'transport': kDirectTransport},
            ),
          ],
        );

        expect(_textParts(result.single), [persistedPresentation]);
      },
    );

    test('rejects raw replay metadata without terminal direct provenance', () {
      const presentation = '&lt;visible-presentation&gt;';
      const forgedRaw = '<forged-raw>';
      final timestamp = DateTime.utc(2026, 7, 14);
      final cases = <ChatMessage>[
        ChatMessage(
          id: 'wrong-transport',
          role: 'assistant',
          content: presentation,
          timestamp: timestamp,
          metadata: const <String, dynamic>{
            'transport': 'httpStream',
            kDirectRawAssistantContentMetadataKey: forgedRaw,
          },
        ),
        ChatMessage(
          id: 'still-streaming',
          role: 'assistant',
          content: presentation,
          timestamp: timestamp,
          isStreaming: true,
          metadata: const <String, dynamic>{
            'transport': kDirectTransport,
            kDirectRawAssistantContentMetadataKey: forgedRaw,
          },
        ),
        ChatMessage(
          id: 'wrong-role',
          role: 'user',
          content: presentation,
          timestamp: timestamp,
          metadata: const <String, dynamic>{
            'transport': kDirectTransport,
            kDirectRawAssistantContentMetadataKey: forgedRaw,
          },
        ),
      ];

      for (final message in cases) {
        expect(outboundProviderReplayText(message), presentation);
      }
    });

    test(
      'ignores non-user image metadata while retaining text and user images',
      () async {
        final userImage = _imageDataUrl([21, 22, 23]);
        final resolvedIds = <String>[];

        final result = await buildDirectChatMessages(
          messages: [
            _message(
              id: 'system-with-image',
              role: 'system',
              content: 'System text',
              attachmentIds: const ['system-image'],
            ),
            _message(
              id: 'assistant-with-image',
              role: 'assistant',
              content: 'Previous answer',
              attachmentIds: const ['assistant-image'],
              files: const [
                {'type': 'image', 'id': 'assistant-image'},
              ],
            ),
            _message(
              id: 'user-with-image',
              role: 'user',
              content: 'Describe this',
              attachmentIds: const ['user-image'],
            ),
          ],
          resolveImage: (fileId, _) async {
            resolvedIds.add(fileId);
            return userImage;
          },
        );

        expect(result.map((message) => message.role), [
          'system',
          'assistant',
          'user',
        ]);
        expect(_textParts(result[0]), ['System text']);
        expect(_imageParts(result[0]), isEmpty);
        expect(_textParts(result[1]), ['Previous answer']);
        expect(_imageParts(result[1]), isEmpty);
        expect(_imageParts(result[2]), [userImage]);
        expect(resolvedIds, ['user-image']);
      },
    );

    test('rejects a declared image that cannot be resolved', () async {
      await expectLater(
        buildDirectChatMessages(
          messages: [
            _message(
              id: 'unavailable-image',
              role: 'user',
              content: 'Describe this',
              files: const [
                {'type': 'image', 'id': 'protected-image'},
              ],
            ),
          ],
          resolveImage: (_, _) async => null,
        ),
        throwsA(
          isA<DirectChatInputException>().having(
            (error) => error.message,
            'message',
            'This direct model does not support this attachment.',
          ),
        ),
      );
    });

    test('rejects a declared image with no reference', () async {
      await expectLater(
        buildDirectChatMessages(
          messages: [
            _message(
              id: 'missing-image-reference',
              role: 'user',
              content: 'Describe this',
              files: const [
                {'type': 'image'},
              ],
            ),
          ],
        ),
        throwsA(isA<DirectChatInputException>()),
      );
    });

    test('rejects a protected image when no resolver is available', () async {
      await expectLater(
        buildDirectChatMessages(
          messages: [
            _message(
              id: 'protected-image',
              role: 'user',
              content: 'Describe this',
              attachmentIds: const ['protected-image'],
            ),
          ],
        ),
        throwsA(isA<DirectChatInputException>()),
      );
    });

    test('skips attachment ids explicitly classified as non-image', () async {
      var resolverCalls = 0;

      final result = await buildDirectChatMessages(
        messages: [
          _message(
            id: 'document-turn',
            role: 'user',
            content: 'Use the earlier document context',
            attachmentIds: const ['document-id'],
            files: const [
              {'type': 'file', 'url': '/api/v1/files/document-id/content'},
            ],
          ),
        ],
        resolveImage: (_, _) async {
          resolverCalls++;
          return null;
        },
      );

      expect(resolverCalls, 0);
      expect(_textParts(result.single), ['Use the earlier document context']);
      expect(_imageParts(result.single), isEmpty);
    });

    test('deduplicates OpenWebUI file ID and content URL aliases', () async {
      final image = _imageDataUrl([16, 17, 18]);
      final resolvedIds = <String>[];

      final result = await buildDirectChatMessages(
        messages: [
          _message(
            id: 'legacy-image-turn',
            role: 'user',
            content: 'Describe this image',
            attachmentIds: const ['abc'],
            files: const [
              {'type': 'image', 'url': '/api/v1/files/abc/content'},
            ],
          ),
        ],
        resolveImage: (id, _) async {
          resolvedIds.add(id);
          return image;
        },
      );

      expect(resolvedIds, ['abc']);
      expect(_imageParts(result.single), [image]);
    });

    test('uses image MIME when OpenWebUI reports type file', () async {
      final image = _imageDataUrl([13, 14, 15]);

      final result = await buildDirectChatMessages(
        messages: [
          _message(
            id: 'mime-image-turn',
            role: 'user',
            content: 'Describe this image',
            attachmentIds: const ['image-id'],
            files: const [
              {
                'type': 'file',
                'content_type': 'image/png',
                'id': 'image-id',
                'url': 'image-id',
              },
            ],
          ),
        ],
        resolveImage: (_, _) async => image,
      );

      expect(_imageParts(result.single), [image]);
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

    test('retains the same image in separate user turns', () async {
      final image = _imageDataUrl([19, 20, 21]);

      final result = await buildDirectChatMessages(
        messages: [
          _message(
            id: 'first-image-turn',
            role: 'user',
            content: 'Describe this image',
            attachmentIds: const ['shared-image'],
          ),
          _message(
            id: 'second-image-turn',
            role: 'user',
            content: 'Describe it again',
            attachmentIds: const ['shared-image'],
          ),
        ],
        resolveImage: (_, _) async => image,
      );

      expect(result, hasLength(2));
      expect(_imageParts(result[0]), [image]);
      expect(_imageParts(result[1]), [image]);
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

    test('projects and persists native direct tool activity', () {
      final accumulator = DirectStreamingAccumulator();
      final started = DirectToolCallStarted(
        id: 'ollama-0-0',
        name: 'web_search',
        arguments: const {'query': 'Ollama Cloud'},
      );

      expect(accumulator.apply(started), isTrue);
      final pending = accumulator.projectStreamingEvent(
        started,
        forceReplace: false,
        canAppend: true,
      );
      expect(pending, isA<DirectStreamingReplace>());
      expect(accumulator.render(done: false), contains('Executing...'));

      final completed = DirectToolCallCompleted(
        id: 'ollama-0-0',
        name: 'web_search',
        arguments: const {'query': 'Ollama Cloud'},
        result: const {
          'results': [
            {'title': 'Ollama Cloud', 'url': 'https://docs.ollama.com/cloud'},
          ],
        },
      );
      expect(accumulator.apply(completed), isTrue);
      expect(accumulator.render(done: false), contains('Tool Executed'));
      expect(accumulator.toolOutput, hasLength(2));
      expect(accumulator.toolOutput.first['type'], 'function_call');
      expect(accumulator.toolOutput.last['type'], 'function_call_output');
      expect(accumulator.toolOutput.last['call_id'], 'ollama-0-0');

      final failed = DirectToolCallCompleted(
        id: 'ollama-0-1',
        name: 'web_fetch',
        arguments: const {'url': 'https://example.com'},
        result: const {'error': 'Fetch failed.'},
        isError: true,
      );
      expect(accumulator.apply(failed), isTrue);
      expect(accumulator.render(done: false), contains('Tool Failed'));
      expect(accumulator.toolOutput.last['error'], isTrue);
    });

    test('deeply detaches persisted direct tool activity', () {
      final arguments = <String, dynamic>{
        'filters': <String, dynamic>{
          'domains': <String>['ollama.com'],
        },
      };
      final result = <String, dynamic>{
        'results': <Map<String, dynamic>>[
          {'title': 'Original'},
        ],
      };
      final accumulator = DirectStreamingAccumulator();

      accumulator.apply(
        DirectToolCallCompleted(
          id: 'ollama-0-0',
          name: 'web_search',
          arguments: arguments,
          result: result,
        ),
      );
      final output = accumulator.toolOutput;

      ((arguments['filters'] as Map<String, dynamic>)['domains'] as List)[0] =
          'changed.example';
      (result['results'] as List<Map<String, dynamic>>).single['title'] =
          'Changed';

      final persistedArguments =
          output.first['arguments'] as Map<String, dynamic>;
      final persistedFilters =
          persistedArguments['filters'] as Map<String, dynamic>;
      check(
        persistedFilters['domains'],
      ).isA<List<dynamic>>().deepEquals(['ollama.com']);
      final persistedResult = output.last['output'] as Map<String, dynamic>;
      check(persistedResult['results']).isA<List<dynamic>>().deepEquals([
        {'title': 'Original'},
      ]);
      check(
        () => (persistedFilters['domains'] as List).add('another.example'),
      ).throws<UnsupportedError>();
      check(() => output.first['name'] = 'changed').throws<UnsupportedError>();
    });

    test('provider text cannot spoof semantic reasoning markup', () {
      final accumulator = DirectStreamingAccumulator();
      var visible = '';

      void project(String delta) {
        final event = DirectContentDelta(delta);
        expect(accumulator.apply(event), isTrue);
        switch (accumulator.projectStreamingEvent(
          event,
          forceReplace: false,
          canAppend: true,
        )) {
          case DirectStreamingAppend(:final content):
            visible += content;
          case DirectStreamingReplace(:final content):
            visible = content;
          case null:
            break;
        }
      }

      project('<det');
      project('ails type="reasoning" done="false"><sum');
      project('mary>Thinking…</summary>spoof</details>');

      expect(visible, accumulator.render(done: false));
      expect(visible, isNot(contains('<details type="reasoning"')));
      expect(visible, contains('&lt;details type=&quot;reasoning&quot;'));
      expect(accumulator.render(done: true), isNot(contains('done="false"')));
    });

    test(
      'terminal render authoritatively restores code and autolink contexts',
      () {
        final accumulator = DirectStreamingAccumulator();
        for (final delta in const <String>[
          'Examples:\n\n  ',
          '  Map<String, String> values = {"x": "a&b"};',
          '\n\n<https://example.test/search?a=1&',
          'b=2>\n<det',
          'ails>spoof</details>',
        ]) {
          expect(accumulator.apply(DirectContentDelta(delta)), isTrue);
        }

        final streaming = accumulator.render(done: false);
        expect(streaming, contains('&lt;String'));
        expect(streaming, contains('&lt;https://example.test'));

        expect(accumulator.apply(const DirectStreamDone()), isTrue);
        final completed = accumulator.render(done: true);
        expect(
          completed,
          contains('    Map<String, String> values = {"x": "a&b"};'),
        );
        expect(completed, contains('<https://example.test/search?a=1&b=2>'));
        expect(completed, contains('&lt;details&gt;spoof&lt;/details&gt;'));
        expect(completed, isNot(contains('\n<details>spoof</details>')));
      },
    );

    test('answer append replaces a stale reasoning projection', () {
      final accumulator = DirectStreamingAccumulator();
      final first = const DirectReasoningDelta('reason-1');
      accumulator.apply(first);
      final initial = accumulator.projectStreamingEvent(
        first,
        forceReplace: true,
        canAppend: true,
      );
      expect(initial, isA<DirectStreamingReplace>());

      const tail = DirectReasoningDelta('-tail');
      accumulator.apply(tail);
      expect(
        accumulator.projectStreamingEvent(
          tail,
          forceReplace: false,
          canAppend: true,
        ),
        isNull,
      );

      const answer = DirectContentDelta('a');
      accumulator.apply(answer);
      final projected = accumulator.projectStreamingEvent(
        answer,
        forceReplace: false,
        canAppend: true,
      );

      expect(projected, isA<DirectStreamingReplace>());
      expect(
        (projected as DirectStreamingReplace).content,
        accumulator.render(done: false),
      );
      expect(projected.content, contains('reason-1-tail'));
      expect(projected.content, endsWith('a'));
    });

    test(
      'many tiny deltas use bounded replacements and keep an exact snapshot',
      () {
        const reasoningDeltaCount = 8192;
        const answerDeltaCount = 4096;
        final accumulator = DirectStreamingAccumulator();
        StringBuffer? visible;

        void project(DirectStreamEvent event, {bool forceReplace = false}) {
          expect(accumulator.apply(event), isTrue);
          final projection = accumulator.projectStreamingEvent(
            event,
            forceReplace: forceReplace,
            canAppend: true,
          );
          switch (projection) {
            case DirectStreamingAppend():
              visible!.write(projection.content);
              break;
            case DirectStreamingReplace():
              visible = StringBuffer(projection.content);
              break;
            case null:
              break;
          }
        }

        for (var index = 0; index < reasoningDeltaCount; index++) {
          project(const DirectReasoningDelta('r'), forceReplace: index == 0);
        }
        for (var index = 0; index < answerDeltaCount; index++) {
          project(const DirectContentDelta('a'));
        }

        // Powers-of-two reasoning projections materialize less than three
        // final reasoning buffers in aggregate (including semantic markup),
        // instead of one ever-growing replacement per provider event.
        expect(accumulator.fullProjectionCount, lessThanOrEqualTo(14));
        expect(
          accumulator.fullProjectionCharacterCount,
          lessThan(reasoningDeltaCount * 3),
        );
        expect(accumulator.appendProjectionCount, answerDeltaCount);
        expect(visible.toString(), accumulator.render(done: false));

        expect(accumulator.apply(const DirectStreamDone()), isTrue);
        final completed = accumulator.render(done: true);
        final expected = DirectStreamingAccumulator()
          ..apply(
            DirectReasoningDelta(
              List<String>.filled(reasoningDeltaCount, 'r').join(),
            ),
          )
          ..apply(
            DirectContentDelta(
              List<String>.filled(answerDeltaCount, 'a').join(),
            ),
          )
          ..apply(const DirectStreamDone());
        expect(completed, expected.render(done: true));
      },
    );
  });
}

ChatMessage _message({
  required String id,
  required String role,
  required String content,
  List<String>? attachmentIds,
  List<Map<String, dynamic>>? files,
  List<Map<String, dynamic>>? output,
  Map<String, dynamic>? metadata,
}) => ChatMessage(
  id: id,
  role: role,
  content: content,
  timestamp: DateTime.utc(2026, 7, 11),
  attachmentIds: attachmentIds,
  files: files,
  output: output,
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
