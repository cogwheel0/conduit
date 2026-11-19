@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_terminal_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:fake_async/fake_async.dart';
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
  role: 'admin',
);

/// `automations.*` over one signed-in account whose server answers from
/// memory; another account signs in on the same server mid-way.
void main() {
  late _Api api;
  late Object epoch;
  late Completer<void> modelsListed;

  setUp(() {
    api = _Api();
    epoch = Object();
    modelsListed = Completer<void>()..complete();
  });
  tearDown(() => api.dispose());

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) {
          ref.watch(openWebUiAuthSessionEpochProvider);
          return api;
        }),
        currentUserProvider2.overrideWith((ref) => _ava),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('token'),
        activeServerProvider.overrideWith((ref) async => _server),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        backendConfigProvider.overrideWith(_Config.new),
        userPermissionsProvider.overrideWith(
          (ref) async => const <String, dynamic>{},
        ),
        modelsProvider.overrideWith(() => _Models(() => modelsListed.future)),
        channelsListProvider.overrideWith(_Channels.new),
        foldersProvider.overrideWith(_Folders.new),
        automationTerminalsProvider.overrideWith((ref) async => _benches),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    return container;
  }

  /// For a test on fake time: the already-answered waits are made again
  /// in its zone (a future completed outside it would never be heard).
  void answeredInThisZone() {
    modelsListed = Completer<void>()..complete();
    api.agentsListed = Completer<void>()..complete();
  }

  void signInAnother(ProviderContainer c) {
    epoch = Object();
    c.invalidate(openWebUiAuthSessionEpochProvider);
  }

  test("an editor's agent question still out never goes to the next "
      "account's server", () {
    fakeAsync((time) {
      answeredInThisZone();
      final c = container();
      _settled(time, c.read(activeServerProvider.future));
      final service = AutomationsService(c);
      addTearDown(service.dispose);
      api.withTerminal = true;
      final ava = api;
      // Opening: Ava's terminal is slow to list its agents (its wait's own
      // timeout never runs out: the clock does not move).
      ava.agentsListed = Completer<void>();
      final opening = _Outcome(
        service.editor(const AutomationEditorOpen(id: 't1')),
      );
      time.elapse(Duration.zero);
      expect(ava.agentsAsked.isCompleted, isTrue);
      // Another account signs in on a server of its own; the editor closes.
      final next = _Api();
      addTearDown(ava.dispose);
      api = next;
      signInAnother(c);
      c.read(apiServiceProvider);
      _settled(time, c.pump());
      ava.agentsListed.complete();
      time.elapse(Duration.zero);
      expect(opening.reason, 'accountChanged');
      _settled(time, c.pump());
      expect(next.agentCalls, 0, reason: "Ava's task asked of the next server");
    });
  });

  test(
    'an open editor asks for no agents once another account signed in',
    () async {
      final c = container();
      await c.read(activeServerProvider.future);
      final service = AutomationsService(c);
      addTearDown(service.dispose);
      api.withTerminal = true;
      final open = await service.editor(const AutomationEditorOpen(id: 't1'));
      expect(api.agentCalls, 1);
      // Another account signs in, on a server of its own.
      signInAnother(c);
      await c.pump();
      expect(api.agentCalls, 1, reason: "Ava's task asked of the next server");
      await expectLater(
        service.terminals(
          AutomationDraftEdit(token: open.token, fields: open.fields),
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.args['reason'],
            'reason',
            'editorClosed',
          ),
        ),
      );
    },
  );

  test("an older agent answer never replaces a newer one's, though both "
      'asked the same', () {
    fakeAsync((time) {
      answeredInThisZone();
      final c = container();
      _settled(time, c.read(activeServerProvider.future));
      final service = AutomationsService(c);
      addTearDown(service.dispose);
      api.withTerminal = true;
      api.numbered = true;
      final open = _settled(
        time,
        service.editor(const AutomationEditorOpen(id: 't1')),
      );
      AutomationDraftEdit at(String cwd) => AutomationDraftEdit(
        token: open.token,
        fields: open.fields.copyWith(workingDirectory: cwd),
      );
      // A's first question is slow; B's, and A's again, answer at once.
      api.agentHolds[api.agentCalls] = Completer<void>();
      final slow = api.agentHolds[api.agentCalls]!;
      _Outcome(service.terminals(at('/work/a')));
      time.elapse(Duration.zero);
      _settled(time, service.terminals(at('/work/b')));
      final again = _settled(time, service.terminals(at('/work/a')));
      final newest = again.models!.where((m) => m.agent).single.id;
      slow.complete();
      time.elapse(Duration.zero);
      final after = _settled(time, service.terminals(at('/work/a')));
      expect(after.models!.where((m) => m.agent).single.id, newest);
    });
  });

  test("a failed agent question is asked again by the terminals' list", () {
    fakeAsync((time) {
      answeredInThisZone();
      final c = container();
      _settled(time, c.read(activeServerProvider.future));
      final service = AutomationsService(c);
      addTearDown(service.dispose);
      api.withTerminal = true;
      api.agentFailures = 1;
      final open = _settled(
        time,
        service.editor(const AutomationEditorOpen(id: 't1')),
      );
      expect(open.agentsUnknown, isTrue);
      // The terminal answers again: the next list asks, and lists them.
      final listed = _settled(
        time,
        service.terminals(
          AutomationDraftEdit(token: open.token, fields: open.fields),
        ),
      );
      expect(listed.models!.where((m) => m.agent), isNotEmpty);
      expect(api.agentCalls, 2);
    });
  });

  group("a task editor's answer after the terminal's agents load", () {
    test('is refused once another account signed in', () {
      fakeAsync((time) {
        answeredInThisZone();
        final c = container();
        _settled(time, c.read(activeServerProvider.future));
        final service = AutomationsService(c);
        addTearDown(service.dispose);
        api.withTerminal = true;
        // Opening: the task's terminal is slow to list its agents.
        api.agentsListed = Completer<void>();
        final opening = _Outcome(
          service.editor(const AutomationEditorOpen(id: 't1')),
        );
        time.elapse(Duration.zero);
        expect(api.agentsAsked.isCompleted, isTrue);
        signInAnother(c);
        api.agentsListed.complete();
        time.elapse(Duration.zero);
        expect(opening.reason, 'accountChanged');

        // The terminals' list of an editor open before the switch.
        final c2 = container();
        _settled(time, c2.read(activeServerProvider.future));
        final second = AutomationsService(c2);
        addTearDown(second.dispose);
        final open = _settled(
          time,
          second.editor(const AutomationEditorOpen(id: 't1')),
        );
        api.agentsListed = Completer<void>();
        api.agentsAsked = Completer<void>();
        final listing = _Outcome(
          second.terminals(
            AutomationDraftEdit(
              token: open.token,
              fields: open.fields.copyWith(workingDirectory: '/srv/other'),
            ),
          ),
        );
        time.elapse(Duration.zero);
        expect(api.agentsAsked.isCompleted, isTrue);
        signInAnother(c2);
        api.agentsListed.complete();
        time.elapse(Duration.zero);
        expect(listing.reason, 'accountChanged');
      });
    });

    test('is refused, not an error, once newer editors closed it', () {
      fakeAsync((time) {
        answeredInThisZone();
        final c = container();
        _settled(time, c.read(activeServerProvider.future));
        final service = AutomationsService(c);
        addTearDown(service.dispose);
        api.withTerminal = true;
        api.agentsListed = Completer<void>();
        final opening = _Outcome(
          service.editor(const AutomationEditorOpen(id: 't1')),
        );
        time.elapse(Duration.zero);
        expect(api.agentsAsked.isCompleted, isTrue);
        // Eight more editors open (new tasks: no terminal to wait for), and
        // the first is the oldest.
        for (var i = 0; i < 8; i++) {
          _settled(time, service.editor(const AutomationEditorOpen()));
        }
        api.agentsListed.complete();
        time.elapse(Duration.zero);
        expect(opening.reason, 'editorClosed');
      });
    });
  });

  test(
    "a check takes the folder the window sends with the task's terminal",
    () async {
      final c = container();
      await c.read(activeServerProvider.future);
      final service = AutomationsService(c);
      addTearDown(service.dispose);
      api.withTerminal = true;
      final open = await service.editor(const AutomationEditorOpen(id: 't1'));
      expect(open.fields.terminalId, 'north');
      // The window moved the task to south and a folder was typed there
      // before any answer came back: the request carries both.
      final state = await service.checkDraft(
        AutomationDraftEdit(
          token: open.token,
          fields: open.fields.copyWith(
            terminalId: 'south',
            workingDirectory: '/srv/south-repo',
          ),
        ),
      );
      expect(state.fields.terminalId, 'south');
      expect(state.fields.workingDirectory, '/srv/south-repo');
      expect(state.fields.modelId, '', reason: "north's agent kept on south");
    },
  );

  test("a Run Now result stays with the account that ran it", () async {
    final c = container();
    await c.read(activeServerProvider.future);
    final events = EventBus();
    final finished = Completer<void>();
    events.attach('window', (envelope) {
      if (envelope.event == ConduitEventSpecs.automationsRunProgress.name &&
          envelope.payload['phase'] == 'finished' &&
          !finished.isCompleted) {
        finished.complete();
      }
    });
    final service = AutomationsService(
      c,
      events: events,
      pollInterval: Duration.zero,
    );
    addTearDown(service.dispose);
    const task = AutomationRef(id: 't1');

    final started = await service.run(task);
    expect(started.phase, 'waiting');
    api.runsNow = [
      const AutomationRun(
        id: 'r1',
        automationId: 't1',
        status: AutomationRun.statusSuccess,
        chatId: 'ava-private-result',
        createdAtNs: 2,
      ),
    ];
    await finished.future;
    expect(service.runState(task).phase, 'finished');

    signInAnother(c);
    final shown = service.runState(task);
    expect(
      shown.phase,
      'idle',
      reason: "Ava's run is shown to the next account",
    );
    expect(
      shown.run,
      isNull,
      reason: "Ava's result chat is shown to the next account",
    );
  });

  test('a task read under one account is never shown to the next', () async {
    final c = container();
    await c.read(activeServerProvider.future);
    final service = AutomationsService(c);
    addTearDown(service.dispose);
    for (final read in <Future<Object?> Function()>[
      () => service.get(const AutomationRef(id: 't1')),
      () => service.editor(const AutomationEditorOpen(id: 't1')),
    ]) {
      // The names the detail shows load slowly: another account signs in
      // meanwhile.
      modelsListed = Completer<void>();
      c.invalidate(modelsProvider);
      api.asked = Completer<void>();
      final reading = read();
      await api.asked.future;
      // Ava's task is read; the names are still loading.
      await pumpEventQueue();
      signInAnother(c);
      if (!modelsListed.isCompleted) modelsListed.complete();
      await expectLater(
        reading,
        throwsA(
          isA<RpcError>().having(
            (e) => e.args['reason'],
            'reason',
            'accountChanged',
          ),
        ),
      );
    }
  });

  test('a Save that carries a schedule kind saves that kind', () async {
    final c = container();
    await c.read(activeServerProvider.future);
    final service = AutomationsService(c);
    addTearDown(service.dispose);
    final open = await service.editor(const AutomationEditorOpen(id: 't1'));
    expect(open.fields.schedule.kind, 'daily');
    // Weekly was chosen; its check had not answered when Save went.
    final saved = await service.save(
      AutomationDraftEdit(
        token: open.token,
        fields: open.fields,
        chooseKind: 'weekly',
      ),
    );
    expect(saved.saved, isTrue, reason: '${saved.issues} ${saved.failure}');
    expect(
      api.updatedForms.single.data['rrule'],
      startsWith('RRULE:FREQ=WEEKLY'),
    );
  });

  test(
    "a saved task's editor saves later edits to it, not as another task",
    () async {
      final c = container();
      await c.read(activeServerProvider.future);
      final service = AutomationsService(c);
      addTearDown(service.dispose);
      final editor = await service.editor(const AutomationEditorOpen());
      final first = editor.fields.copyWith(
        name: 'Allotment digest',
        prompt: 'List what to sow this week',
        modelId: 'm1',
      );
      final saved = await service.save(
        AutomationDraftEdit(token: editor.token, fields: first),
      );
      expect(saved.saved, isTrue, reason: '${saved.issues} ${saved.failure}');
      // Words typed while that save was out go next, to the same task.
      final again = await service.save(
        AutomationDraftEdit(
          token: editor.token,
          fields: first.copyWith(prompt: 'List what to sow and to harvest'),
        ),
      );
      expect(again.saved, isTrue, reason: '${again.issues} ${again.failure}');
      expect(api.created, hasLength(1), reason: 'the task was made twice');
      expect(api.updated, ['t1']);
    },
  );
}

