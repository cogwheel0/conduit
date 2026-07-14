import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_session.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit/features/hermes/utils/hermes_time_parsing.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CaptureInterceptor extends Interceptor {
  _CaptureInterceptor(this.responseFor);

  /// Maps a request path to its canned response payload.
  final Object? Function(RequestOptions) responseFor;
  final List<RequestOptions> requests = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(
      Response<dynamic>(
        requestOptions: options,
        data: responseFor(options),
        statusCode: 200,
      ),
    );
  }
}

HermesApiService _service(_CaptureInterceptor capture) {
  final dio = Dio()..interceptors.add(capture);
  return HermesApiService(
    config: const HermesConfig(
      enabled: true,
      baseUrl: 'http://host:8642/v1',
      apiKey: 'k',
    ),
    dio: dio,
  );
}

class _FixedHermesConfigController extends HermesConfigController {
  _FixedHermesConfigController(this._config);

  final HermesConfig _config;

  @override
  HermesConfig build() => _config;
}

class _RotatableHermesConfigController extends _FixedHermesConfigController {
  _RotatableHermesConfigController(super.config);

  var _epoch = 0;

  @override
  int? captureSessionActionAdmission() => _epoch;

  @override
  bool sessionActionAdmissionIsCurrent(int admission) => admission == _epoch;

  void rotate() => _epoch++;
}

final class _HermesServiceGeneration extends Notifier<HermesApiService?> {
  _HermesServiceGeneration(this.initial);

  final HermesApiService? initial;

  @override
  HermesApiService? build() => initial;

  void set(HermesApiService? service) => state = service;
}

class _FailingForkHistoryService extends HermesApiService {
  _FailingForkHistoryService({required super.config});

  int deleteCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> listSessions() async => const [];

  @override
  Future<String> forkSession(String id) async => 'fork-target';

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) async {
    if (id == 'fork-source') {
      return const [
        {'id': 'source-message', 'role': 'user', 'content': 'Question'},
      ];
    }
    throw StateError('target history unavailable');
  }

  @override
  Future<void> deleteSession(String id, {CancelToken? cancelToken}) async {
    deleteCalls++;
  }
}

class _DeleteTrackingHermesService extends HermesApiService {
  _DeleteTrackingHermesService({
    required super.config,
    this.beforeDelete,
    this.failure,
  });

  final void Function()? beforeDelete;
  final Object? failure;
  int deleteCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> listSessions() async => const [];

  @override
  Future<void> deleteSession(String id, {CancelToken? cancelToken}) async {
    deleteCalls++;
    beforeDelete?.call();
    final error = failure;
    if (error != null) throw error;
  }
}

