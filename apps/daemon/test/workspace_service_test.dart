@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/models/backend_config.dart';
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

  late _NoNetwork network;
  setUp(() {
    api = _Api();
    epoch = Object();
    // These tests answer from memory: any connection opened fails them.
    network = _NoNetwork();
    HttpOverrides.global = network;
  });
  tearDown(() {
    HttpOverrides.global = null;
    api.dispose();
    expect(network.opened, 0, reason: 'a test reached the network');
  });

  BackendConfig config = BackendConfig(serverId: _server.id);
  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => api),
        currentUserProvider2.overrideWith((ref) => _ava),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('token'),
        activeServerProvider.overrideWith((ref) async => _server),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        // A config of this server whose version is not known: the clone is
        // tried, and a 404 or 405 may mean it has no clone.
        backendConfigProvider.overrideWith(() => _Config(config)),
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

  test('an account that changes while a clone is out is never asked about '
      "the first account's skill", () async {
    final c = container();
    await c.read(activeServerProvider.future);
    api.skillReads = [_skill];
    final held = api.holdClone = Completer<void>();
    final copying = WorkspaceService(c).duplicate(
      const WorkspaceDuplicate(
        kind: WorkspaceKind.skills,
        id: 's1',
        suffix: '(copy)',
      ),
    );
    await api.cloneAsked.future;
    // Another account signs in while the clone is out; it answers 405.
    epoch = Object();
    c.invalidate(openWebUiAuthSessionEpochProvider);
    held.complete();
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
      api.skillReadCount,
      1,
      reason: 'the next account was asked about the skill',
    );
    expect(api.createdSkills, isEmpty);
  });

  for (final (label, stale) in <(String, BackendConfig)>[
    (
      'an older version cached for this server',
      BackendConfig(serverId: _server.id, version: '0.11.0'),
    ),
    (
      'a version of another server',
      BackendConfig(serverId: 'elsewhere', version: '0.11.0'),
    ),
  ]) {
    test('$label never skips the server\'s own clone', () async {
      config = stale;
      final c = container();
      await c.read(activeServerProvider.future);
      // The cached config is in when the duplicate is asked.
      await c.read(backendConfigProvider.future);
      api.skillReads = [_skill];
      await WorkspaceService(c).duplicate(
        const WorkspaceDuplicate(
          kind: WorkspaceKind.skills,
          id: 's1',
          suffix: '(copy)',
        ),
      );
      expect(api.clones, ['s1'], reason: 'the server was not asked to clone');
    });
  }

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

  static DioException _missing(String path) => _status(path, 404);

  static DioException _status(String path, int code) => DioException(
    requestOptions: RequestOptions(path: path),
    response: Response<void>(
      requestOptions: RequestOptions(path: path),
      statusCode: code,
    ),
  );

  /// The clone was asked for; [holdClone] keeps its answer back.
  final cloneAsked = Completer<void>();
  Completer<void>? holdClone;
  int skillReadCount = 0;

  @override
  Future<WorkspacePagedResponse<WorkspaceSkillSummary>> getWorkspaceSkills({
    String? query,
    String? viewOption,
    int page = 1,
  }) async => const WorkspacePagedResponse(items: [], total: 0);

  @override
  Future<WorkspaceSkillDetail?> getWorkspaceSkill(String id) async {
    skillReadCount++;
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
    if (!cloneAsked.isCompleted) cloneAsked.complete();
    if (holdClone case final hold?) await hold.future;
    throw _status('/api/v1/skills/id/$id/clone', holdClone == null ? 404 : 405);
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

/// This server's config, as the test sets it.
final class _Config extends BackendConfigNotifier {
  _Config(this.config);
  final BackendConfig config;

  @override
  Future<BackendConfig?> build() async => config;
}

/// Counts every connection the code under test opens.
final class _NoNetwork extends HttpOverrides {
  int opened = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    opened++;
    return super.createHttpClient(context);
  }
}
