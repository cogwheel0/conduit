import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Open WebUI 0.13.4 with Terminals 0.4.0: a template that makes a machine
/// per model, and one per user (`routers/terminals.py`).
final class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    requests.add(options);
    final Object body = switch (options.path) {
      '/api/v1/users/user/settings' => <String, dynamic>{},
      '/api/v1/terminals/' => [
        for (final (id, scope) in [('per-model', 'model'), ('mine', 'user')])
          {
            'id': 'orchestra:$id',
            'url': '',
            'name': 'Bench $id',
            'template_id': id,
            'scope': scope,
            'config': {'chat_uploads': 'default'},
          },
      ],
      final path when path.endsWith('/files/cwd') => {'cwd': '/home/bench'},
      _ => throw StateError('unexpected ${options.path}'),
    };
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _Picked extends SelectedModel {
  @override
  Model? build() => null;

  void choose(Model? model) => state = model;
}

final class _Offered extends TerminalFeatureEnabledNotifier {
  @override
  bool build() => false;

  @override
  void setEnabled(bool enabled) => state = enabled;
}

void main() {
  test('a terminal made per model is offered only once the chat has a '
      'model, and every call to it names that model', () async {
    final server = _Server();
    final workerManager = WorkerManager();
    addTearDown(workerManager.dispose);
    final api = ApiService(
      serverConfig: const ServerConfig(
        id: 'bench',
        name: 'Bench',
        url: 'http://localhost:9999',
      ),
      workerManager: workerManager,
    );
    api.dio.httpClientAdapter = server;
    api.dio.interceptors.clear();
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        selectedModelProvider.overrideWith(_Picked.new),
        terminalFeatureEnabledProvider.overrideWith(_Offered.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(terminalSelectedServerProvider, (_, _) {});

    // No model yet: Open WebUI would answer 409 "This terminal requires a
    // model".
    final before = await container.read(
      terminalAvailableServersProvider.future,
    );
    check(before.map((s) => s.selectionId)).deepEquals(['orchestra:mine']);

    final picked = container.read(selectedModelProvider.notifier) as _Picked;
    picked.choose(const Model(id: 'nova-chat', name: 'Nova'));
    final servers = await container.read(
      terminalAvailableServersProvider.future,
    );
    check(servers.map((s) => s.selectionId))
        .deepEquals(['orchestra:per-model', 'orchestra:mine']);
    container
        .read(selectedTerminalIdProvider.notifier)
        .set('orchestra:per-model');
    final perModel = (await container.read(
      terminalSelectedServerProvider.future,
    ))!;
    final mine = servers.last;

    final service = container.read(terminalServiceProvider)!;
    server.requests.clear();
    for (final terminal in [perModel, mine]) {
      await service.getCwd(terminal, sessionScopeId: 'chat-1');
    }
    check(server.requests.map((r) => r.headers['X-Terminal-Model-Id']))
        .deepEquals(['nova-chat', null]);
    check(server.requests.map((r) => r.headers['X-Session-Id']))
        .deepEquals(['chat-1', 'chat-1']);

    check(
      buildTerminalWebSocketAuthPayload(
        perModel,
        token: 'token',
        sessionScopeId: 'chat-1',
      ),
    ).deepEquals({
      'type': 'auth',
      'token': 'token',
      'chat_id': 'chat-1',
      'model_id': 'nova-chat',
    });
    check(
      buildTerminalWebSocketAuthPayload(
        mine,
        token: 'token',
        sessionScopeId: 'chat-1',
      ),
    ).deepEquals({'type': 'auth', 'token': 'token', 'chat_id': 'chat-1'});

    // Another model: the selected terminal is that model's, and the list is
    // not read again.
    server.requests.clear();
    picked.choose(const Model(id: 'nova-other', name: 'Nova Other'));
    final switched = await container.read(
      terminalSelectedServerProvider.future,
    );
    check(switched?.modelId).equals('nova-other');
    check(server.requests).isEmpty();
  });
}
