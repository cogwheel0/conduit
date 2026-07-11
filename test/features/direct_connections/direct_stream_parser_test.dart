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
      throwsA(isA<TimeoutException>()),
    );

    final budget = DirectStreamBudget(maxCharacters: 4)..add('1234');
    expect(() => budget.add('5'), throwsA(isA<DirectProviderException>()));
    expect(
      normalizeDirectProviderError(TimeoutException('idle')).message,
      contains('timed out'),
    );
  });
}
