import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_session.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_service.dart';
import 'package:conduit/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit/features/hermes/utils/hermes_time_parsing.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

      await service.getSessionMessages(sessionId);
      await service.renameSession(sessionId, 'New');
      await service.deleteSession(sessionId);
      check(await service.forkSession(sessionId)).equals('branched');

      check(
        capture.requests[0].path,
      ).equals('http://host:8642/api/sessions/$encoded/messages');
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
      final messages = hermesMessagesToChatMessages([
        {'role': 'user', 'content': 'Summarize the findings.\n\n$rendered'},
      ]);

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

    test(
      'preserves document-only user rows and restores multiple documents',
      () {
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
        final messages = hermesMessagesToChatMessages([
          {
            'role': 'user',
            'content': [
              {
                'type': 'input_text',
                'text':
                    '${first.renderForPrompt()}\n\n${second.renderForPrompt()}',
              },
            ],
          },
        ]);

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
      },
    );

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
}
