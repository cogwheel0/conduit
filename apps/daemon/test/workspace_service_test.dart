@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:dio/dio.dart';
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
        // A server whose version is not known: the clone is tried, and a
        // 404 or 405 may mean it has no clone.
        workspaceServerVersionProvider.overrideWithValue(null),
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

  test('a skill gone when its clone answers 404 is not copied from the earlier read', () async {
    final c = container();
    await c.read(activeServerProvider.future);
    // Deleted on the server after the daemon read it: the clone and the
    // read after it both answer 404.
    api.skillReads = [_skill, null];
    await expectLater(
      WorkspaceService(c).duplicate(
        const WorkspaceDuplicate(
          kind: WorkspaceKind.skills,
          id: 's1',
          suffix: '(copy)',
        ),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
    expect(api.clones, ['s1']);
    expect(api.createdSkills, isEmpty, reason: 'a deleted skill was copied');
  });

  test('a skill still there when its clone answers 404 is copied, as a server '
      'without a clone needs', () async {
    final c = container();
    await c.read(activeServerProvider.future);
    api.skillReads = [_skill];
    await WorkspaceService(c).duplicate(
      const WorkspaceDuplicate(
        kind: WorkspaceKind.skills,
        id: 's1',
        suffix: '(copy)',
      ),
    );
    expect(api.createdSkills.map((f) => f.name), ['Trail notes (copy)']);
  });
}

const _skill = WorkspaceSkillSummary(
  id: 's1',
  name: 'Trail notes',
  content: 'Plan a private hike',
  userId: 'user-1',
);

/// The account's server, answered from memory.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager());

  Future<WorkspacePromptDetail?> Function() prompt = () async => null;

  /// The prompt was asked for.
  final asked = Completer<void>();
  final created = <WorkspacePromptForm>[];

  /// What each skill read answers, in turn (the last one from then on):
  /// null is a 404.
  List<WorkspaceSkillDetail?> skillReads = [];
  final clones = <String>[];
  final createdSkills = <WorkspaceSkillForm>[];

  static DioException _missing(String path) => DioException(
    requestOptions: RequestOptions(path: path),
    response: Response<void>(
      requestOptions: RequestOptions(path: path),
      statusCode: 404,
    ),
  );

  @override
  Future<WorkspaceSkillDetail?> getWorkspaceSkill(String id) async {
    // The last answer stays for every read after it.
    final answer = skillReads.length > 1
        ? skillReads.removeAt(0)
        : skillReads.single;
    if (answer == null) throw _missing('/api/v1/skills/id/$id');
    return answer;
  }

  @override
  Future<WorkspaceSkillDetail?> cloneWorkspaceSkill(
    String id, {
    required String newId,
    required String name,
  }) async {
    clones.add(id);
    throw _missing('/api/v1/skills/id/$id/clone');
  }

  @override
  Future<WorkspaceSkillDetail?> createWorkspaceSkill(
    WorkspaceSkillForm form,
  ) async {
    createdSkills.add(form);
    return WorkspaceSkillSummary(
      id: form.id,
      name: form.name,
      content: form.content,
      userId: 'user-1',
    );
  }

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
