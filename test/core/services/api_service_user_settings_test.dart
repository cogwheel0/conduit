import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
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

    test('automatic reasoning effort clears the server-side value', () async {
      final adapter = _UserSettingsAdapter(<String, dynamic>{
        'params': <String, dynamic>{
          'reasoning_effort': 'medium',
          'temperature': 0.3,
        },
      });
      final api = _buildApi(adapter, authToken: 'account-a');

      check(
        (adapter.settings['params']
            as Map<String, dynamic>)['reasoning_effort'],
      ).equals('medium');
      adapter.releaseFirstGet.complete();

      final result = await api.updateUserReasoningEffort(null);

      check(result.reasoningEffort).isNull();
      check(adapter.settings['params'])
          .isA<Map<String, dynamic>>()
          .deepEquals(<String, dynamic>{'temperature': 0.3});
    });

    test('clearing the system prompt sends an explicit null', () async {
      // Open WebUI >= 0.11.4 patches `ui` per key, so an omitted key keeps
      // its old value. Only an explicit null resets it.
      final adapter = _UserSettingsAdapter(<String, dynamic>{
        'ui': <String, dynamic>{
          'system': 'Be concise',
          'models': <String>['gpt-4o'],
          'theme': 'dark',
        },
      });
      final api = _buildApi(adapter, authToken: 'account-a');
      adapter.releaseFirstGet.complete();

      final afterPrompt = await api.updateUserSystemPrompt('   ');
      final promptUi = adapter.lastSubmitted!['ui'] as Map<String, dynamic>;
      check(promptUi.containsKey('system')).isTrue();
      check(promptUi['system']).isNull();
      check(promptUi['theme']).equals('dark');
      check(afterPrompt.systemPrompt).isNull();

      // The default-model half of this test on main is not ported:
      // `updateUserDefaultModel` had no callers and this branch removed
      // it along with 47 other unreferenced methods.
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
  Map<String, dynamic>? lastSubmitted;
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
        final submitted = _clone(options.data as Map<String, dynamic>);
        lastSubmitted = submitted;
        settings = <String, dynamic>{...settings, ...submitted};
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
