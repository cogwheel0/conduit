import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(id: 's', name: 'S', url: 'http://localhost:0');

const _owner = User(id: 'owner', username: 'o', email: 'o@e.com', role: 'user');
const _other = User(id: 'other', username: 'g', email: 'g@e.com', role: 'user');

/// Who is signed in, switched by a test while a request is on its way.
final class _SignedIn extends Notifier<User> {
  @override
  User build() => _owner;

  void use(User user) => state = user;
}

final _signedInProvider = NotifierProvider<_SignedIn, User>(_SignedIn.new);

/// An Open WebUI server answering every write with [answer], after running
/// [onWrite]; reads get an empty list.
class _Server implements HttpClientAdapter {
  _Server(this.answer);

  /// The body a write is answered with.
  final Object? answer;

  /// Runs as a write arrives, before it is answered.
  void Function()? onWrite;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') return _json(const <Object?>[]);
    onWrite?.call();
    return _json(answer);
  }

  ResponseBody _json(Object? body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

Future<ProviderContainer> _container(_Server server) async {
  final api = ApiService(serverConfig: _server, workerManager: WorkerManager())
    ..dio.httpClientAdapter = server;
  api.dio.interceptors.clear();
  final container = ProviderContainer(
    overrides: [
      apiServiceProvider.overrideWithValue(api),
      activeServerProvider.overrideWith((ref) async => _server),
      currentUserProvider2.overrideWith((ref) => ref.watch(_signedInProvider)),
      authTokenProvider3.overrideWithValue('token'),
    ],
  );
  await container.read(activeServerProvider.future);
  // Another account signs in while each write is on its way.
  server.onWrite = () => container.read(_signedInProvider.notifier).use(_other);
  return container;
}

void main() {
  // A session that changed while a write was on its way means the server
  // took it; one the server did not confirm stays a failure, so the page
  // can say it was not saved.
  group('a write the server does not confirm, as another account signs in, '
      'is a failure, not a change taken', () {
    test('a skill delete answered false', () async {
      final container = await _container(_Server(false));
      addTearDown(container.dispose);

      await check(
        container.read(workspaceSkillsProvider.notifier).delete('skill-1'),
      ).throws<StateError>();
    });

    test('a skill switch answered with no record', () async {
      final container = await _container(_Server(null));
      addTearDown(container.dispose);

      await check(
        container.read(workspaceSkillsProvider.notifier).toggle('skill-1'),
      ).throws<StateError>();
    });

    test('a tool switch answered with no record', () async {
      final container = await _container(_Server(null));
      addTearDown(container.dispose);

      await check(
        container.read(workspaceToolsProvider.notifier).toggle('tool-1'),
      ).throws<StateError>();
    });
  });

  test('a write the server took, as another account signs in, says the '
      'session changed', () async {
    final container = await _container(_Server(true));
    addTearDown(container.dispose);

    await check(
      container.read(workspaceSkillsProvider.notifier).delete('skill-1'),
    ).throws<WorkspaceSessionChanged>();
  });
}
