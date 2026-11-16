@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Home server',
  url: 'https://home.invalid',
);

const _ava = User(
  id: 'user-1',
  username: 'ava',
  email: 'ava@example.com',
  name: 'Ava',
  role: 'user',
);

/// `workspace.*` over one signed-in account whose server answers from
/// memory.
void main() {
  late _Api api;
  late Object epoch;

  setUp(() {
    api = _Api();
    epoch = Object();
  });
  tearDown(() => api.dispose());

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => api),
        currentUserProvider2.overrideWith((ref) => _ava),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('token'),
        activeServerProvider.overrideWith((ref) async => _server),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'a duplicate read under one account is never made under the next',
    () async {
      final c = container();
      await c.read(activeServerProvider.future);
      final read = Completer<WorkspacePromptDetail?>();
      api.prompt = () => read.future;
      final copying = WorkspaceService(c).duplicate(
        const WorkspaceDuplicate(
          kind: WorkspaceKind.prompts,
          id: 'p1',
          suffix: '(copy)',
        ),
      );
      await api.asked.future;
      // Another account signs in while the prompt is read.
      epoch = Object();
      c.invalidate(openWebUiAuthSessionEpochProvider);
      read.complete(
        const WorkspacePromptSummary(
          id: 'p1',
          command: 'trail',
          name: 'Trail',
          content: 'Plan a private hike',
          userId: 'user-1',
        ),
      );
      await expectLater(
        copying,
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );
      expect(
        api.created,
        isEmpty,
        reason: "Ava's prompt went to the next account",
      );
    },
  );
}

/// The account's server, answered from memory.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager());

  Future<WorkspacePromptDetail?> Function() prompt = () async => null;

  /// The prompt was asked for.
  final asked = Completer<void>();
  final created = <WorkspacePromptForm>[];

  @override
  Future<WorkspacePromptDetail?> getWorkspacePrompt(String id) {
    asked.complete();
    return prompt();
  }

  @override
  Future<WorkspacePromptDetail?> createWorkspacePrompt(
    WorkspacePromptForm form,
  ) async {
    created.add(form);
    return null;
  }
}
