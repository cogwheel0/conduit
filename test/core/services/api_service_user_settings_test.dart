import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/terminal/services/terminal_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('user settings mutation boundary', () {
    test('stale auth snapshots are rejected before transport', () async {
      final adapter = _UserSettingsAdapter(const <String, dynamic>{});
      final api = _buildApi(adapter, authToken: 'account-a');
      final staleSnapshot = api.captureAuthSnapshot();
      api.updateAuthToken('account-b');

      await expectLater(
        api.getUserSettings(authSnapshot: staleSnapshot),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        api.updateUserSettings(const <String, dynamic>{
          'ui': <String, dynamic>{},
        }, authSnapshot: staleSnapshot),
        throwsA(isA<DioException>()),
      );

      expect(adapter.requestMethods, isEmpty);
    });

    test(
      'API and terminal read-modify-write operations serialize without loss',
      () async {
        final adapter = _UserSettingsAdapter(<String, dynamic>{
          'ui': <String, dynamic>{'theme': 'system'},
          'terminalServers': <Map<String, dynamic>>[
            <String, dynamic>{'url': 'https://one.example'},
            <String, dynamic>{'url': 'https://two.example', 'enabled': true},
          ],
        });
        final api = _buildApi(adapter, authToken: 'account-a');
        final terminal = TerminalService(api);

        final promptUpdate = api.updateUserSystemPrompt('Be concise');
        await adapter.firstGetEntered.future;

        final terminalUpdate = terminal.updateDirectTerminalSelection(
          'https://one.example',
        );
        await Future<void>.delayed(Duration.zero);

        expect(adapter.requestMethods, <String>['GET']);
        expect(adapter.maximumConcurrentRequests, 1);

        adapter.releaseFirstGet.complete();
        await Future.wait<Object?>(<Future<Object?>>[
          promptUpdate,
          terminalUpdate,
        ]);

        expect(adapter.requestMethods, <String>['GET', 'POST', 'GET', 'POST']);
        expect(adapter.maximumConcurrentRequests, 1);
        expect(
          (adapter.settings['ui'] as Map<String, dynamic>)['system'],
          'Be concise',
        );
        expect(
          (adapter.settings['ui'] as Map<String, dynamic>)['theme'],
          'system',
        );
        final terminals = (adapter.settings['terminalServers'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        expect(terminals[0]['enabled'], isTrue);
        expect(terminals[1]['enabled'], isFalse);
      },
    );

    test('a failed operation does not poison the mutation queue', () async {
      final api = _buildApi(
        _UserSettingsAdapter(const <String, dynamic>{}),
        authToken: 'account-a',
      );

      await expectLater(
        api.serializeUserSettingsMutation<void>(
          () async => throw StateError('first mutation failed'),
        ),
        throwsStateError,
      );

      final result = await api.serializeUserSettingsMutation<int>(
        () async => 42,
      );
      expect(result, 42);
    });
  });
}

ApiService _buildApi(HttpClientAdapter adapter, {required String authToken}) {
  final api = ApiService(
    serverConfig: const ServerConfig(
      id: 'settings-test',
      name: 'Settings test',
      url: 'https://example.test',
    ),
    workerManager: WorkerManager(),
    authToken: authToken,
  );
  api.dio.httpClientAdapter = adapter;
  return api;
}

final class _UserSettingsAdapter implements HttpClientAdapter {
  _UserSettingsAdapter(Map<String, dynamic> initialSettings)
    : settings = _clone(initialSettings);

  Map<String, dynamic> settings;
  final List<String> requestMethods = <String>[];
  final Completer<void> firstGetEntered = Completer<void>();
  final Completer<void> releaseFirstGet = Completer<void>();
  int _activeRequests = 0;
  int maximumConcurrentRequests = 0;
  bool _blockedFirstGet = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _activeRequests++;
    if (_activeRequests > maximumConcurrentRequests) {
      maximumConcurrentRequests = _activeRequests;
    }
    requestMethods.add(options.method);

    try {
      if (options.method == 'GET' && !_blockedFirstGet) {
        _blockedFirstGet = true;
        firstGetEntered.complete();
        await releaseFirstGet.future;
      }

      if (options.method == 'POST') {
        settings = _clone(options.data as Map<String, dynamic>);
      }
      return _jsonResponse(settings);
    } finally {
      _activeRequests--;
    }
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _clone(Map<String, dynamic> value) {
  return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}

ResponseBody _jsonResponse(Object? value) {
  return ResponseBody(
    Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
    200,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    },
  );
}