/// [future]'s value once it settles on fake time (the clock does not move).
T _settled<T>(FakeAsync time, Future<T> future) {
  final outcome = _Outcome(future);
  time.elapse(Duration.zero);
  if (outcome.error != null) throw outcome.error!;
  expect(outcome.done, isTrue, reason: 'still waiting');
  return outcome.value as T;
}

/// A future's outcome, read on fake time once it settles.
final class _Outcome {
  _Outcome(Future<Object?> future) {
    future.then(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    );
  }

  Object? value;
  Object? error;
  bool done = false;

  /// The refusal's reason, when it was refused with an [RpcError].
  String? get reason => switch (error) {
    final RpcError e => e.args['reason'],
    _ => null,
  };
}

/// The server's own terminals for tasks.
final _benches = <TerminalServerInfo>[
  for (final id in const ['north', 'south'])
    TerminalServerInfo(
      kind: TerminalServerKind.system,
      selectionId: id,
      systemServerId: id,
      name: 'Bench $id',
      baseUrl: Uri.parse('http://127.0.0.1:9/$id'),
    ),
];


/// The account's server, answered from memory.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager());

  List<AutomationRun> runsNow = const <AutomationRun>[];
  Completer<void> asked = Completer<void>();

  /// The task runs north's coding agent on terminal north, in a folder.
  bool withTerminal = false;

  /// The terminal's agents answer once [agentsListed] completes;
  /// [agentsAsked] marks the first question, [agentCalls] counts them.
  Completer<void> agentsListed = Completer<void>()..complete();
  Completer<void> agentsAsked = Completer<void>();
  var agentCalls = 0;

  /// Per question (by its number from 0), a wait before it answers.
  final agentHolds = <int, Completer<void>>{};

  /// How many questions fail before the terminal answers again.
  var agentFailures = 0;

  /// Each answer names its question by number (`call-<n>`).
  var numbered = false;

  @override
  Future<List<core.Model>> getTerminalAgentModels({
    required String terminalId,
    String? chatId,
    String? cwd,
    String? terminalName,
    bool forAutomation = false,
    String? automationId,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final n = agentCalls++;
    if (!agentsAsked.isCompleted) agentsAsked.complete();
    await (agentHolds[n]?.future ?? agentsListed.future);
    if (n < agentFailures) throw StateError('the terminal is out of reach');
    final model = numbered ? 'call-$n' : 'gpt-test';
    return <core.Model>[
      core.Model(id: 'agent:$terminalId:codex:$model', name: 'Codex · $model'),
    ];
  }

  static const _onTerminal = Automation(
    id: 't1',
    userId: 'user-1',
    name: 'Nightly lint',
    data: <String, dynamic>{
      'prompt': 'Run the linter and summarise',
      'model_id': 'agent:north:codex:gpt-test',
      'rrule': 'RRULE:FREQ=DAILY;BYHOUR=2;BYMINUTE=0',
      'target': <String, dynamic>{'type': 'chat'},
      'terminal': <String, dynamic>{
        'server_id': 'north',
        'cwd': '/srv/north-repo',
      },
    },
    isActive: true,
  );

  static const _task = Automation(
    id: 't1',
    userId: 'user-1',
    name: 'Morning digest',
    data: <String, dynamic>{
      'prompt': 'Summarize my notes',
      'model_id': 'm1',
      'rrule': 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
      'target': <String, dynamic>{'type': 'chat'},
    },
    isActive: true,
  );

  @override
  Future<AutomationPage> getAutomations({
    String? query,
    String? status,
    String? folderId,
    int page = 1,
    required ApiAuthSnapshot authSnapshot,
  }) async => const AutomationPage(items: [_task], total: 1);

  @override
  Future<Automation> getAutomation(
    String id, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    if (!asked.isCompleted) asked.complete();
    return withTerminal ? _onTerminal : _task;
  }

  @override
  Future<List<AutomationRun>> getAutomationRuns(
    String id, {
    int skip = 0,
    int limit = automationRunsPageSize,
    required ApiAuthSnapshot authSnapshot,
  }) async => runsNow;

  final created = <AutomationForm>[];
  final updated = <String>[];
  final updatedForms = <AutomationForm>[];

  @override
  Future<Automation> createAutomation(
    AutomationForm form, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    created.add(form);
    return _task;
  }

  @override
  Future<Automation> updateAutomation(
    String id,
    AutomationForm form, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    updated.add(id);
    updatedForms.add(form);
    return _task;
  }

  @override
  Future<Automation> runAutomation(
    String id, {
    required ApiAuthSnapshot authSnapshot,
  }) async => _task;
}

final class _Config extends BackendConfigNotifier {
  /// Kept as built: the config is read from memory, never the network.
  @override
  Future<void> refresh() async {}

  @override
  Future<BackendConfig?> build() async => const BackendConfig(
    serverId: 'server',
    enableAutomations: true,
    version: '0.13.3',
  );
}

final class _Models extends Models {
  _Models(this.listed);

  /// Read at each build: an invalidated provider keeps its notifier.
  final Future<void> Function() listed;

  @override
  Future<List<core.Model>> build() async {
    await listed();
    return const <core.Model>[core.Model(id: 'm1', name: 'Notes model')];
  }
}

final class _Channels extends ChannelsList {
  @override
  Future<List<Channel>> build() async => const <Channel>[];
}

final class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const <Folder>[];
}
