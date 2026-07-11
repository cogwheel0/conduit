import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_session.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
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
      check(id).equals('s1');
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
      await service.renameSession('s1', 'New');
      await service.deleteSession('s1');
      check(capture.requests[0].method).equals('PATCH');
      check(
        capture.requests[0].path,
      ).equals('http://host:8642/api/sessions/s1');
      check((capture.requests[0].data as Map)['title']).equals('New');
      check(capture.requests[1].method).equals('DELETE');
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

      check(
        messages.map((message) => message.metadata?['hermesRunId']).toList(),
      ).deepEquals(['run-1', 'response-2', 'response-3']);
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
