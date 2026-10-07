import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/models/personal_valves.dart';
import 'package:conduit_core/features/chat/providers/personal_valves_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';

const _server = ServerConfig(
  id: 'test',
  name: 'Test',
  url: 'http://localhost:0',
);

const _toolTarget = PersonalValvesTarget(
  kind: PersonalValvesTargetKind.tool,
  id: 'shared_tool',
  label: 'Shared tool',
);

const _functionTarget = PersonalValvesTarget(
  kind: PersonalValvesTargetKind.function,
  id: 'echo_pipe',
  label: 'Echo pipe',
);

final _schema = {
  'properties': {
    'token': {
      'type': 'string',
      'input': {'type': 'password'},
    },
    'tags': {'type': 'array'},
  },
};

void main() {
  group('editor owner', () {
    for (final target in [_toolTarget, _functionTarget]) {
      test('use-only ${target.kind.name} user loads and saves without any '
          'server-owner request', () async {
        final harness = await _Harness.open((request) {
          if (!request.path.contains('/valves/user')) {
            // Server-owner valve routes need write access to the resource.
            return _json({'detail': 'Access prohibited'}, statusCode: 403);
          }
          if (request.path.endsWith('/spec')) return _json(_schema);
          if (request.method == 'GET') {
            return _json({
              'token': 'secret',
              'tags': ['a', 'b'],
              'legacy': 7,
            });
          }
          return _json(request.data);
        });
        final editor = harness.editor(target);

        await harness.settled(target);
        final loaded = harness.state(target);
        check(loaded.phase).equals(PersonalValvesPhase.ready);
        check(loaded.draft['tags']).equals('a, b');

        editor.setDraft({...loaded.draft, 'tags': 'a, b, c'});
        check(await editor.save()).isNull();

        final post = harness.requests.last;
        check(post.method).equals('POST');
        check(post.data as Map<String, dynamic>).deepEquals({
          'token': 'secret',
          'tags': ['a', 'b', 'c'],
          // A stored value this client cannot render is not dropped.
          'legacy': 7,
        });
        final kind = target.kind == PersonalValvesTargetKind.tool
            ? 'tools'
            : 'functions';
        check(harness.requests.map((r) => r.path)).every(
          (path) => path.contains('/api/v1/$kind/id/${target.id}/valves/user'),
        );
      });
    }

    test('account switch between load and save sends nothing', () async {
      final harness = await _Harness.open(_serverFor());
      final editor = harness.editor(_toolTarget);
      await harness.settled(_toolTarget);
      editor.setDraft({...harness.state(_toolTarget).draft, 'token': 'draft'});
      final sent = harness.requests.length;

      harness.signInAs('user-b', 'token-b');
      final failure = await editor.save();

      check(failure!.reason).equals(PersonalValvesFailureReason.ownerChanged);
      check(harness.requests.length).equals(sent);
      final state = harness.state(_toolTarget);
      check(state.phase).equals(PersonalValvesPhase.ownerChanged);
      check(state.document).isNull();
      check(state.draft).isEmpty();
    });

    test('account switch during load never reads the new account', () async {
      final spec = Completer<ResponseBody>();
      final harness = await _Harness.open((request) => spec.future);
      harness.editor(_toolTarget);
      await pumpEventQueue();
      check(harness.requests).length.equals(1);

      harness.signInAs('user-b', 'token-b');
      spec.complete(_json(_schema));
      await harness.settled(_toolTarget);

      check(harness.requests).length.equals(1);
      check(harness.state(_toolTarget).phase)
          .equals(PersonalValvesPhase.ownerChanged);
    });

    test('rejected values keep the draft and can be retried', () async {
      var reject = true;
      final harness = await _Harness.open((request) {
        if (request.method == 'POST' && reject) {
          return _json({'detail': 'tags must be short'}, statusCode: 400);
        }
        return _serverFor()(request);
      });
      final editor = harness.editor(_toolTarget);
      await harness.settled(_toolTarget);
      editor.setDraft({...harness.state(_toolTarget).draft, 'token': 'new'});

      final failure = await editor.save();

      check(failure!.reason).equals(PersonalValvesFailureReason.invalid);
      check(failure.detail).equals('tags must be short');
      check(harness.state(_toolTarget).draft['token']).equals('new');
      check(harness.state(_toolTarget).saving).isFalse();

      reject = false;
      check(await editor.save()).isNull();
      check((harness.requests.last.data as Map<String, dynamic>)['token'])
          .equals('new');
    });

    test('a retained editor refuses to save once chat.valves is denied, '
        'and keeps its draft', () async {
      final harness = await _Harness.open(_serverFor());
      final editor = harness.editor(_toolTarget);
      await harness.settled(_toolTarget);
      editor.setDraft({...harness.state(_toolTarget).draft, 'token': 'kept'});
      final sent = harness.requests.length;

      // Same account, same API: only the server's policy changed.
      harness.setPermissions({
        'chat': {'valves': false},
      });
      final failure = await editor.save();

      check(failure!.reason).equals(PersonalValvesFailureReason.denied);
      check(harness.requests.length).equals(sent);
      check(harness.state(_toolTarget).phase).equals(PersonalValvesPhase.ready);
      check(harness.state(_toolTarget).draft['token']).equals('kept');

      harness.setPermissions(const {});
      check(await editor.save()).isNull();
      check((harness.requests.last.data as Map<String, dynamic>)['token'])
          .equals('kept');
    });

    test(
      'an editor opened while chat.valves is denied reads nothing',
      () async {
        final harness = await _Harness.open(_serverFor());
        harness.setPermissions({
          'chat': {'valves': false},
        });
        harness.editor(_toolTarget);
        await harness.settled(_toolTarget);

        check(harness.requests).isEmpty();
        check(harness.state(_toolTarget).phase)
            .equals(PersonalValvesPhase.unavailable);
      },
    );

    test('a target without a personal schema cannot be saved', () async {
      final harness = await _Harness.open((request) => _json(null));
      final editor = harness.editor(_functionTarget);
      await harness.settled(_functionTarget);

      check(harness.state(_functionTarget).phase)
          .equals(PersonalValvesPhase.unavailable);
      final failure = await editor.save();

      check(failure!.reason).equals(PersonalValvesFailureReason.unavailable);
      // Only the schema probe was sent: no values read, no save.
      check(harness.requests).length.equals(1);
    });

    test('a removed target reads as unavailable, not a failure', () async {
      final harness = await _Harness.open(
        (request) => _json({'detail': 'Not found'}, statusCode: 401),
      );
      harness.editor(_functionTarget);
      await harness.settled(_functionTarget);

      check(harness.state(_functionTarget).phase)
          .equals(PersonalValvesPhase.unavailable);
    });
  });

  // These keep the real ApiAuthInterceptor: the owner checks around each await
  // cannot see which token Dio attaches when it later dispatches the request.
  group('request authorization', () {
    String? bearer(RequestOptions request) =>
        request.headers['Authorization']?.toString();

    for (final target in [_toolTarget, _functionTarget]) {
      final kind = target.kind.name;

      test(
        '$kind loads authenticate as the owner that opened the editor',
        () async {
          final harness = await _Harness.open(_serverFor(), realAuth: true);
          harness.editor(target);
          await harness.settled(target);

          check(harness.state(target).phase).equals(PersonalValvesPhase.ready);
          check(harness.requests).length.equals(2);
          check(harness.requests.map(bearer))
              .every((b) => b.equals('Bearer token-a'));
        },
      );

      test(
        'a $kind save admitted as account A is never dispatched as B',
        () async {
          final harness = await _Harness.open(_serverFor(), realAuth: true);
          final editor = harness.editor(target);
          await harness.settled(target);
          editor.setDraft({
            ...harness.state(target).draft,
            'token': 'draft-from-a',
          });
          final sent = harness.requests.length;

          // The owner is still current when save() checks, so only the request
          // itself can notice that the shared client moved to account B.
          final save = editor.save();
          harness.api.updateAuthToken('token-b');
          final failure = await save;

          check(failure).isNotNull();
          check(harness.requests.length).equals(sent);
          check(harness.state(target).draft['token']).equals('draft-from-a');
        },
      );

      test('a $kind load never dispatches its spec read as account B', () async {
        final harness = await _Harness.open(_serverFor(), realAuth: true);
        harness.editor(target);
        // The load starts on the next microtask, after the client has rotated.
        harness.api.updateAuthToken('token-b');
        await harness.settled(target);

        check(harness.requests).isEmpty();
        check(harness.state(target).phase)
            .equals(PersonalValvesPhase.loadFailed);
      });

      test(
        'a $kind load never dispatches its values read as account B',
        () async {
          late final _Harness harness;
          harness = await _Harness.open((request) {
            // Account A's spec read completes, then the client rotates.
            harness.api.updateAuthToken('token-b');
            return _json(_schema);
          }, realAuth: true);
          harness.editor(target);
          await harness.settled(target);

          check(harness.requests).length.equals(1);
          check(harness.requests.single.path).endsWith('/valves/user/spec');
          check(harness.state(target).phase)
              .equals(PersonalValvesPhase.loadFailed);
        },
      );
    }
  });

  group('targets', () {
    Model pipe(
      String id, {
      bool userValves = true,
      Map<String, dynamic>? extra,
    }) {
      return Model(
        id: id,
        name: 'Pipe $id',
        metadata: {
          'pipe': {'type': 'pipe'},
          'has_user_valves': userValves,
          ...?extra,
        },
      );
    }

    Future<List<PersonalValvesTarget>> targets({
      required Model selected,
      List<Model> models = const [],
      List<Tool> tools = const [],
      List<String> selectedTools = const [],
      List<String> selectedFilters = const [],
      Map<String, dynamic> permissions = const {},
      String role = 'user',
    }) async {
      final harness = await _Harness.open(
        _serverFor(),
        role: role,
        overrides: [
          selectedModelProvider.overrideWithValue(selected),
          modelsProvider.overrideWith(
            () => _FixedModels([selected, ...models]),
          ),
          toolsListProvider.overrideWith(() => _FixedTools(tools)),
          selectedToolIdsProvider.overrideWithBuild((_, _) => selectedTools),
          selectedFilterIdsProvider.overrideWithBuild(
            (_, _) => selectedFilters,
          ),
        ],
      );
      harness.setPermissions(permissions);
      await harness.container.read(modelsProvider.future);
      await harness.container.read(toolsListProvider.future);
      return harness.container.read(personalValvesTargetsProvider);
    }

    test(
      'a manifold submodel maps to its function id, not the model id',
      () async {
        final result = await targets(selected: pipe('echo_pipe.echo'));

        check(result).deepEquals([
          const PersonalValvesTarget(
            kind: PersonalValvesTargetKind.function,
            id: 'echo_pipe',
            label: 'Pipe echo_pipe.echo',
          ),
        ]);
      },
    );

    test('a preset model uses the pipe of its base model', () async {
      final preset = Model(
        id: 'my-preset',
        name: 'My preset',
        metadata: {
          'pipe': {'type': 'pipe'},
          'info': {'base_model_id': 'echo_pipe.echo'},
        },
      );

      final result = await targets(
        selected: preset,
        models: [pipe('echo_pipe.echo')],
      );
      final hidden = await targets(selected: preset);

      check(result.single.id).equals('echo_pipe');
      check(hidden).isEmpty();
    });

    test(
      'only selected, authoritative personal-valve resources appear',
      () async {
        const filter = ToggleFilter(
          id: 'tone_filter',
          name: 'Tone',
          hasUserValves: true,
        );
        const plain = ToggleFilter(id: 'plain_filter', name: 'Plain');
        final selected = Model(
          id: 'base',
          name: 'Base',
          filters: const [filter, plain],
        );
        const tools = [
          Tool(id: 'valved', name: 'Valved', hasUserValves: true),
          Tool(id: 'unknown', name: 'Unknown'),
          Tool(id: 'none', name: 'None', hasUserValves: false),
          Tool(id: 'unselected', name: 'Unselected', hasUserValves: true),
        ];

        final result = await targets(
          selected: selected,
          tools: tools,
          selectedTools: ['valved', 'unknown', 'none'],
          selectedFilters: ['tone_filter', 'plain_filter'],
        );

        check(result.map((t) => '${t.kind.name}:${t.id}'))
            .deepEquals(['function:tone_filter', 'tool:valved']);
      },
    );

    test('the chat.valves permission hides personal settings', () async {
      final denied = {
        'chat': {'valves': false},
      };

      check(await targets(selected: pipe('echo_pipe'), permissions: denied))
          .isEmpty();
      check(
        await targets(
          selected: pipe('echo_pipe'),
          permissions: denied,
          role: 'admin',
        ),
      ).length.equals(1);
    });
  });
}

