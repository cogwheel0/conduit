import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit/features/direct_connections/services/ollama_stream_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ollama parser handles split UTF-8, CRLF, and trailing line', () async {
    final bytes = utf8.encode(
      '{"message":{"content":"你"}}\r\n'
      '{"message":{"content":"好"},"done":true}',
    );
    final splitInsideRune = bytes.indexOf(0xE4) + 1;
    final stream = Stream<List<int>>.fromIterable([
      bytes.sublist(0, splitInsideRune),
      bytes.sublist(splitInsideRune, bytes.length - 3),
      bytes.sublist(bytes.length - 3),
    ]);

    final parsed = await parseOllamaNdjson(stream).toList();

    expect(parsed, hasLength(2));
    expect((parsed.first['message'] as Map)['content'], '你');
    expect((parsed.last['message'] as Map)['content'], '好');
    expect(parsed.last['done'], isTrue);
  });

  test('Ollama parser rejects non-object lines', () async {
    final stream = Stream<List<int>>.value(utf8.encode('[1,2,3]\n'));
    await expectLater(
      parseOllamaNdjson(stream).toList(),
      throwsFormatException,
    );
  });

  test('Ollama parser remains correct across tiny chunks', () async {
    final encoded = utf8.encode(
      '${jsonEncode({
        'message': {'content': List.filled(20000, 'x').join()},
      })}\n',
    );

    final parsed = await parseOllamaNdjson(
      Stream<List<int>>.fromIterable([
        for (final byte in encoded) [byte],
      ]),
      maxLineCharacters: 21000,
    ).toList();

    expect((parsed.single['message'] as Map)['content'], hasLength(20000));
  });

  test('Ollama parser does not count the CR in a bounded CRLF line', () async {
    const line = '{"value":1}';

    final parsed = await parseOllamaNdjson(
      Stream.value(utf8.encode('$line\r\n')),
      maxLineCharacters: line.length,
    ).toList();

    expect(parsed.single['value'], 1);
  });

  test('Ollama parser counts a trailing CR that is not framing', () async {
    const line = '{"value":1}';

    await expectLater(
      parseOllamaNdjson(
        Stream.value(utf8.encode('$line\r')),
        maxLineCharacters: line.length,
      ).toList(),
      throwsFormatException,
    );
  });

  test('bounded JSON decoder rejects oversized provider responses', () async {
    final body = ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode('{"value":1}'))),
      200,
    );

    await expectLater(
      decodeDirectJsonBody(body, maxBytes: 4),
      throwsFormatException,
    );
  });

  test('provider error messages stop at cycles and bounded depth', () {
    final cyclic = <String, Object?>{};
    cyclic['error'] = cyclic;
    expect(directErrorMessage(cyclic), 'The provider reported an error.');

    Object? deeplyNested = 'too deep';
    for (var index = 0; index < 10; index++) {
      deeplyNested = <String, Object?>{'error': deeplyNested};
    }
    expect(directErrorMessage(deeplyNested), 'The provider reported an error.');
    expect(
      directErrorMessage({
        'message': {'detail': '  useful message  '},
      }),
      'useful message',
    );
  });

  test('direct streams enforce idle and cumulative response bounds', () async {
    final body = ResponseBody(Stream<Uint8List>.empty(), 200);
    await expectLater(
      directStreamingResponseBytes(
        body,
        idleTimeout: const Duration(milliseconds: 1),
      ).toList(),
      completes,
    );

    final neverBody = ResponseBody(
      Stream<Uint8List>.fromFuture(Completer<Uint8List>().future),
      200,
    );
    await expectLater(
      directStreamingResponseBytes(
        neverBody,
        idleTimeout: const Duration(milliseconds: 1),
      ).toList(),
      throwsA(
        isA<DirectProviderException>()
            .having(
              (error) => error.message,
              'message',
              'The provider stream timed out while waiting for data.',
            )
            .having((error) => error.cause, 'cause', isA<TimeoutException>()),
      ),
    );

    final budget = DirectStreamBudget(maxCharacters: 4)..add('1234');
    expect(() => budget.add('5'), throwsA(isA<DirectProviderException>()));
    expect(
      normalizeDirectProviderError(TimeoutException('idle')).message,
      contains('timed out'),
    );
  });

  test(
    'direct streams enforce absolute duration and cancel the source',
    () async {
      late Timer heartbeat;
      var sourceCancelled = false;
      late final StreamController<Uint8List> source;
      source = StreamController<Uint8List>(
        onListen: () {
          heartbeat = Timer.periodic(
            const Duration(milliseconds: 2),
            (_) => source.add(Uint8List.fromList(utf8.encode(': ping\n\n'))),
          );
        },
        onCancel: () {
          sourceCancelled = true;
          heartbeat.cancel();
        },
      );
      final body = ResponseBody(source.stream, 200);

      await expectLater(
        directStreamingResponseBytes(
          body,
          idleTimeout: const Duration(milliseconds: 50),
          maxDuration: const Duration(milliseconds: 15),
        ).toList(),
        throwsA(
          isA<DirectProviderException>().having(
            (error) => error.message,
            'message',
            contains('time limit'),
          ),
        ),
      );
      expect(sourceCancelled, isTrue);
    },
  );

  test(
    'direct idle timeout is not trapped by hostile source cancellation',
    () async {
      final cancellationStarted = Completer<void>();
      final cancellationNeverFinishes = Completer<void>();
      final source = StreamController<Uint8List>(
        onCancel: () {
          cancellationStarted.complete();
          return cancellationNeverFinishes.future;
        },
      );
      final body = ResponseBody(source.stream, 200);

      final outcome =
          directStreamingResponseBytes(
            body,
            idleTimeout: const Duration(milliseconds: 10),
            maxDuration: const Duration(seconds: 1),
          ).toList().then<Object>(
            (_) => StateError('The idle stream unexpectedly completed.'),
            onError: (Object error) => error,
          );

      expect(
        await outcome.timeout(
          const Duration(seconds: 1),
          onTimeout: () => StateError('Source cancellation blocked timeout.'),
        ),
        isA<DirectProviderException>()
            .having(
              (error) => error.message,
              'message',
              'The provider stream timed out while waiting for data.',
            )
            .having((error) => error.cause, 'cause', isA<TimeoutException>()),
      );
      await cancellationStarted.future.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'direct stream errors are not trapped by hostile source cancellation',
    () async {
      final cancellationStarted = Completer<void>();
      final cancellationNeverFinishes = Completer<void>();
      late final StreamController<Uint8List> source;
      source = StreamController<Uint8List>(
        onListen: () {
          source.add(Uint8List.fromList(utf8.encode('oversized')));
        },
        onCancel: () {
          cancellationStarted.complete();
          return cancellationNeverFinishes.future;
        },
      );
      final body = ResponseBody(source.stream, 200);

      final outcome = directStreamingResponseBytes(body, maxBytes: 1)
          .toList()
          .then<Object>(
            (_) => StateError('The oversized stream unexpectedly completed.'),
            onError: (Object error) => error,
          );

      expect(
        await outcome.timeout(
          const Duration(seconds: 1),
          onTimeout: () => StateError('Source cancellation blocked the error.'),
        ),
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('transfer limit'),
        ),
      );
      await cancellationStarted.future.timeout(const Duration(seconds: 1));
    },
  );

  test('direct streams bound cumulative raw bytes', () async {
    final body = ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(': ping\n\n'))),
      200,
    );

    await expectLater(
      directStreamingResponseBytes(body, maxBytes: 4).toList(),
      throwsA(
        isA<DirectProviderException>().having(
          (error) => error.message,
          'message',
          contains('transfer limit'),
        ),
      ),
    );
  });

  test('provider errors redact secrets, controls, and excessive text', () {
    const secret = 'provider-secret-value';
    final message = directErrorMessage(
      'Authorization: Bearer $secret\u0000\n${List.filled(100, 'x').join()}',
      sensitiveValues: const [secret],
      maxCharacters: 48,
    );

    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains('\u0000')));
    expect(message, isNot(contains('\n')));
    expect(message.runes.length, 48);
    expect(message, endsWith('…'));
  });

  test('provider errors redact every authorization scheme completely', () {
    const reflected = <String>[
      'Authorization: Basic dXNlcjpwYXNz',
      'Proxy-Authorization=Digest username="user", response="credential"',
      'Authorization: Custom-Scheme first second third',
    ];

    for (final value in reflected) {
      final message = sanitizeDirectProviderErrorMessage('$value\nfailed');
      expect(message, contains('[REDACTED]'));
      expect(message, endsWith('failed'));
      expect(message, isNot(contains('dXNlcjpwYXNz')));
      expect(message, isNot(contains('username')));
      expect(message, isNot(contains('credential')));
      expect(message, isNot(contains('first second third')));
    }
  });

  test(
    'provider secret redaction is bounded and never recursively expands',
    () {
      final message = sanitizeDirectProviderErrorMessage(
        List.filled(100000, 'A').join(),
        sensitiveValues: const ['A', 'D'],
      );
      expect(message.runes.length, kMaxDirectProviderErrorCharacters);
      expect(message, startsWith('[REDACTED][REDACTED]'));
      expect(message, isNot(contains('[RE[REDACTED]')));

      expect(
        sanitizeDirectProviderErrorMessage(
          'provider detail',
          sensitiveValues: List<String>.generate(129, (index) => 's$index'),
        ),
        'The provider reported an error.',
      );
    },
  );
}