void main() {
  group('parseHermesTimestamp', () {
    test(
      'parses epoch seconds, milliseconds, and numeric strings identically',
      () {
        const epochMilliseconds = 1781947724528;

        check(
          parseHermesTimestamp(1781947724.528)!.millisecondsSinceEpoch,
        ).equals(epochMilliseconds);
        check(
          parseHermesTimestamp(epochMilliseconds)!.millisecondsSinceEpoch,
        ).equals(epochMilliseconds);
        check(
          parseHermesTimestamp('1781947724.528')!.millisecondsSinceEpoch,
        ).equals(epochMilliseconds);
      },
    );

    test('parses ISO-8601 values and rejects invalid values', () {
      check(
        parseHermesTimestamp('2026-06-20T10:00:00Z'),
      ).equals(DateTime.utc(2026, 6, 20, 10));
      check(parseHermesTimestamp('not-a-timestamp')).isNull();
      check(parseHermesTimestamp(null)).isNull();
    });
  });

  group('HermesApiService sessions', () {
    test('createSession posts title and returns id', () async {
      final capture = _CaptureInterceptor((_) => {'id': 's1'});
      final id = await _service(capture).createSession(title: 'Hello');
      final req = capture.requests.single;
      check(req.method).equals('POST');
      check(req.path).equals('http://host:8642/api/sessions');
      check((req.data as Map)['title']).equals('Hello');
      check(req.responseType).equals(ResponseType.stream);
      check(id).equals('s1');
    });

    test('createSession rejects structured and unsafe identifiers', () async {
      final invalidIds = <Object?>[
        {
          'nested': ['session'],
        },
        List<String>.filled(
          kMaxHermesOpaqueIdentifierCharacters + 1,
          'a',
        ).join(),
        'session\ncontrol',
        'prefix-k-suffix',
      ];

      for (final invalidId in invalidIds) {
        final capture = _CaptureInterceptor((_) => {'id': invalidId});
        await check(
          _service(capture).createSession(),
        ).throws<FormatException>();
      }
    });

    test('createSession bounds its streamed response body', () async {
      final cancelToken = CancelToken();
      final capture = _CaptureInterceptor(
        (_) => ResponseBody.fromString(
          jsonEncode({
            'id': List<String>.filled(
              kMaxHermesCreateResponseBytes,
              'x',
            ).join(),
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );

      await check(
        _service(capture).createSession(cancelToken: cancelToken),
      ).throws<FormatException>();

      check(cancelToken.isCancelled).isTrue();
      check(hermesCancellationWasInternal(cancelToken)).isTrue();
    });

    test('fork hits the fork path and returns the new id', () async {
      final capture = _CaptureInterceptor(
        (_) => {
          'session': {'id': 's2'},
        },
      );
      final id = await _service(capture).forkSession('s1');
      check(
        capture.requests.single.path,
      ).equals('http://host:8642/api/sessions/s1/fork');
      check(id).equals('s2');
    });

    test('rename and delete target the right paths', () async {
      final capture = _CaptureInterceptor((_) => {});
      final service = _service(capture);
      final deleteCancelToken = CancelToken();
      await service.renameSession('s1', 'New');
      await service.deleteSession('s1', cancelToken: deleteCancelToken);
      check(capture.requests[0].method).equals('PATCH');
      check(
        capture.requests[0].path,
      ).equals('http://host:8642/api/sessions/s1');
      check((capture.requests[0].data as Map)['title']).equals('New');
      check(capture.requests[1].method).equals('DELETE');
      check(capture.requests[1].cancelToken).identicalTo(deleteCancelToken);
    });

    test('session ids are encoded as single path segments', () async {
      final capture = _CaptureInterceptor((request) {
        if (request.path.endsWith('/fork')) return {'id': 'branched'};
        return const <String, dynamic>{};
      });
      final service = _service(capture);
      const sessionId = 's/1+abc=';
      const encoded = 's%2F1%2Babc%3D';
      final historyCancelToken = CancelToken();

      await service.getSessionMessages(
        sessionId,
        cancelToken: historyCancelToken,
      );
      await service.renameSession(sessionId, 'New');
      await service.deleteSession(sessionId);
      check(await service.forkSession(sessionId)).equals('branched');

      check(
        capture.requests[0].path,
      ).equals('http://host:8642/api/sessions/$encoded/messages');
      check(capture.requests[0].cancelToken).identicalTo(historyCancelToken);
      check(
        capture.requests[1].path,
      ).equals('http://host:8642/api/sessions/$encoded');
      check(
        capture.requests[2].path,
      ).equals('http://host:8642/api/sessions/$encoded');
      check(
        capture.requests[3].path,
      ).equals('http://host:8642/api/sessions/$encoded/fork');
    });
  });

  group('HermesSessionSummary.fromJson', () {
    test('parses id/title and skips entries without an id', () {
      check(HermesSessionSummary.fromJson({'name': 'no id'})).isNull();
      final s = HermesSessionSummary.fromJson({
        'id': 's1',
        'title': 'Trip planning',
        'updated_at': '2026-06-20T10:00:00Z',
      });
      check(s).isNotNull();
      check(s!.title).equals('Trip planning');
      check(s.updatedAt).isNotNull();
    });

    test('falls back to a placeholder title', () {
      final s = HermesSessionSummary.fromJson({'id': 's1'});
      check(s!.title).equals('Untitled session');
    });
  });

  group('hermesMessagesToChatMessages', () {
    test('replaces null and empty message ids with non-empty UUIDs', () {
      final messages = hermesMessagesToChatMessages([
        {'id': null, 'role': 'user', 'content': 'Null id'},
        {'id': '', 'role': 'assistant', 'content': 'Empty id'},
        {'id': '   ', 'role': 'user', 'content': 'Blank id'},
        {'id': 'server-id', 'role': 'assistant', 'content': 'Preserved id'},
      ]);

      check(messages).has((items) => items.length, 'length').equals(4);
      for (final message in messages.take(3)) {
        check(message.id).isNotEmpty();
      }
      check(
        messages.take(3).map((message) => message.id).toSet(),
      ).has((ids) => ids.length, 'unique generated ids').equals(3);
      check(messages.last.id).equals('server-id');
    });

    test('maps user/assistant rows and skips system/empty', () {
      final messages = hermesMessagesToChatMessages([
        {'role': 'system', 'content': 'ignored'},
        {'role': 'user', 'content': 'Hi'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'Hello '},
            {'type': 'output_text', 'text': 'there'},
          ],
        },
        {'role': 'assistant', 'content': ''},
      ], modelId: 'hermes:agent:default');

      check(messages).has((m) => m.length, 'length').equals(2);
      check(messages[0].role).equals('user');
      check(messages[0].content).equals('Hi');
      check(messages[1].role).equals('assistant');
      check(messages[1].content).equals('Hello there');
      check(messages[1].model).equals('hermes:agent:default');
    });

    test('preserves explicit run/response ids for regeneration branches', () {
      final messages = hermesMessagesToChatMessages([
        {'role': 'assistant', 'content': 'One', 'run_id': 'run-1'},
        {'role': 'assistant', 'content': 'Two', 'response_id': 'response-2'},
        {'role': 'assistant', 'content': 'Three', 'responseId': 'response-3'},
      ]);

      check(messages[0].metadata?['hermesRunId']).equals('run-1');
      check(messages[0].metadata?['hermesResponseId']).isNull();
      check(messages[1].metadata?['hermesResponseId']).equals('response-2');
      check(messages[2].metadata?['hermesResponseId']).equals('response-3');
      check(
        messages
            .sublist(1)
            .map((message) => message.metadata?['hermesTransportMode']),
      ).deepEquals(['responses', 'responses']);
    });

    test('restores typed image parts alongside their text', () {
      const pngDataUrl = 'data:image/png;base64,AQID';
      const jpegDataUrl = 'data:image/jpeg;base64,BAUG';
      const remoteImageUrl = 'https://images.example.com/photo.webp';
      final messages = hermesMessagesToChatMessages([
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'Compare '},
            {
              'type': 'image_url',
              'image_url': {'url': pngDataUrl},
            },
            {'type': 'input_image', 'image_url': jpegDataUrl},
            {'type': 'input_image', 'url': remoteImageUrl},
            {
              // Older history rows can omit the part type.
              'image_url': {'url': pngDataUrl},
            },
            {'type': 'text', 'text': 'these'},
          ],
        },
      ]);

      check(messages).has((m) => m.length, 'length').equals(1);
      final message = messages.single;
      check(message.content).equals('Compare these');
      check(
        message.attachmentIds!,
      ).deepEquals([pngDataUrl, jpegDataUrl, remoteImageUrl]);
      check(message.files!).deepEquals([
        {'type': 'image', 'url': pngDataUrl, 'content_type': 'image/png'},
        {'type': 'image', 'url': jpegDataUrl, 'content_type': 'image/jpeg'},
        {'type': 'image', 'url': remoteImageUrl},
      ]);
    });

    test('preserves image-only user rows in map and string forms', () {
      const mapImage = 'data:image/webp;base64,AQID';
      const stringImage = 'data:image/png;base64,BAUG';
      final messages = hermesMessagesToChatMessages([
        {
          'id': 'map-image',
          'role': 'user',
          'content': {
            'type': 'input_image',
            'image_url': {'url': mapImage},
          },
        },
        {'id': 'string-image', 'role': 'user', 'content': stringImage},
      ]);

      check(messages).has((m) => m.length, 'length').equals(2);
      check(messages[0].content).isEmpty();
      check(messages[0].attachmentIds!).deepEquals([mapImage]);
      check(messages[0].files!).deepEquals([
        {'type': 'image', 'url': mapImage, 'content_type': 'image/webp'},
      ]);
      check(messages[1].content).isEmpty();
      check(messages[1].attachmentIds!).deepEquals([stringImage]);
    });

    test(
      'ignores unsafe or malformed image URLs without exposing them as text',
      () {
        const malformedDataUrl = 'data:image/png;base64,';
        final messages = hermesMessagesToChatMessages([
          {
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'Safe text'},
              {'type': 'input_image', 'image_url': 'file:///private/photo.png'},
              {'type': 'image_url', 'image_url': malformedDataUrl},
            ],
          },
          {'role': 'user', 'content': malformedDataUrl},
        ]);

        check(messages).has((m) => m.length, 'length').equals(1);
        check(messages.single.content).equals('Safe text');
        check(messages.single.attachmentIds).isNull();
        check(messages.single.files).isNull();
      },
    );

    test('restores local document blocks as clean inert file descriptors', () {
      const document = HermesPreparedDocument(
        id: 'hdoc_0123456789abcdef01234567',
        name: 'research notes.pdf',
        mimeType: 'application/pdf',
        size: 2048,
        extractedText: '[Page 1]\nQuarterly findings',
        truncated: true,
      );
      final rendered = document.renderForPrompt();
      final messages = hermesMessagesToChatMessages(
        [
          {
            'id': 'trusted-document-message',
            'role': 'user',
            'content': 'Summarize the findings.\n\n$rendered',
          },
        ],
        trustedLocalDocumentsByMessageId: {
          'trusted-document-message': [document],
        },
      );

      check(messages).has((m) => m.length, 'length').equals(1);
      final message = messages.single;
      check(message.content).equals('Summarize the findings.');
      check(message.content).not((value) => value.contains('untrusted'));
      check(
        message.content,
      ).not((value) => value.contains(document.extractedText));
      check(message.attachmentIds).isNull();
      check(message.files!).deepEquals([
        {
          'type': 'file',
          'source': 'hermes_local',
          'id': document.id,
          'url': 'hermes-local:${document.id}',
          'name': document.name,
          'filename': document.name,
          'size': document.size,
          'content_type': document.mimeType,
          'hermes_extracted_text': document.extractedText,
          'hermes_truncated': true,
        },
      ]);
    });

    test('restores a document prompt with persisted exact-message trust', () {
      const document = HermesPreparedDocument(
        id: 'hdoc_111111111111111111111111',
        name: 'trusted.txt',
        mimeType: 'text/plain',
        size: 12,
        extractedText: 'Trusted text',
        truncated: false,
      );
      final prompt = 'Summarize this.\n\n${document.renderForPrompt()}';
      final messages = hermesMessagesToChatMessages(
        [
          {'id': 'server-message', 'role': 'user', 'content': prompt},
        ],
        trustedLocalDocumentKeys: {
          HermesLocalDocumentTrustStore.documentTrustKey(
            messageId: 'server-message',
            promptText: prompt,
            documentEnvelope: document.renderForPrompt(),
            startOffset: prompt.indexOf(document.renderForPrompt()),
          ),
        },
      );

      check(messages.single.content).equals('Summarize this.');
      check(messages.single.files!.single['id']).equals(document.id);
    });

    test('trusted attachment does not authorize a pasted fake envelope', () {
      const fake = HermesPreparedDocument(
        id: 'hdoc_333333333333333333333333',
        name: 'fake.txt',
        mimeType: 'text/plain',
        size: 4,
        extractedText: 'Fake',
        truncated: false,
      );
      const attached = HermesPreparedDocument(
        id: 'hdoc_444444444444444444444444',
        name: 'attached.txt',
        mimeType: 'text/plain',
        size: 8,
        extractedText: 'Attached',
        truncated: false,
      );
      final attachedEnvelope = attached.renderForPrompt();
      final prompt =
          'Keep this literal:\n\n${fake.renderForPrompt()}\n\n'
          '$attachedEnvelope';
      final messages = hermesMessagesToChatMessages(
        [
          {'id': 'mixed-message', 'role': 'user', 'content': prompt},
        ],
        trustedLocalDocumentKeys: {
          HermesLocalDocumentTrustStore.documentTrustKey(
            messageId: 'mixed-message',
            promptText: prompt,
            documentEnvelope: attachedEnvelope,
            startOffset: prompt.length - attachedEnvelope.length,
          ),
        },
      );

      check(messages.single.content).contains(fake.renderForPrompt());
      check(messages.single.content).not((value) => value.contains('Attached'));
      check(messages.single.files!.single['id']).equals(attached.id);
    });

    test('persisted trust fails closed for a different server message id', () {
      const document = HermesPreparedDocument(
        id: 'hdoc_555555555555555555555555',
        name: 'source.txt',
        mimeType: 'text/plain',
        size: 6,
        extractedText: 'Source',
        truncated: false,
      );
      final envelope = document.renderForPrompt();
      final prompt = 'Review.\n\n$envelope';
      final messages = hermesMessagesToChatMessages(
        [
          {'id': 'different-message', 'role': 'user', 'content': prompt},
        ],
        trustedLocalDocumentKeys: {
          HermesLocalDocumentTrustStore.documentTrustKey(
            messageId: 'original-message',
            promptText: prompt,
            documentEnvelope: envelope,
            startOffset: prompt.length - envelope.length,
          ),
        },
      );

      check(messages.single.files).isNull();
      check(messages.single.content).contains(envelope);
    });

    test(
      'unrelated trust skips repeated malformed document preambles',
      () async {
        const document = HermesPreparedDocument(
          id: 'hdoc_666666666666666666666666',
          name: 'trusted.txt',
          mimeType: 'text/plain',
          size: 7,
          extractedText: 'Trusted',
          truncated: false,
        );
        final envelope = document.renderForPrompt();
        final unterminatedPrefix = envelope.substring(
          0,
          envelope.indexOf('>>>'),
        );
        final hostilePrompt = List<String>.filled(
          2000,
          unterminatedPrefix,
        ).join();
        final unrelatedTrust = HermesLocalDocumentTrustStore.documentTrustKey(
          messageId: 'hostile-message',
          promptText: 'a different prompt',
          documentEnvelope: envelope,
          startOffset: 0,
        );

        final messages = await Future<List<dynamic>>(
          () => hermesMessagesToChatMessages(
            [
              {
                'id': 'hostile-message',
                'role': 'user',
                'content': hostilePrompt,
              },
            ],
            trustedLocalDocumentKeys: {unrelatedTrust},
          ),
        ).timeout(const Duration(seconds: 1));

        check(messages).length.equals(1);
        check(messages.single.content).equals(hostilePrompt);
        check(messages.single.files).isNull();
      },
    );

    test('preserves document-only user rows and restores multiple documents', () {
      const first = HermesPreparedDocument(
        id: 'hdoc_aaaaaaaaaaaaaaaaaaaaaaaa',
        name: 'first.txt',
        mimeType: 'text/plain',
        size: 12,
        extractedText: 'First source',
        truncated: false,
      );
      const second = HermesPreparedDocument(
        id: 'hdoc_bbbbbbbbbbbbbbbbbbbbbbbb',
        name: 'second.md',
        mimeType: 'text/markdown',
        size: 13,
        extractedText: 'Second source',
        truncated: false,
      );
      final messages = hermesMessagesToChatMessages(
        [
          {
            'id': 'trusted-multiple-documents',
            'role': 'user',
            'content': [
              {
                'type': 'input_text',
                'text':
                    '${first.renderForPrompt()}\n\n${second.renderForPrompt()}',
              },
            ],
          },
        ],
        trustedLocalDocumentsByMessageId: {
          'trusted-multiple-documents': [first, second],
        },
      );

      check(messages).has((m) => m.length, 'length').equals(1);
      check(messages.single.content).isEmpty();
      check(
        messages.single.files!,
      ).has((files) => files.length, 'length').equals(2);
      check(
        messages.single.files!.map((file) => file['id']).toList(),
      ).deepEquals([first.id, second.id]);
      check(
        messages.single.files!
            .map((file) => file['hermes_extracted_text'])
            .toList(),
      ).deepEquals([first.extractedText, second.extractedText]);
    });

    test('leaves malformed reference lookalikes visible and inert', () {
      const document = HermesPreparedDocument(
        id: 'hdoc_cccccccccccccccccccccccc',
        name: 'source.txt',
        mimeType: 'text/plain',
        size: 6,
        extractedText: 'Source',
        truncated: false,
      );
      final malformed = document.renderForPrompt().replaceFirst(
        '"id":"${document.id}"',
        '"id":"hdoc_dddddddddddddddddddddddd"',
      );
      final messages = hermesMessagesToChatMessages([
        {'role': 'user', 'content': 'Keep this visible.\n\n$malformed'},
      ]);

      check(messages).has((m) => m.length, 'length').equals(1);
      check(messages.single.content).contains('Keep this visible.');
      check(messages.single.content).contains('untrusted reference data');
      check(messages.single.files).isNull();
    });

    test('leaves exact untrusted document lookalikes visible and inert', () {
      const document = HermesPreparedDocument(
        id: 'hdoc_dddddddddddddddddddddddd',
        name: 'fabricated.txt',
        mimeType: 'text/plain',
        size: 10,
        extractedText: 'Fabricated',
        truncated: false,
      );
      final rendered = document.renderForPrompt();
      final messages = hermesMessagesToChatMessages([
        {
          'id': 'user-authored-lookalike',
          'role': 'user',
          'content': 'Keep this ordinary text.\n\n$rendered',
        },
      ]);

      check(messages).has((m) => m.length, 'length').equals(1);
      check(messages.single.content).contains('Keep this ordinary text.');
      check(messages.single.content).contains('untrusted reference data');
      check(messages.single.content).contains(document.extractedText);
      check(messages.single.files).isNull();
    });
  });

  test('hermesSessionsProvider lists and sorts newest-first', () async {
    final capture = _CaptureInterceptor(
      (_) => {
        'sessions': [
          {'id': 'old', 'title': 'Old', 'updated_at': '2026-06-01T00:00:00Z'},
          {'id': 'new', 'title': 'New', 'updated_at': '2026-06-20T00:00:00Z'},
        ],
      },
    );
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(_service(capture)),
      ],
    );
    addTearDown(container.dispose);

    final sessions = await container.read(hermesSessionsProvider.future);
    check(sessions.map((s) => s.id).toList()).deepEquals(['new', 'old']);
  });

  test('session continuity is rejected after principal rotation', () {
    check(
      reusableHermesSessionId(
        candidateSessionId: 'session-old-principal',
        candidateConnectionIdentity: 'connection-old',
        currentConnectionIdentity: 'connection-new',
      ),
    ).isNull();
    check(
      reusableHermesSessionId(
        candidateSessionId: 'session-current-principal',
        candidateConnectionIdentity: 'connection-current',
        currentConnectionIdentity: 'connection-current',
      ),
    ).equals('session-current-principal');
  });

  test('fork history alignment maps only exact ordered rows', () {
    final source = <Map<String, dynamic>>[
      {'id': '10', 'role': 'user', 'content': 'same prompt'},
      {'id': '11', 'role': 'assistant', 'content': 'same answer'},
    ];
    final target = <Map<String, dynamic>>[
      {'id': '20', 'role': 'user', 'content': 'same prompt'},
      {'id': '21', 'role': 'assistant', 'content': 'same answer'},
    ];

    check(
      alignHermesForkedMessageIds(source, target),
    ).isNotNull().deepEquals(<String, String>{'10': '20', '11': '21'});
    check(
      alignHermesForkedMessageIds(source, <Map<String, dynamic>>[target.first]),
    ).isNull();
    check(
      alignHermesForkedMessageIds(source, <Map<String, dynamic>>[
        target.first,
        {...target.last, 'content': 'different answer'},
      ]),
    ).isNull();
    check(
      alignHermesForkedMessageIds(source, <Map<String, dynamic>>[
        target.first,
        {...target.last, 'id': '20'},
      ]),
    ).isNull();
  });

  test('fork history failure purges stale target document trust', () async {
    const principalId = '11111111-1111-4111-8111-111111111111';
    const config = HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example/v1',
      apiKey: 'test-key',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      PreferenceKeys.hermesLocalDocumentTrustPrincipal: principalId,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    addTearDown(() {
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      PreferencesStore.debugReset();
    });

    final endpointIdentity = HermesConfigController.connectionEndpoint(
      config.baseUrl,
    )!;
    final connectionIdentity = HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: endpointIdentity,
      principalId: principalId,
    );
    const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_TEST>>>';
    const prompt = 'Question\n\n$envelope';
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: connectionIdentity,
      sessionId: 'fork-source',
      messageId: 'source-message',
      promptText: prompt,
      documentEnvelopes: const [envelope],
    );
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: connectionIdentity,
      sessionId: 'fork-target',
      messageId: 'stale-target-message',
      promptText: prompt,
      documentEnvelopes: const [envelope],
    );

    final service = _FailingForkHistoryService(config: config);
    final container = ProviderContainer(
      overrides: [
        hermesConfigProvider.overrideWith(
          () => _FixedHermesConfigController(config),
        ),
        hermesApiServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);

    check(
      await container.read(hermesSessionsProvider.notifier).fork('fork-source'),
    ).equals('fork-target');
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: connectionIdentity,
        sessionId: 'fork-target',
      ),
    ).isEmpty();
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: connectionIdentity,
        sessionId: 'fork-source',
      ),
    ).isNotEmpty();
  });

  test('fork fails closed when stale target trust cannot be purged', () async {
    const principalId = '55555555-5555-4555-8555-555555555555';
    const config = HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example/v1',
      apiKey: 'test-key',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      PreferenceKeys.hermesLocalDocumentTrustPrincipal: principalId,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    addTearDown(() {
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      PreferencesStore.debugReset();
    });

    final connectionIdentity = HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: HermesConfigController.connectionEndpoint(
        config.baseUrl,
      )!,
      principalId: principalId,
    );
    const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_FORK_FAIL>>>';
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: connectionIdentity,
      sessionId: 'fork-target',
      messageId: 'stale-target-message',
      promptText: 'Question\n\n$envelope',
      documentEnvelopes: const <String>[envelope],
    );
    PreferencesStore.debugOverride(
      PreferencesStore.instance,
      writeInterceptor: (preferences, key, value) async =>
          key == PreferenceKeys.hermesLocalDocumentTrust ? false : null,
    );

    final service = _FailingForkHistoryService(config: config);
    final container = ProviderContainer(
      overrides: [
        hermesConfigProvider.overrideWith(
          () => _FixedHermesConfigController(config),
        ),
        hermesApiServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);

    check(
      await container.read(hermesSessionsProvider.notifier).fork('fork-source'),
    ).isNull();
    check(service.deleteCalls).equals(1);

    // The failed write leaves the stale record durable. The fork must not be
    // exposed because the in-memory scope block disappears after a restart.
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: connectionIdentity,
        sessionId: 'fork-target',
      ),
    ).isNotEmpty();
  });

  test(
    'session delete durably revokes trust before an ambiguous request failure',
    () async {
      const principalId = '22222222-2222-4222-8222-222222222222';
      const config = HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example/v1',
        apiKey: 'test-key',
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.hermesLocalDocumentTrustPrincipal: principalId,
      });
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      addTearDown(() {
        HermesLocalDocumentTrustStore.debugResetRuntimeState();
        PreferencesStore.debugReset();
      });
      final connectionIdentity =
          HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: HermesConfigController.connectionEndpoint(
              config.baseUrl,
            )!,
            principalId: principalId,
          );
      const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_DELETE>>>';
      await HermesLocalDocumentTrustStore.remember(
        connectionIdentity: connectionIdentity,
        sessionId: 'delete-session',
        messageId: 'delete-message',
        promptText: 'Question\n\n$envelope',
        documentEnvelopes: const <String>[envelope],
      );
      var durableTrustWasEmptyAtDelete = false;
      final service = _DeleteTrackingHermesService(
        config: config,
        failure: StateError('response lost after delete'),
        beforeDelete: () {
          durableTrustWasEmptyAtDelete =
              (PreferencesStore.getStringList(
                        PreferenceKeys.hermesLocalDocumentTrust,
                      ) ??
                      const <String>[])
                  .isEmpty;
        },
      );
      final container = ProviderContainer(
        overrides: [
          hermesConfigProvider.overrideWith(
            () => _FixedHermesConfigController(config),
          ),
          hermesApiServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      await container.read(hermesSessionsProvider.future);

      await check(
        container
            .read(hermesSessionsProvider.notifier)
            .delete('delete-session'),
      ).throws<StateError>();

      check(service.deleteCalls).equals(1);
      check(durableTrustWasEmptyAtDelete).isTrue();
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: connectionIdentity,
          sessionId: 'delete-session',
        ),
      ).isEmpty();
    },
  );

  test(
    'session delete does not cross a server rotation during trust purge',
    () async {
      const principalId = '44444444-4444-4444-8444-444444444444';
      const oldConfig = HermesConfig(
        enabled: true,
        baseUrl: 'https://old-hermes.example/v1',
        apiKey: 'old-key',
      );
      const replacementConfig = HermesConfig(
        enabled: true,
        baseUrl: 'https://replacement-hermes.example/v1',
        apiKey: 'replacement-key',
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferenceKeys.hermesLocalDocumentTrustPrincipal: principalId,
      });
      PreferencesStore.debugOverride(await SharedPreferences.getInstance());
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      final purgeStarted = Completer<void>();
      final allowPurge = Completer<void>();
      addTearDown(() {
        if (!allowPurge.isCompleted) allowPurge.complete();
        HermesLocalDocumentTrustStore.debugResetRuntimeState();
        PreferencesStore.debugReset();
      });
      final oldConnectionIdentity =
          HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: HermesConfigController.connectionEndpoint(
              oldConfig.baseUrl,
            )!,
            principalId: principalId,
          );
      const envelope =
          '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_DELETE_ROTATION>>>';
      await HermesLocalDocumentTrustStore.remember(
        connectionIdentity: oldConnectionIdentity,
        sessionId: 'rotating-delete-session',
        messageId: 'rotating-delete-message',
        promptText: 'Question\n\n$envelope',
        documentEnvelopes: const <String>[envelope],
      );
      PreferencesStore.debugOverride(
        PreferencesStore.instance,
        writeInterceptor: (preferences, key, value) async {
          if (key == PreferenceKeys.hermesLocalDocumentTrust) {
            if (!purgeStarted.isCompleted) purgeStarted.complete();
            await allowPurge.future;
          }
          return null;
        },
      );
      final oldService = _DeleteTrackingHermesService(config: oldConfig);
      final replacementService = _DeleteTrackingHermesService(
        config: replacementConfig,
      );
      final configController = _RotatableHermesConfigController(oldConfig);
      final serviceGeneration =
          NotifierProvider<_HermesServiceGeneration, HermesApiService?>(
            () => _HermesServiceGeneration(oldService),
          );
      final container = ProviderContainer(
        overrides: [
          hermesConfigProvider.overrideWith(() => configController),
          hermesApiServiceProvider.overrideWith(
            (ref) => ref.watch(serviceGeneration),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(hermesSessionsProvider.future);

      final deletion = container
          .read(hermesSessionsProvider.notifier)
          .delete('rotating-delete-session');
      await purgeStarted.future.timeout(const Duration(seconds: 1));
      configController.rotate();
      container.read(serviceGeneration.notifier).set(replacementService);
      allowPurge.complete();
      check(await deletion.timeout(const Duration(seconds: 1))).isFalse();

      check(oldService.deleteCalls).equals(0);
      check(replacementService.deleteCalls).equals(0);
      check(
        PreferencesStore.getStringList(
              PreferenceKeys.hermesLocalDocumentTrust,
            ) ??
            const <String>[],
      ).isEmpty();
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: oldConnectionIdentity,
          sessionId: 'rotating-delete-session',
        ),
      ).isEmpty();
    },
  );

  test('session delete is not sent when durable trust purge fails', () async {
    const principalId = '33333333-3333-4333-8333-333333333333';
    const config = HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example/v1',
      apiKey: 'test-key',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      PreferenceKeys.hermesLocalDocumentTrustPrincipal: principalId,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    addTearDown(() {
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      PreferencesStore.debugReset();
    });
    final connectionIdentity = HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: HermesConfigController.connectionEndpoint(
        config.baseUrl,
      )!,
      principalId: principalId,
    );
    const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_DELETE_FAIL>>>';
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: connectionIdentity,
      sessionId: 'purge-failure-session',
      messageId: 'purge-failure-message',
      promptText: 'Question\n\n$envelope',
      documentEnvelopes: const <String>[envelope],
    );
    PreferencesStore.debugOverride(
      PreferencesStore.instance,
      writeInterceptor: (preferences, key, value) async =>
          key == PreferenceKeys.hermesLocalDocumentTrust ? false : null,
    );
    final service = _DeleteTrackingHermesService(config: config);
    final container = ProviderContainer(
      overrides: [
        hermesConfigProvider.overrideWith(
          () => _FixedHermesConfigController(config),
        ),
        hermesApiServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await container.read(hermesSessionsProvider.future);

    await check(
      container
          .read(hermesSessionsProvider.notifier)
          .delete('purge-failure-session'),
    ).throws<StateError>();

    check(service.deleteCalls).equals(0);
  });
}