/// Serves a use-only account's personal valve routes.
ResponseBody Function(RequestOptions) _serverFor() {
  return (request) {
    if (request.path.endsWith('/spec')) return _json(_schema);
    if (request.method == 'GET') {
      return _json({'token': 'secret', 'tags': <String>[]});
    }
    return _json(request.data);
  };
}

class _FixedModels extends Models {
  _FixedModels(this._models);
  final List<Model> _models;

  @override
  Future<List<Model>> build() async => _models;
}

class _FixedTools extends ToolsList {
  _FixedTools(this._tools);
  final List<Tool> _tools;

  @override
  Future<List<Tool>> build() async => _tools;
}

class _Session {
  const _Session(this.userId, this.token, this.role);
  final String userId;
  final String token;
  final String role;
}

class _SessionNotifier extends Notifier<_Session> {
  @override
  _Session build() => const _Session('user-a', 'token-a', 'user');

  void set(_Session value) => state = value;
}

final _sessionProvider = NotifierProvider<_SessionNotifier, _Session>(
  _SessionNotifier.new,
);

class _PolicyNotifier extends Notifier<Map<String, dynamic>> {
  @override
  Map<String, dynamic> build() => const {};

  void set(Map<String, dynamic> permissions) => state = permissions;
}

final _policyProvider = NotifierProvider<_PolicyNotifier, Map<String, dynamic>>(
  _PolicyNotifier.new,
);

