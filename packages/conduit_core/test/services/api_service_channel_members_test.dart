import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';

void main() {
  test('add sends user and group ids, remove sends user ids only', () async {
    final harness = _Harness();

    await harness.api.addChannelMembers(
      'channel-1',
      userIds: ['user-2'],
      groupIds: ['group-1'],
    );
    await harness.api.removeChannelMembers('channel-1', userIds: ['user-2']);

    check(harness.requests.map((r) => '${r.method} ${r.path}')).deepEquals([
      'POST /api/v1/channels/channel-1/update/members/add',
      'POST /api/v1/channels/channel-1/update/members/remove',
    ]);
    check(harness.requests[0].data as Map<String, dynamic>).deepEquals({
      'user_ids': ['user-2'],
      'group_ids': ['group-1'],
    });
    // The route has no group form; a group id here would be silently ignored.
    check(harness.requests[1].data as Map<String, dynamic>).deepEquals({
      'user_ids': ['user-2'],
    });
  });

  test('member reads send the page, search and sort the caller asked for, '
      'and a caller without a snapshot is unchanged', () async {
    final harness = _Harness();

    await harness.api.getChannelMembers(
      'channel-1',
      query: 'al',
      orderBy: 'name',
      direction: 'asc',
      page: 3,
      authSnapshot: harness.api.captureAuthSnapshot(),
    );
    await harness.api.getChannelMembers('channel-1');

    check(harness.requests[0].queryParameters).deepEquals({
      'page': 3,
      'query': 'al',
      'order_by': 'name',
      'direction': 'asc',
    });
    check(harness.requests[1].queryParameters).deepEquals({'page': 1});
    for (final request in harness.requests) {
      check(request.headers['Authorization']).equals('Bearer token-a');
    }
  });

  group('after the client rotates to another token', () {
    final calls = <String, Future<Object?> Function(_Harness, ApiAuthSnapshot)>{
      'read': (h, s) => h.api.getChannelMembers('channel-1', authSnapshot: s),
      // The count refresh that follows a member change.
      'channel refresh': (h, s) =>
          h.api.getChannel('channel-1', authSnapshot: s),
      'add': (h, s) => h.api.addChannelMembers(
        'channel-1',
        userIds: ['user-2'],
        authSnapshot: s,
      ),
      'remove': (h, s) => h.api.removeChannelMembers(
        'channel-1',
        userIds: ['user-2'],
        authSnapshot: s,
      ),
    };

    for (final entry in calls.entries) {
      test('a captured ${entry.key} is refused before it is dispatched, '
          'and an uncaptured one carries the new token', () async {
        final harness = _Harness();
        final snapshot = harness.api.captureAuthSnapshot();

        harness.api.updateAuthToken('token-b');

        await check(entry.value(harness, snapshot)).throws<DioException>(
          (it) => it.has((e) => e.type, 'type').equals(DioExceptionType.cancel),
        );
        check(harness.requests).isEmpty();

        // Without the snapshot the same call is sent as the new account. This
        // is what the snapshot exists to prevent.
        await switch (entry.key) {
          'read' => harness.api.getChannelMembers('channel-1'),
          'channel refresh' => harness.api.getChannel('channel-1'),
          'add' => harness.api.addChannelMembers(
            'channel-1',
            userIds: ['user-2'],
          ),
          _ => harness.api.removeChannelMembers(
            'channel-1',
            userIds: ['user-2'],
          ),
        };
        check(harness.requests.single.headers['Authorization'])
            .equals('Bearer token-b');
      });
    }
  });
}

class _Harness {
  _Harness() {
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'test',
        name: 'Test',
        url: 'http://localhost:0',
      ),
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    api.dio.httpClientAdapter = _Adapter(requests);
    addTearDown(api.dispose);
  }

  late final ApiService api;
  final List<RequestOptions> requests = [];
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.requests);

  final List<RequestOptions> requests;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody(
      Stream.value(
        Uint8List.fromList(utf8.encode(jsonEncode({'users': [], 'total': 0}))),
      ),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