class _Harness {
  _Harness._(this.container, this.api, this.requests, this.owner);

  final ProviderContainer container;
  final ApiService api;
  final List<RequestOptions> requests;
  final PersonalValvesOwner owner;

  /// With [realAuth] the client keeps its real auth interceptor and starts
  /// signed in as account A, so a test sees the Authorization header that
  /// would reach the server. Otherwise the interceptors are cleared.
  static Future<_Harness> open(
    FutureOr<ResponseBody> Function(RequestOptions request) handler, {
    String role = 'user',
    List<Override> overrides = const [],
    bool realAuth = false,
  }) async {
    final requests = <RequestOptions>[];
    final api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: realAuth ? 'token-a' : null,
    );
    api.dio.httpClientAdapter = _Adapter((request) {
      requests.add(request);
      return handler(request);
    });
    if (!realAuth) api.dio.interceptors.clear();
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) => _server),
        authTokenProvider3.overrideWith(
          (ref) => ref.watch(_sessionProvider).token,
        ),
        currentUserProvider2.overrideWith((ref) {
          final session = ref.watch(_sessionProvider);
          return User(
            id: session.userId,
            username: session.userId,
            email: '${session.userId}@example.com',
            role: role,
          );
        }),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) {
          ref.watch(_sessionProvider);
          return Object();
        }),
        // Permissions are fetched through the shared transport, which these
        // tests do not exercise; the policy is a fixture they can change.
        userPermissionsProvider.overrideWith(
          (ref) => ref.watch(_policyProvider),
        ),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    await container.read(activeServerProvider.future);
    final owner = PersonalValvesOwner.capture(container.read)!;
    return _Harness._(container, api, requests, owner);
  }

  void setPermissions(Map<String, dynamic> permissions) =>
      container.read(_policyProvider.notifier).set(permissions);

  void signInAs(String userId, String token) => container
      .read(_sessionProvider.notifier)
      .set(_Session(userId, token, 'user'));

  PersonalValvesEditorKey _key(PersonalValvesTarget target) =>
      PersonalValvesEditorKey(owner, target);

  PersonalValvesEditor editor(PersonalValvesTarget target) {
    final provider = personalValvesEditorProvider(_key(target));
    // A listener keeps the auto-dispose editor alive like an open sheet.
    container.listen(provider, (_, _) {});
    return container.read(provider.notifier);
  }

  PersonalValvesEditorState state(PersonalValvesTarget target) =>
      container.read(personalValvesEditorProvider(_key(target)));

  Future<void> settled(PersonalValvesTarget target) async {
    for (var i = 0; i < 50; i++) {
      await pumpEventQueue();
      if (state(target).phase != PersonalValvesPhase.loading) return;
    }
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions request) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? value, {int statusCode = 200}) => ResponseBody(
  Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
  statusCode,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);
