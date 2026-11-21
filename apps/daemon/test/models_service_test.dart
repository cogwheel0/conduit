@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        ModelControlChoicesNotifier,
        modelControlChoicesProvider,
        openWebUiChatSettingsAccessProvider;
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show directModelRegistryProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesFastTierSelectionProvider;
import 'package:conduit_core/features/terminal/models/terminal_agent_model.dart'
    show terminalAgentModelFromJson;
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart'
    show
        terminalAvailableServersProvider,
        terminalServiceProvider,
        terminalSystemServersForChatProvider;
import 'package:conduit_core/features/tools/providers/tools_providers.dart'
    show selectedTerminalIdProvider;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/models/model_controls.dart'
    show ModelControlChoices;
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountKind, PrimaryAccountRef, primaryAccountProvider;
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart' hide ReviewerMode;
import 'package:conduitd/conduitd.dart';
import 'package:checks/checks.dart';
import 'package:fake_async/fake_async.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _cached = core.Model(id: 'cached-model', name: 'Cached model');

/// The core's model list with the server out of reach: the cached list
/// first, then the refresh behind it fails, and the list stays beside the
/// error.
final class _Unreachable extends Models {
  @override
  Future<List<core.Model>> build() async => const [_cached];

  /// What the refresh behind the cached list leaves.
  void refreshFailed() => state = AsyncError<List<core.Model>>(
    const SocketException('No route to host'),
    StackTrace.current,
  );
}

/// A server offering two models.
final class _Listed extends Models {
  @override
  Future<List<core.Model>> build() async => const [
    core.Model(id: 'first-model', name: 'First model'),
    core.Model(id: 'preferred-model', name: 'Preferred'),
  ];
}

/// A model one of the user's devices offers, as Open WebUI 0.13.4 lists it,
/// beside one of the server's own.
final class _OnDevices extends Models {
  @override
  Future<List<core.Model>> build() async => [
    core.Model.fromJson(const <String, dynamic>{
      'id': 'qwen3:8b',
      'name': 'qwen3:8b',
      'owned_by': 'openai',
      'connection_type': 'local',
      'tags': <dynamic>[
        <String, dynamic>{'name': 'Studio Mac · Garage lab'},
      ],
      'owner_id': 'user-1',
      'base_url': 'tether://3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d',
      'service': 'garage_lab',
    }),
    const core.Model(id: 'first-model', name: 'First model'),
  ];
}

/// Two Hermes models that both offer the Fast tier.
final class _Fast extends Models {
  @override
  Future<List<core.Model>> build() async => const [
    core.Model(id: 'fast-a', name: 'Fast A', metadata: {'hermesFast': true}),
    core.Model(id: 'fast-b', name: 'Fast B', metadata: {'hermesFast': true}),
  ];
}

/// The account's settings on its server, loaded once [loaded] completes.
final class _Personal extends PersonalizationSettings {
  _Personal(this.loaded);

  final Future<void> loaded;
  final toggled = <String>[];

  @override
  Future<ServerUserSettings> build() async {
    await loaded;
    return const ServerUserSettings();
  }

  @override
  Future<ServerUserSettings> togglePinnedModel(String modelId) async {
    toggled.add(modelId);
    return const ServerUserSettings();
  }
}

/// [_Fast]'s models, read once [gate] (when set) completes.
final class _FastGated extends Models {
  static Completer<void>? gate;

  @override
  Future<List<core.Model>> build() async {
    await gate?.future;
    return const [
      core.Model(id: 'fast-a', name: 'Fast A', metadata: {'hermesFast': true}),
      core.Model(id: 'fast-b', name: 'Fast B', metadata: {'hermesFast': true}),
    ];
  }
}

/// A future's outcome, read on fake time once it settles: its value, or
/// the code of the [RpcError] it was refused with.
/// What [models] captures of a turn about to be sent from [chatId], in a
/// fake-async test: captured at once, its New Chat check settled here.
ModelSend _sendingIn(FakeAsync time, ModelsService models, String? chatId) {
  final outcome = _Outcome(models.sending(chatId));
  time.elapse(Duration.zero);
  return outcome.value! as ModelSend;
}

final class _Outcome {
  _Outcome(Future<Object?> future) {
    future.then(
      (v) => value = v,
      onError: (Object e) => refusal = e is RpcError ? e.code : '$e',
    );
  }

  Object? value;
  String? refusal;
}

/// A server offering exactly [models].
final class _These extends Models {
  _These(this.models);

  final List<core.Model> models;

  @override
  Future<List<core.Model>> build() async => models;
}

/// A server offering two models once [listed] completes.
final class _Held extends Models {
  _Held(this.listed);

  final Future<void> listed;

  @override
  Future<List<core.Model>> build() async {
    await listed;
    return const [
      core.Model(id: 'first-model', name: 'First model'),
      core.Model(id: 'preferred-model', name: 'Preferred'),
    ];
  }
}

/// Account A's one model while [first] is the session, held until [listed];
/// any other session's is B's.
final class _PerAccount extends Models {
  _PerAccount(this.first, this.listed);

  final Object first;
  final Future<void> listed;

  @override
  Future<List<core.Model>> build() async {
    if (!identical(ref.watch(openWebUiAuthSessionEpochProvider), first)) {
      return const [core.Model(id: 'b-model', name: 'B model')];
    }
    await listed;
    return const [core.Model(id: 'a-model', name: 'A model')];
  }
}

/// Signed out, or never signed in: there is no list to fall back on.
final class _Failing extends Models {
  @override
  Future<List<core.Model>> build() async =>
      throw const SocketException('No route to host');
}

const _northAgent = 'agent:north:codex:gpt-test';
const _southAgent = 'agent:south:pi:test';

/// The server's own terminals, north and south.
final _terminals = <TerminalServerInfo>[
  TerminalServerInfo(
    kind: TerminalServerKind.system,
    selectionId: 'north',
    systemServerId: 'north',
    name: 'North bench',
    baseUrl: Uri.parse('http://127.0.0.1:9/north'),
  ),
  TerminalServerInfo(
    kind: TerminalServerKind.system,
    selectionId: 'south',
    systemServerId: 'south',
    name: 'South bench',
    baseUrl: Uri.parse('http://127.0.0.1:9/south'),
  ),
];

/// A server whose terminal north offers one coding agent, and south none.
final class _AgentsApi extends ApiService {
  _AgentsApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Home server',
          url: 'https://home.invalid',
        ),
        workerManager: WorkerManager(),
      );

  final asked = <String>[];

  /// North's answers wait for this while it is set; [northAsked] marks the
  /// question reaching it.
  Completer<void>? held;
  final northAsked = Completer<void>();

  /// How many more times north answers with its agent (null: always);
  /// after that it answers with none.
  int? northAnswers;

  /// South's answers wait for this while it is set; [southAsked] marks the
  /// question reaching it.
  Completer<void>? southHeld;
  final southAsked = Completer<void>();

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
    asked.add(terminalId);
    if (terminalId == 'north') {
      if (!northAsked.isCompleted) northAsked.complete();
      await held?.future;
    }
    if (terminalId == 'south') {
      if (!southAsked.isCompleted) southAsked.complete();
      await southHeld?.future;
    }
    // South's agent works in plain-chat's workspace.
    if (terminalId == 'south') {
      return chatId == 'plain-chat'
          ? const [core.Model(id: _southAgent, name: 'Pi · test')]
          : const <core.Model>[];
    }
    // North's agent works in agent-chat's workspace, and in a new chat.
    if (terminalId != 'north' || (chatId != 'agent-chat' && chatId != null)) {
      return const <core.Model>[];
    }
    final left = northAnswers;
    if (left != null) {
      if (left <= 0) return const <core.Model>[];
      northAnswers = left - 1;
    }
    return [_north(efforts: chatId == null ? _newChatEfforts : _chatEfforts)];
  }
}

const _chatEfforts = <String>['low', 'high'];
const _newChatEfforts = <String>['low', 'high', 'max'];

/// North's agent as it offers itself, with an effort control of [efforts].
core.Model _north({required List<String> efforts}) => core.Model(
  id: _northAgent,
  name: 'Codex · gpt-test',
  metadata: <String, dynamic>{
    'info': <String, dynamic>{
      'params': <String, dynamic>{
        'model_controls': <String, dynamic>{
          'reasoning_effort': <String, dynamic>{
            'label': 'Effort',
            'options': <String, dynamic>{
              for (final effort in efforts)
                effort: <String, dynamic>{'label': effort},
            },
          },
        },
      },
    },
  },
);

/// No saved control picks (none asked of a server).
final class _NoChoices extends ModelControlChoicesNotifier {
  @override
  Future<ModelControlChoices> build() async =>
      const <String, Map<String, String>>{};
}

final class _ReviewerOff extends ReviewerMode {
  @override
  bool build() => false;
}

/// Chats `agent-chat` (started with north's agent) and `plain-chat`.
Conversation _conversation(String id) => Conversation(
  id: id,
  title: 'Bench chat',
  createdAt: DateTime.utc(2026, 3, 1),
  updatedAt: DateTime.utc(2026, 3, 1),
  model: id == 'agent-chat' ? _northAgent : 'first-model',
);

/// The session the agent tests' container reads; another sign-in replaces it.
Object _session = Object();

/// The primary account the agent tests' container reads.
const _home = PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'home');
PrimaryAccountRef _primary = _home;

/// [_primary] is [to] from now on, as an account switch leaves it.
void _switchTo(ProviderContainer container, PrimaryAccountRef to) {
  _primary = to;
  container.invalidate(primaryAccountProvider);
  container.read(primaryAccountProvider);
}

/// Account settings whose pin toggles wait for [held] while it is set.
final class _HeldPins extends PersonalizationSettings {
  Completer<void>? held;
  final toggleAsked = Completer<void>();

  @override
  Future<ServerUserSettings> build() async => const ServerUserSettings();

  @override
  Future<ServerUserSettings> togglePinnedModel(String modelId) async {
    if (!toggleAsked.isCompleted) toggleAsked.complete();
    await held?.future;
    return const ServerUserSettings();
  }
}

/// The chats read, in order; a read waits for [_chatHeld] while it is set,
/// and `gone-chat` cannot be read.
final _chatReads = <String>[];

/// The terminal list cannot be read while this is set.
var _terminalsUnreadable = false;

/// The terminals the server offers now, in its list and as a fresh read of
/// its own answers them.
var _offered = _terminals;

/// The server's own terminals as it lists them for a saved chat, when not
/// [_offered]'s (the sidebar's list leaves out one that needs a saved chat).
List<TerminalServerInfo>? _offeredToChats;

/// A fresh read of the server's own terminals fails while this is set.
var _systemUnreadable = false;

/// A fresh read of the server's own terminals waits for this while it is
/// set; [_systemAsked] completes as one starts.
Completer<void>? _systemHeld;
Completer<void> _systemAsked = Completer<void>();

/// The server's own terminals, read afresh: [_offered].
final class _SystemTerminals extends TerminalService {
  _SystemTerminals(super.api);

  @override
  Future<List<TerminalServerInfo>> getSystemTerminalServers() async {
    if (!_systemAsked.isCompleted) _systemAsked.complete();
    await _systemHeld?.future;
    if (_systemUnreadable) throw StateError('the terminals are unreadable');
    return _offered;
  }
}

/// The account's default model resolves once this completes, when set.
Completer<void>? _defaultHeld;
Completer<void>? _chatHeld;
Completer<void> _chatAsked = Completer<void>();

/// A container for the agent tests: [api]'s terminals, with south selected.
ProviderContainer _agentContainer(
  _AgentsApi api, {
  Models Function() models = _Listed.new,
  List<Override> extra = const [],
}) {
  _session = Object();
  _primary = _home;
  _chatReads.clear();
  _chatHeld = null;
  _terminalsUnreadable = false;
  _offered = _terminals;
  _offeredToChats = null;
  _systemUnreadable = false;
  _systemHeld = null;
  _systemAsked = Completer<void>();
  _defaultHeld = null;
  _chatAsked = Completer<void>();
  final container = ProviderContainer(
    overrides: [
      openWebUiAuthSessionEpochProvider.overrideWith((ref) => _session),
      primaryAccountProvider.overrideWith((ref) => _primary),
      modelsProvider.overrideWith(models),
      apiServiceProvider.overrideWithValue(api),
      reviewerModeProvider.overrideWith(_ReviewerOff.new),
      openWebUiAccountAvailableProvider.overrideWithValue(true),
      terminalAgentsSupportedProvider.overrideWithValue(true),
      terminalAvailableServersProvider.overrideWith((ref) async {
        if (_terminalsUnreadable) {
          throw StateError('the terminal list is unreadable');
        }
        return _offered;
      }),
      terminalServiceProvider.overrideWithValue(_SystemTerminals(api)),
      // A saved chat's terminals, as the server lists them for it.
      terminalSystemServersForChatProvider.overrideWithValue((chatId) async {
        if (_terminalsUnreadable) {
          throw StateError('the terminal list is unreadable');
        }
        return [
          for (final server in _offeredToChats ?? _offered)
            if (server.isAvailableForChatScope(chatId)) server,
        ];
      }),
      defaultModelProvider.overrideWith((ref) async {
        await _defaultHeld?.future;
        return const core.Model(id: 'first-model', name: 'First model');
      }),
      loadConversationProvider.overrideWith((ref, id) async {
        _chatReads.add(id);
        if (!_chatAsked.isCompleted) _chatAsked.complete();
        await _chatHeld?.future;
        if (id == 'gone-chat') throw StateError('no chat $id here');
        return _conversation(id);
      }),
      ...extra,
    ],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  container.read(selectedTerminalIdProvider.notifier).set('south');
  container
      .read(selectedModelProvider.notifier)
      .set(const core.Model(id: 'first-model', name: 'First model'));
  return container;
}

void main() {
  Matcher refused(String code) =>
      throwsA(isA<RpcError>().having((e) => e.code, 'code', code));

  group('a chat started with a coding agent', () {
    const listed = ModelListQuery(chatId: 'agent-chat');

    test('tells the window its agent, the selection left as it is', () async {
      final api = _AgentsApi();
      final container = _agentContainer(api);
      final list = await ModelsService(container).list(listed);
      expect(list.selectedId, 'first-model');
      expect(list.chatAgent, _northAgent);
      expect(container.read(selectedModelProvider)?.id, 'first-model');
      expect(container.read(selectedTerminalIdProvider), 'south');
      expect(api.asked, isNot(contains('north')));
    });

    test('switches to it on its own terminal when the window asks', () async {
      final api = _AgentsApi();
      final container = _agentContainer(api);
      final list = await ModelsService(container)
          .select(_northAgent, chatId: 'agent-chat');
      expect(list.selectedId, _northAgent);
      // The chat's own pick is its saved agent now: no Switch to offer.
      expect(list.chatAgent, isNull);
      expect(container.read(selectedTerminalIdProvider), 'north');

      // North runs agents only in a saved chat: the sidebar's list leaves it
      // out, the chat's own list has it. Switch still finds it there.
      final northSavedOnly = TerminalServerInfo(
        kind: TerminalServerKind.system,
        selectionId: 'north',
        systemServerId: 'north',
        name: 'North bench',
        baseUrl: Uri.parse('http://127.0.0.1:9/north'),
        requiresSavedChatContext: true,
      );
      final saved = _agentContainer(_AgentsApi());
      _offered = [_terminals.last];
      _offeredToChats = [northSavedOnly, _terminals.last];
      addTearDown(() {
        _offered = _terminals;
        _offeredToChats = null;
      });
      expect(saved.read(selectedTerminalIdProvider), 'south');
      final switched = await ModelsService(saved)
          .select(_northAgent, chatId: 'agent-chat');
      expect(switched.selectedId, _northAgent);
      expect(saved.read(selectedTerminalIdProvider), 'north');
    });

    test('tells the window its agent though the account selected it', () async {
      final api = _AgentsApi();
      final container = _agentContainer(api);
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      // Picked in another window's chat: the account's selection.
      await models.select(_northAgent);
      final list = await models.list(
        const ModelListQuery(chatId: 'agent-chat'),
      );
      expect(list.selectedId, 'first-model');
      expect(list.chatAgent, _northAgent);
    });

    test('names no agent for a chat with an ordinary model', () async {
      final container = _agentContainer(_AgentsApi());
      final list = await ModelsService(container)
          .list(const ModelListQuery(chatId: 'plain-chat'));
      expect(list.chatAgent, isNull);
    });
  });

  group("a chat's own requests", () {
    test('are never made again for the next account', () async {
      final container = _agentContainer(_AgentsApi());
      _chatHeld = Completer<void>();
      final listing = ModelsService(container)
          .list(const ModelListQuery(chatId: 'plain-chat'));
      await _chatAsked.future;
      _session = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      _chatHeld!.complete();
      await expectLater(listing, refused(ConduitErrorCodes.sessionExpired));
      expect(_chatReads, <String>['plain-chat'], reason: 'read again for B');
    });

    test('offer no agents for a chat that could not be read', () async {
      final api = _AgentsApi();
      final container = _agentContainer(api);
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      final list = await models.list(const ModelListQuery(chatId: 'gone-chat'));
      expect(list.agents, isEmpty);
      await expectLater(
        models.select(_northAgent, chatId: 'gone-chat'),
        refused(ConduitErrorCodes.notFound),
      );
      expect(container.read(selectedModelProvider)?.id, 'first-model');
      // Neither request asked the terminal: an unread chat is not a new one.
      expect(api.asked, isNot(contains('north')));
    });
  });

  test("Switch never asks the next account's server for the chat's agent", () {
    fakeAsync((time) {
      final api = _AgentsApi()..southHeld = Completer<void>();
      final container = _agentContainer(api);
      // Switch under A: the selected terminal (south) is asked first, slowly.
      final switching = _Outcome(
        ModelsService(container).select(_northAgent, chatId: 'agent-chat'),
      );
      time.elapse(Duration.zero);
      expect(api.southAsked.isCompleted, isTrue);
      // B signs in; south then answers A with no agent.
      _session = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      api.southHeld!.complete();
      time.elapse(Duration.zero);
      expect(switching.refusal, ConduitErrorCodes.sessionExpired);
      expect(api.asked, <String>[
        'south',
      ], reason: "A's chat asked of north for B");
      expect(container.read(selectedModelProvider)?.id, 'first-model');
    });
  });
  test("a picked agent is not offered in another chat's workspace", () async {
    final api = _AgentsApi();
    final container = _agentContainer(api);
    container.read(selectedTerminalIdProvider.notifier).set('north');
    final models = ModelsService(container);
    final picked = await models.select(_northAgent, chatId: 'agent-chat');
    expect(picked.selectedId, _northAgent);
    // Another chat on the same terminal, whose lookup finds no agent: the
    // agent is not offered there, so the window names another model.
    final other = await models.list(const ModelListQuery(chatId: 'plain-chat'));
    expect(other.selectedId, 'first-model');
    expect(
      other.agents,
      isEmpty,
      reason: "agent-chat's agent offered in plain-chat",
    );
  });

  test('a lookup that finds none never changes the agent picked', () async {
    final api = _AgentsApi()..northAnswers = 1;
    final container = _agentContainer(api);
    container.read(selectedTerminalIdProvider.notifier).set('north');
    final list = await ModelsService(container)
        .select(_northAgent, chatId: 'agent-chat');
    // The pick's own list asked north again, and north answered with none:
    // the list reports what north offers now, and the pick stays.
    expect(api.asked.where((t) => t == 'north'), hasLength(2));
    expect(list.selectedId, _northAgent);
    // The chat's own pick stays on offer beside what north lists now.
    expect(list.agents.map((m) => m.id), <String>[_northAgent]);
    expect(container.read(selectedModelProvider)?.id, _northAgent);
  });

  test(
    'a terminal list that cannot be read never changes the agent picked',
    () async {
      final api = _AgentsApi();
      final container = _agentContainer(api);
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      await models.select(_northAgent, chatId: 'agent-chat');
      _terminalsUnreadable = true;
      container.invalidate(terminalAvailableServersProvider);
      final list = await models.list(
        const ModelListQuery(chatId: 'agent-chat'),
      );
      expect(list.agents.map((m) => m.id), <String>[_northAgent]);
      expect(list.selectedId, _northAgent);
      expect(container.read(selectedModelProvider)?.id, _northAgent);
    },
  );
  test(
    "a terminal's agents are not offered once another terminal is chosen",
    () {
      fakeAsync((time) {
        final api = _AgentsApi()..held = Completer<void>();
        final container = _agentContainer(api);
        container.read(selectedTerminalIdProvider.notifier).set('north');
        final listing = _Outcome(
          ModelsService(container)
              .list(const ModelListQuery(chatId: 'agent-chat')),
        );
        time.elapse(Duration.zero);
        expect(api.northAsked.isCompleted, isTrue);
        container.read(selectedTerminalIdProvider.notifier).set('south');
        api.held!.complete();
        time.elapse(Duration.zero);
        final list = listing.value! as ModelList;
        expect(list.agents, isEmpty, reason: "north's agents offered on south");
      });
    },
  );
  test("a terminal's agents are not offered once another terminal is chosen "
      'while the model in use is still being worked out', () {
    fakeAsync((time) {
      final api = _AgentsApi();
      final container = _agentContainer(api);
      container.read(selectedTerminalIdProvider.notifier).set('north');
      // Nothing is selected: the list waits for the account's default.
      container.read(selectedModelProvider.notifier).clear();
      _defaultHeld = Completer<void>();
      final listing = _Outcome(
        ModelsService(container)
            .list(const ModelListQuery(chatId: 'agent-chat')),
      );
      time.elapse(Duration.zero);
      expect(api.asked, contains('north'));
      container.read(selectedTerminalIdProvider.notifier).set('south');
      _defaultHeld!.complete();
      time.elapse(Duration.zero);
      final list = listing.value! as ModelList;
      expect(list.agents, isEmpty, reason: "north's agents offered on south");
    });
  });

  test('a slower pick never replaces a later one', () {
    fakeAsync((time) {
      final api = _AgentsApi()..held = Completer<void>();
      final container = _agentContainer(api);
      final models = ModelsService(container);
      // Switch to the chat's agent, asked of north, which is slow (its
      // lookup's own timeout never runs out: the clock does not move).
      final first = _Outcome(models.select(_northAgent, chatId: 'agent-chat'));
      time.elapse(Duration.zero);
      expect(api.northAsked.isCompleted, isTrue);
      final later = _Outcome(
        models.select('preferred-model', chatId: 'plain-chat'),
      );
      time.elapse(Duration.zero);
      expect(later.value, isNotNull, reason: 'the later pick did not land');
      api.held!.complete();
      time.elapse(Duration.zero);
      expect(first.refusal, ConduitErrorCodes.conflict);
      expect(container.read(selectedModelProvider)?.id, 'preferred-model');
      expect(container.read(selectedTerminalIdProvider), 'south');
    });
  });

  group("each chat's own pick, kept by the daemon", () {
    test(
      "is the chat's selection whatever the account picks elsewhere",
      () async {
        final container = _agentContainer(_AgentsApi());
        container.read(selectedTerminalIdProvider.notifier).set('north');
        final models = ModelsService(container);
        await models.select(_northAgent, chatId: 'agent-chat');
        await models.select('preferred-model', chatId: 'plain-chat');
        final a = await models.list(const ModelListQuery(chatId: 'agent-chat'));
        expect(a.selectedId, _northAgent);
        final b = await models.list(const ModelListQuery(chatId: 'plain-chat'));
        expect(b.selectedId, 'preferred-model');
      },
    );

    test("moves with the chat's id", () async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final bus = EventBus();
      final models = ModelsService(container, events: bus);
      await models.select(_northAgent, chatId: 'agent-chat');
      bus.emit(
        ConduitEventSpecs.routeRemap,
        const RouteRemap(fromId: 'agent-chat', toId: 'agent-chat-9'),
      );
      final moved = await models.list(
        const ModelListQuery(chatId: 'agent-chat-9'),
      );
      expect(moved.selectedId, _northAgent);
    });

    test("lands on the chat's new id when it moves while the pick is out", () {
      fakeAsync((time) {
        final api = _AgentsApi()..held = Completer<void>();
        final container = _agentContainer(api);
        container.read(selectedTerminalIdProvider.notifier).set('north');
        final bus = EventBus();
        final models = ModelsService(container, events: bus);
        final picking = _Outcome(
          models.select(_northAgent, chatId: 'agent-chat'),
        );
        time.elapse(Duration.zero);
        expect(api.northAsked.isCompleted, isTrue);
        bus.emit(
          ConduitEventSpecs.routeRemap,
          const RouteRemap(fromId: 'agent-chat', toId: 'agent-chat-9'),
        );
        api.held!.complete();
        time.elapse(Duration.zero);
        expect((picking.value! as ModelList).selectedId, _northAgent);
        final moved = _Outcome(
          models.list(const ModelListQuery(chatId: 'agent-chat-9')),
        );
        time.elapse(Duration.zero);
        expect((moved.value! as ModelList).selectedId, _northAgent);
      });
    });

    test(
      "answers a chat's agent controls as that chat's agent offers them",
      () async {
        final container = _agentContainer(
          _AgentsApi(),
          extra: [modelControlChoicesProvider.overrideWith(_NoChoices.new)],
        );
        final models = ModelsService(container);
        Future<List<String>> efforts() async {
          final list = await models.controls(
            const ModelControlsQuery(
              modelId: _northAgent,
              chatId: 'agent-chat',
            ),
          );
          check(list.modelId).equals(_northAgent);
          return [
            for (final control in list.controls)
              for (final option in control.options) option.value,
          ];
        }

        // No pick: asked of the agent's own terminal, not the one selected.
        await models.select(_southAgent, chatId: 'plain-chat');
        check(await efforts()).deepEquals(_chatEfforts);
        // A pick a first send made by the agent's id alone: asked the same way.
        models.sent(
          await models.sending(null),
          toChat: 'agent-chat',
          model: _northAgent,
        );
        check(await efforts()).deepEquals(_chatEfforts);
        // The chat's own pick, though a new chat picked the same agent since,
        // where it offers more.
        container.read(selectedTerminalIdProvider.notifier).set('north');
        await models.select(_northAgent, chatId: 'agent-chat');
        await models.select(_northAgent);
        check(await efforts()).deepEquals(_chatEfforts);
        // New Chat's pick, taken to the chat its first send made: the agent as
        // that chat's terminal offers it, not as New Chat's did.
        models.sent(
          await models.sending(null),
          toChat: 'agent-chat',
          model: _northAgent,
        );
        check(await efforts()).deepEquals(_chatEfforts);
      },
    );

    test("New Chat's coding agent goes when its terminal does; a chat's own "
        'stays', () async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      await models.select(_northAgent, chatId: 'agent-chat');
      await models.select(_northAgent);
      check((await models.list()).selectedId).equals(_northAgent);
      // Terminals turned off: New Chat runs no agent, as the account's own
      // selection does not.
      container.read(selectedTerminalIdProvider.notifier).set(null);
      check((await models.list()).selectedId).equals('first-model');
      check(await models.modelFor(null)).equals('first-model');
      // The chat's own agent runs on its own terminal, whichever is chosen.
      check(
        (await models.list(const ModelListQuery(chatId: 'agent-chat')))
            .selectedId,
      ).equals(_northAgent);
    });

    test("New Chat's coding agent goes once the server confirms its terminal "
        'is gone, and stays while that is unread', () async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      await models.select(_northAgent);
      Future<void> listAgain() async {
        container.invalidate(terminalAvailableServersProvider);
        await container
            .read(terminalAvailableServersProvider.future)
            .then((_) {}, onError: (_) {});
      }

      // A list that cannot be read proves nothing.
      _terminalsUnreadable = true;
      await listAgain();
      check((await models.list()).selectedId).equals(_northAgent);
      // Read without north while the server's own list is unread (the
      // combined list leaves them out then): nothing either.
      _terminalsUnreadable = false;
      _offered = [_terminals.last];
      _systemUnreadable = true;
      await listAgain();
      check((await models.list()).selectedId).equals(_northAgent);
      check(await models.modelFor(null)).equals(_northAgent);
      // The server confirms north is gone, though it is still selected: a
      // turn sent from New Chat runs no agent, and leaves none to its chat.
      _systemUnreadable = false;
      check(container.read(selectedTerminalIdProvider)).equals('north');
      final sending = await models.sending(null);
      final model = await models.modelFor(null);
      check(model).equals('first-model');
      models.sent(sending, toChat: 'new-chat-1', model: model);
      check(
        (await models.list(const ModelListQuery(chatId: 'new-chat-1')))
            .selectedId,
      ).equals('first-model');
      check((await models.list()).selectedId).equals('first-model');
    });

    /// New Chat's agent picked on north, north gone from the list, and the
    /// server's own read of its terminals that [read] starts held (that one
    /// alone) until [meanwhile] has run.
    Future<T> readWhile<T>(
      Future<T> Function(ModelsService models) read,
      Future<void> Function(ModelsService models, ProviderContainer container)
      meanwhile,
    ) async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      await models.select(_northAgent);
      _offered = [_terminals.last];
      container.invalidate(terminalAvailableServersProvider);
      await container.read(terminalAvailableServersProvider.future);
      final held = _systemHeld = Completer<void>();
      final reading = read(models);
      await _systemAsked.future;
      _systemHeld = null;
      await meanwhile(models, container);
      held.complete();
      return reading;
    }

    test("New Chat's coding agent goes when another terminal is chosen while "
        'the server is read, though the server still offers its own', () async {
      final model = await readWhile((models) => models.modelFor(null), (
        _,
        container,
      ) async {
        container.read(selectedTerminalIdProvider.notifier).set('south');
        _offered = _terminals;
      });
      check(model).equals('first-model');
    });

    test('a turn from New Chat carries no agent found gone while another pick '
        'took its place', () async {
      late ModelsService service;
      final send = await readWhile((models) {
        service = models;
        return models.sending(null);
      }, (models, _) => models.select('preferred-model'));
      service.sent(send, toChat: 'new-chat-1', model: 'preferred-model');
      // The chat runs with the model the turn did, not north's agent.
      check(
        (await service.list(const ModelListQuery(chatId: 'new-chat-1')))
            .selectedId,
      ).equals('preferred-model');
      check((await service.list()).selectedId).equals('preferred-model');
    });

    test("New Chat's coding agent is checked as it is read: another account's "
        'terminal reset leaves it no terminal', () async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      await models.select(_northAgent);
      // The next account takes over, with no terminal selected, and hands
      // back: none is selected for New Chat's agent now.
      _switchTo(
        container,
        const PrimaryAccountRef(PrimaryAccountKind.libreChat, 'lc-one'),
      );
      container.read(selectedTerminalIdProvider.notifier).set(null);
      _switchTo(container, _home);
      check((await models.list()).selectedId).equals('first-model');
      check(await models.modelFor(null)).equals('first-model');
    });

    /// New Chat's agent picked under the home account, its terminal gone
    /// from the list; [read] starts, and another signed-in Open WebUI
    /// account takes over while the server's own read of its terminals,
    /// which confirms that, waits.
    Future<Object?> readWhileAnotherTakesOver(
      Future<Object?> Function(ModelsService models) read,
    ) async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      await models.select(_northAgent);
      _offered = [_terminals.last];
      container.invalidate(terminalAvailableServersProvider);
      await container.read(terminalAvailableServersProvider.future);
      _systemHeld = Completer<void>();
      final reading = read(models);
      await _systemAsked.future;
      _session = Object();
      _switchTo(
        container,
        const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'away'),
      );
      _systemHeld!.complete();
      return reading;
    }

    test("New Chat's coding agent is not the model a turn runs with for an "
        'account that takes over while its terminal is checked', () async {
      await expectLater(
        readWhileAnotherTakesOver((models) => models.modelFor(null)),
        refused(ConduitErrorCodes.sessionExpired),
      );
    });

    test("New Chat's coding agent's controls are not answered for an account "
        'that takes over while its terminal is checked', () async {
      await expectLater(
        readWhileAnotherTakesOver(
          (models) =>
              models.controls(const ModelControlsQuery(modelId: _northAgent)),
        ),
        refused(ConduitErrorCodes.sessionExpired),
      );
    });

    test("New Chat's list for an account that takes over while its terminal "
        "is checked is that account's, without the last one's agent", () async {
      final list = await readWhileAnotherTakesOver(
        (models) => models.list(),
      ) as ModelList;
      check(list.selectedId).equals('first-model');
    });

    test("a turn from New Chat that names a model carries no agent whose "
        'terminal went to the chat it makes', () async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      await models.select(_northAgent);
      // The terminal is turned off, and the first message names a model of
      // its own: nothing reads New Chat's pick before it is sent.
      container.read(selectedTerminalIdProvider.notifier).set(null);
      final sending = await models.sending(null);
      models.sent(sending, toChat: 'new-chat-1', model: 'preferred-model');
      final made = await models.list(
        const ModelListQuery(chatId: 'new-chat-1'),
      );
      expect(made.selectedId, isNot(_northAgent));
    });

    test("goes from New Chat to the chat its first message makes", () async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      await models.select(_northAgent);
      // The first message went to another model for itself alone (`@`).
      models.sent(
        await models.sending(null),
        toChat: 'new-chat-1',
        model: 'preferred-model',
      );
      final made = await models.list(
        const ModelListQuery(chatId: 'new-chat-1'),
      );
      expect(made.selectedId, _northAgent);
      final next = await models.list();
      expect(next.selectedId, isNot(_northAgent));
    });

    // A temporary chat's composer and a saved New Chat both have no chat
    // yet: the temporary one's pick, its list and its first turn are its
    // own, and never offer, take or clear New Chat's coding agent.
    test("a temporary chat keeps out of New Chat's pick", () async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      await models.select(_northAgent);
      final picked = await models.select('preferred-model', temporary: true);
      check(picked.selectedId).equals('preferred-model');
      check(picked.agents).isEmpty();
      await check(
        models.select(_northAgent, temporary: true),
      ).throws<RpcError>();
      check((await models.list()).selectedId).equals(_northAgent);

      final sending = await models.sending(null, temporary: true);
      final model = await models.modelFor(null, temporary: true);
      check(model).equals('preferred-model');
      models.sent(sending, toChat: 'temporary-chat', model: model);
      check((await models.list()).selectedId).equals(_northAgent);
      check(
        (await models.list(const ModelListQuery(chatId: 'temporary-chat')))
            .selectedId,
      ).equals('preferred-model');
      // New Chat's own first send still takes its agent.
      check(await models.modelFor(null)).equals(_northAgent);

      // With nothing picked in New Chat, a temporary pick is no account
      // selection New Chat would fall back on: it keeps the default.
      final fresh = ModelsService(_agentContainer(_AgentsApi()));
      await fresh.select('preferred-model', temporary: true);
      check(await fresh.modelFor(null)).equals('first-model');
      check((await fresh.list()).selectedId).equals('first-model');
      check(await fresh.modelFor(null, temporary: true))
          .equals('preferred-model');
    });

    test("a send that lands after a later pick leaves the chat that pick", () {
      fakeAsync((time) {
        final container = _agentContainer(_AgentsApi());
        container.read(selectedTerminalIdProvider.notifier).set('north');
        final models = ModelsService(container);
        // Chat C runs agent A; a send with A waits to be admitted while B
        // is picked for C.
        models.select(_northAgent, chatId: 'agent-chat');
        time.elapse(Duration.zero);
        final sending = _sendingIn(time, models, 'agent-chat');
        models.select('preferred-model', chatId: 'agent-chat');
        time.elapse(Duration.zero);
        models.sent(sending, toChat: 'agent-chat', model: _northAgent);
        final listed = _Outcome(
          models.list(const ModelListQuery(chatId: 'agent-chat')),
        );
        time.elapse(Duration.zero);
        check((listed.value! as ModelList).selectedId)
            .equals('preferred-model');
      });
    });

    test("a regular model picked in New Chat stays the created chat's", () {
      fakeAsync((time) {
        final container = _agentContainer(_AgentsApi());
        final models = ModelsService(container);
        models.select('preferred-model');
        time.elapse(Duration.zero);
        final sending = _sendingIn(time, models, null);
        models.sent(sending, toChat: 'new-chat-1', model: 'preferred-model');
        // Another chat's pick is the account's selection now.
        models.select('first-model', chatId: 'plain-chat');
        time.elapse(Duration.zero);
        check(container.read(selectedModelProvider)?.id).equals('first-model');
        final made = _Outcome(
          models.list(const ModelListQuery(chatId: 'new-chat-1')),
        );
        time.elapse(Duration.zero);
        check((made.value! as ModelList).selectedId).equals('preferred-model');
      });
    });

    test("a New Chat pick made while a send waits stays New Chat's", () {
      fakeAsync((time) {
        final container = _agentContainer(_AgentsApi());
        final models = ModelsService(container);
        models.select('preferred-model');
        time.elapse(Duration.zero);
        final sending = _sendingIn(time, models, null);
        models.select('first-model');
        time.elapse(Duration.zero);
        models.sent(sending, toChat: 'new-chat-1', model: 'preferred-model');
        final made = _Outcome(
          models.list(const ModelListQuery(chatId: 'new-chat-1')),
        );
        final next = _Outcome(models.list());
        final nextModel = _Outcome(models.modelFor(null));
        time.elapse(Duration.zero);
        check((made.value! as ModelList).selectedId).equals('preferred-model');
        check((next.value! as ModelList).selectedId).equals('first-model');
        check(nextModel.value).equals('first-model');
      });
    });

    test("a send that lands under another account moves no pick", () {
      fakeAsync((time) {
        final container = _agentContainer(_AgentsApi());
        final models = ModelsService(container);
        models.select('preferred-model');
        time.elapse(Duration.zero);
        final sending = _sendingIn(time, models, null);
        // Another chat's pick is the account's selection now.
        models.select('first-model', chatId: 'plain-chat');
        time.elapse(Duration.zero);
        _switchTo(
          container,
          const PrimaryAccountRef(PrimaryAccountKind.libreChat, 'lc-one'),
        );
        models.sent(sending, toChat: 'new-chat-1', model: 'preferred-model');
        _switchTo(container, _home);
        final slot = _Outcome(models.list());
        final made = _Outcome(
          models.list(const ModelListQuery(chatId: 'new-chat-1')),
        );
        time.elapse(Duration.zero);
        check((slot.value! as ModelList).selectedId).equals('preferred-model');
        check((made.value! as ModelList).selectedId).equals('first-model');
      });
    });

    test("a turn naming no model is refused when only another chat's agent "
        'is left', () {
      fakeAsync((time) {
        final container = _agentContainer(
          _AgentsApi(),
          models: () => _These(const []),
        );
        container.read(selectedTerminalIdProvider.notifier).set('north');
        final models = ModelsService(container);
        models.select(_northAgent, chatId: 'agent-chat');
        time.elapse(Duration.zero);
        check(container.read(selectedModelProvider)?.id).equals(_northAgent);
        final unnamed = _Outcome(models.modelFor('plain-chat'));
        time.elapse(Duration.zero);
        check(unnamed.value).isNull();
        check(unnamed.refusal).equals(ConduitErrorCodes.unsupported);
      });
    });

    test(
      'a server model whose id only looks like an agent is a regular one',
      () {
        fakeAsync((time) {
          const research = core.Model(id: 'agent:research', name: 'Research');
          final container = _agentContainer(
            _AgentsApi(),
            models: () => _These(const [research]),
          );
          final models = ModelsService(container);
          final picked = _Outcome(
            models.select('agent:research', chatId: 'plain-chat'),
          );
          final unnamed = _Outcome(models.modelFor('plain-chat'));
          time.elapse(Duration.zero);
          final list = picked.value! as ModelList;
          check(list.selectedId).equals('agent:research');
          check(list.models.map((m) => m.id)).contains('agent:research');
          check(list.models.single.agent).isNull();
          check(list.agents.map((m) => m.id))
              .not((it) => it.contains('agent:research'));
          check(container.read(selectedModelProvider)?.id)
              .equals('agent:research');
          check(unnamed.value).equals('agent:research');
          // A well-formed coding agent's id is still an agent's.
          check(terminalAgentDto(_northAgent)?.agent).equals('codex');
          check(terminalAgentDto('agent:research')).isNull();
        });
      },
    );

    test(
      "every answer carries the chat's pick revision, newer for each pick",
      () {
        fakeAsync((time) {
          final container = _agentContainer(_AgentsApi());
          final models = ModelsService(container);
          int revision(Future<ModelList> answer) {
            final outcome = _Outcome(answer);
            time.elapse(Duration.zero);
            return (outcome.value! as ModelList).revision;
          }

          const plain = ModelListQuery(chatId: 'plain-chat');
          check(revision(models.list(plain))).equals(0);
          final first = revision(
            models.select('preferred-model', chatId: 'plain-chat'),
          );
          check(first).isGreaterThan(0);
          check(revision(models.list(plain))).equals(first);
          final second = revision(
            models.select('first-model', chatId: 'plain-chat'),
          );
          check(second).isGreaterThan(first);
          check(revision(models.list(plain))).equals(second);
          // Another chat's answer has its own pick's revision (none here).
          check(
            revision(models.list(const ModelListQuery(chatId: 'agent-chat'))),
          ).equals(0);
        });
      },
    );

    test(
      'a pick that leaves or moves answers with a newer revision, never 0',
      () {
        fakeAsync((time) {
          final container = _agentContainer(_AgentsApi());
          final bus = EventBus();
          final models = ModelsService(container, events: bus);
          int revision(Future<ModelList> answer) {
            final outcome = _Outcome(answer);
            time.elapse(Duration.zero);
            return (outcome.value! as ModelList).revision;
          }

          // New Chat's pick, taken by its first send.
          final picked = revision(models.select('preferred-model'));
          final changed = <String>[];
          bus.tap((event, _, _) => changed.add(event));
          models.sent(
            _sendingIn(time, models, null),
            toChat: 'new-chat-1',
            model: 'preferred-model',
          );
          final slot = revision(models.list());
          check(slot).isGreaterThan(picked);
          // Every window showing New Chat (Quick Ask too) is told to list
          // it again.
          check(changed).contains(ConduitEvents.modelsChanged);
          final made = revision(
            models.list(const ModelListQuery(chatId: 'new-chat-1')),
          );
          check(made).isGreaterThan(picked);
          // A chat's pick moving with its id.
          bus.emit(
            ConduitEventSpecs.routeRemap,
            const RouteRemap(fromId: 'new-chat-1', toId: 'chat-9'),
          );
          check(revision(models.list(const ModelListQuery(chatId: 'chat-9'))))
              .isGreaterThan(made);
        });
      },
    );

    test("one LibreChat account's picks are never another's", () {
      fakeAsync((time) {
        final container = _agentContainer(_AgentsApi());
        final models = ModelsService(container);
        _switchTo(
          container,
          const PrimaryAccountRef(PrimaryAccountKind.libreChat, 'lc-one'),
        );
        models.select('preferred-model', chatId: 'plain-chat');
        time.elapse(Duration.zero);
        models.select('first-model', chatId: 'agent-chat');
        time.elapse(Duration.zero);
        _switchTo(
          container,
          const PrimaryAccountRef(PrimaryAccountKind.libreChat, 'lc-two'),
        );
        final listed = _Outcome(
          models.list(const ModelListQuery(chatId: 'plain-chat')),
        );
        time.elapse(Duration.zero);
        check((listed.value! as ModelList).selectedId).equals('first-model');
      });
    });

    test("a pin's reply never looks the chat up for the next account", () {
      fakeAsync((time) {
        final pins = _HeldPins()..held = Completer<void>();
        final container = _agentContainer(
          _AgentsApi(),
          extra: [
            personalizationSettingsProvider.overrideWith(() => pins),
            canTogglePinnedModelsProvider.overrideWithValue(true),
            effectivePinnedModelIdsProvider.overrideWithValue(const <String>[]),
          ],
        );
        final models = ModelsService(container);
        final pinning = _Outcome(
          models.setPinned(
            const SetModelPinned(
              id: 'preferred-model',
              pinned: true,
              chatId: 'plain-chat',
            ),
          ),
        );
        time.elapse(Duration.zero);
        check(pins.toggleAsked.isCompleted).isTrue();
        _session = Object();
        container.invalidate(openWebUiAuthSessionEpochProvider);
        pins.held!.complete();
        time.elapse(Duration.zero);
        check(pinning.refusal).equals(ConduitErrorCodes.sessionExpired);
        check(_chatReads).not((it) => it.contains('plain-chat'));
      });
    });

    test("a turn naming no model in one chat never goes to another chat's "
        'agent', () async {
      final container = _agentContainer(_AgentsApi());
      container.read(selectedTerminalIdProvider.notifier).set('north');
      final models = ModelsService(container);
      // Chat A's agent is the account's selection now.
      await models.select(_northAgent, chatId: 'agent-chat');
      expect(container.read(selectedModelProvider)?.id, _northAgent);
      expect(await models.modelFor('plain-chat'), 'first-model');
      expect(await models.modelFor('agent-chat'), _northAgent);
    });

    test("keeps a saved agent chat's Switch offer through a pin", () async {
      final container = _agentContainer(
        _AgentsApi(),
        extra: [
          personalizationSettingsProvider.overrideWith(_HeldPins.new),
          canTogglePinnedModelsProvider.overrideWithValue(true),
          effectivePinnedModelIdsProvider.overrideWithValue(const <String>[
            'first-model',
          ]),
        ],
      );
      final models = ModelsService(container);
      final pinned = await models.setPinned(
        const SetModelPinned(
          id: 'first-model',
          pinned: false,
          chatId: 'agent-chat',
        ),
      );
      expect(pinned.chatAgent, _northAgent);
    });

    test("a new chat's pick is never answered for the next account", () {
      fakeAsync((time) {
        final api = _AgentsApi()..held = Completer<void>();
        final container = _agentContainer(api);
        container.read(selectedTerminalIdProvider.notifier).set('north');
        final picking = _Outcome(
          ModelsService(container).select('preferred-model'),
        );
        time.elapse(Duration.zero);
        expect(api.northAsked.isCompleted, isTrue);
        _session = Object();
        container.invalidate(openWebUiAuthSessionEpochProvider);
        api.held!.complete();
        time.elapse(Duration.zero);
        expect(picking.refusal, ConduitErrorCodes.sessionExpired);
      });
    });
  });

  test('another terminal or a pick announces another list, once', () async {
    final container = _agentContainer(_AgentsApi());
    final bus = EventBus();
    final changed = <String>[];
    bus.tap((event, _, _) => changed.add(event));
    final models = ModelsService(container, events: bus);
    container.read(selectedTerminalIdProvider.notifier).set('north');
    check(changed).deepEquals([ConduitEventSpecs.modelsChanged.name]);
    check(container.read(selectedModelProvider)?.id).equals('first-model');
    // A chat's pick the account had selected already: the chat's other
    // windows still list it again.
    changed.clear();
    await models.select('first-model', chatId: 'plain-chat');
    check(changed).deepEquals([ConduitEventSpecs.modelsChanged.name]);
    changed.clear();
    await models.select('preferred-model', chatId: 'plain-chat');
    check(changed).deepEquals([ConduitEventSpecs.modelsChanged.name]);
    // A chat's own agent on another terminal: the terminal and the model
    // both change, and the pick still announces once.
    container.read(selectedTerminalIdProvider.notifier).set('south');
    changed.clear();
    await models.select(_northAgent, chatId: 'agent-chat');
    check(container.read(selectedTerminalIdProvider)).equals('north');
    check(changed).deepEquals([ConduitEventSpecs.modelsChanged.name]);
  });
  test('an unreachable server leaves the cached models on offer', () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_Unreachable.new)],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});
    await container.read(modelsProvider.future);
    (container.read(modelsProvider.notifier) as _Unreachable).refreshFailed();
    expect(container.read(modelsProvider).hasError, isTrue);

    final list = await ModelsService(container).list();

    expect(list.models.map((model) => model.id), [_cached.id]);
  });

  test("a model one of the user's devices offers says which device", () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_OnDevices.new)],
    );
    addTearDown(container.dispose);

    final list = await ModelsService(container).list();

    expect(
      {for (final model in list.models) model.id: model.device},
      <String, String?>{
        'qwen3:8b': 'Studio Mac · Garage lab',
        'first-model': null,
      },
    );
  });

  test('with nothing chosen, the account default is the selection', () async {
    const first = core.Model(id: 'first-model', name: 'First model');
    const preferred = core.Model(id: 'preferred-model', name: 'Preferred');
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        // The user's settings name a model that the server lists last.
        defaultModelProvider.overrideWith((ref) async => preferred),
      ],
    );
    addTearDown(container.dispose);

    final list = await ModelsService(container).list();

    expect(list.models.first.id, first.id);
    expect(list.selectedId, preferred.id);
    expect((await currentModel(container))?.id, preferred.id);

    // A model picked in the window wins over the default.
    final picked = await ModelsService(container).select(first.id);
    expect(picked.selectedId, first.id);
  });

  test('a default that cannot resolve leaves nothing chosen', () async {
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        defaultModelProvider.overrideWith(
          (ref) async => throw StateError('settings unavailable'),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    final list = await ModelsService(container).list();

    expect(list.models, hasLength(2));
    expect(list.selectedId, isNull);
  });

  test(
    'a reasoning pick asked under one account is not made under the next',
    () async {
      var account = Object();
      final listed = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          modelsProvider.overrideWith(() => _Held(listed.future)),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        ],
        retry: (_, _) => null,
      );
      addTearDown(container.dispose);
      final picking = ModelsService(container).setReasoningEffort(
        const SetReasoningEffort(modelId: 'first-model', effort: 'high'),
      );
      // Another account signs in while the model is looked up.
      account = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      listed.complete();
      await expectLater(picking, refused(ConduitErrorCodes.sessionExpired));
    },
  );

  test('a pick for a chat that cannot be read is refused', () async {
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        loadConversationProvider.overrideWith(
          (ref, id) async => throw StateError('no chat $id here'),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    await expectLater(
      ModelsService(container).setReasoningEffort(
        const SetReasoningEffort(
          modelId: 'first-model',
          effort: 'high',
          chatId: 'gone',
        ),
      ),
      refused(ConduitErrorCodes.notFound),
    );
  });

  // `turns.send` with a new chat's settings, as `chatSettings.save` would
  // write them: only what the account may change.
  test("a new chat's settings keep to the account's rights", () async {
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        openWebUiChatSettingsAccessProvider.overrideWith(
          (ref) async => const OpenWebUiChatSettingsAccess(
            canEditSystemPrompt: false,
            canEditParameters: true,
          ),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);
    await expectLater(
      turns.send(
        const SendTurn(
          model: 'first-model',
          text: 'Hello',
          chatParams: <String, dynamic>{'system': 'Answer in riddles.'},
        ),
      ),
      refused(ConduitErrorCodes.unauthorized),
    );
  });

  // A server's own connection is still the server's chat: its settings
  // keep to the account's rights as any Open WebUI chat's do.
  test(
    "a new chat on a server connection's model keeps to the rights",
    () async {
      final registry = DirectModelRegistry();
      final served = registry
          .replaceProfileModels(
            DirectConnectionProfile(
              id: 'server-connection',
              name: 'Server connection',
              adapterKey: kOpenAiCompatibleAdapterKey,
              baseUrl: 'https://models.invalid/v1',
            ),
            [DirectRemoteModel(id: 'served-model')],
            source: DirectModelSource.openWebUi,
            openWebUiUrlIndex: 0,
          )
          .single;
      final container = ProviderContainer(
        overrides: [
          directModelRegistryProvider.overrideWithValue(registry),
          modelsProvider.overrideWith(() => _These(<core.Model>[served])),
          openWebUiChatSettingsAccessProvider.overrideWith(
            (ref) async => const OpenWebUiChatSettingsAccess(
              canEditSystemPrompt: false,
              canEditParameters: true,
            ),
          ),
        ],
        retry: (_, _) => null,
      );
      addTearDown(container.dispose);
      final turns = TurnsService(container, EventBus());
      addTearDown(turns.dispose);
      await expectLater(
        turns.send(
          SendTurn(
            model: served.id,
            text: 'Hello',
            chatParams: const <String, dynamic>{'system': 'Answer in riddles.'},
          ),
        ),
        refused(ConduitErrorCodes.unauthorized),
      );
    },
  );

  test("a new chat's settings checked for one account are never sent under "
      'the next', () async {
    var account = Object();
    final rights = Completer<OpenWebUiChatSettingsAccess>();
    final asked = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        openWebUiChatSettingsAccessProvider.overrideWith((ref) {
          if (!asked.isCompleted) asked.complete();
          return rights.future;
        }),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    container.read(openWebUiAuthSessionEpochProvider);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);
    final sending = turns.send(
      const SendTurn(
        model: 'first-model',
        text: 'Hello',
        chatParams: <String, dynamic>{'system': 'Answer in riddles.'},
      ),
    );
    // Another account signs in while the rights are read.
    await asked.future;
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    container.read(openWebUiAuthSessionEpochProvider);
    rights.complete(
      const OpenWebUiChatSettingsAccess(
        canEditSystemPrompt: true,
        canEditParameters: true,
      ),
    );
    await expectLater(sending, refused(ConduitErrorCodes.sessionExpired));
  });

  test("a list started under one account never offers its models to the "
      'next', () async {
    final first = Object();
    var account = first;
    final listed = Completer<void>();
    final loaded = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(() => _PerAccount(first, listed.future)),
        apiServiceProvider.overrideWithValue(
          ApiService(
            serverConfig: const ServerConfig(
              id: 'server',
              name: 'Home server',
              url: 'https://home.invalid',
            ),
            workerManager: WorkerManager(),
          ),
        ),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        personalizationSettingsProvider.overrideWith(
          () => _Personal(loaded.future),
        ),
        effectivePinnedModelIdsProvider.overrideWithValue(const <String>[]),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    container.listen(personalizationSettingsProvider, (_, _) {});
    final listing = ModelsService(container).list();
    listed.complete();
    // A's models are in; another account signs in while the account's
    // settings load.
    await container.read(modelsProvider.future);
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    loaded.complete();
    final list = await listing;
    expect(list.models.map((m) => m.id), <String>['b-model']);
  });

  test(
    'a pin asked for under one account is not made under the next',
    () async {
      var account = Object();
      final loaded = Completer<void>();
      final settings = _Personal(loaded.future);
      final container = ProviderContainer(
        overrides: [
          modelsProvider.overrideWith(_Listed.new),
          apiServiceProvider.overrideWithValue(
            ApiService(
              serverConfig: const ServerConfig(
                id: 'server',
                name: 'Home server',
                url: 'https://home.invalid',
              ),
              workerManager: WorkerManager(),
            ),
          ),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
          personalizationSettingsProvider.overrideWith(() => settings),
          effectivePinnedModelIdsProvider.overrideWithValue(const <String>[]),
          canTogglePinnedModelsProvider.overrideWithValue(true),
        ],
        retry: (_, _) => null,
      );
      addTearDown(container.dispose);
      container.listen(personalizationSettingsProvider, (_, _) {});
      final pinning = ModelsService(container)
          .setPinned(const SetModelPinned(id: 'first-model', pinned: true));
      // Another account signs in while the account's settings load.
      account = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      loaded.complete();
      await expectLater(pinning, refused(ConduitErrorCodes.sessionExpired));
      expect(settings.toggled, isEmpty);
    },
  );

  test(
    'a Fast tier switch asked under one account is not made under the next',
    () async {
      var account = Object();
      final container = ProviderContainer(
        overrides: [
          modelsProvider.overrideWith(_FastGated.new),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        ],
        retry: (_, _) => null,
      );
      addTearDown(container.dispose);
      final models = ModelsService(container);
      await models.select('fast-a');
      // The models are read again, slowly, while the switch is asked.
      _FastGated.gate = Completer<void>();
      addTearDown(() => _FastGated.gate = null);
      container.invalidate(modelsProvider);
      final switching = models.setFastTier(
        const SetFastTier(modelId: 'fast-a', on: true),
      );
      account = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      _FastGated.gate!.complete();
      await expectLater(switching, refused(ConduitErrorCodes.sessionExpired));
      expect(container.read(hermesFastTierSelectionProvider), isFalse);
    },
  );

  test("another model's Fast tier request changes nothing", () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_Fast.new)],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final models = ModelsService(container);
    await models.select('fast-a');

    await expectLater(
      models.setFastTier(const SetFastTier(modelId: 'fast-b', on: true)),
      refused(ConduitErrorCodes.invalidParams),
    );
    await expectLater(
      models.setFastTier(const SetFastTier(modelId: 'unknown', on: true)),
      refused(ConduitErrorCodes.invalidParams),
    );
    expect(container.read(hermesFastTierSelectionProvider), isFalse);
  });

  test("a model whose metadata names no terminal in words is listed", () async {
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(
          () => _These(const <core.Model>[
            core.Model(
              id: 'odd-model',
              name: 'Odd model',
              metadata: <String, dynamic>{'terminalName': 7},
            ),
          ]),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final list = await ModelsService(container).list();
    expect(list.models.map((m) => m.id), <String>['odd-model']);
  });

  test('a coding agent on Open WebUI 0.13.4 goes by its own model, not the '
      'slug in its id', () async {
    const id = 'agent:north:codex:gpt-5-1-e7ee8b01';
    final agent = terminalAgentModelFromJson(<String, dynamic>{
      'id': id,
      'name': 'codex/gpt-5.1',
      'owned_by': 'terminal',
      'agent': <String, dynamic>{
        'terminal_id': 'north',
        'provider': 'codex',
        'model': 'gpt-5.1',
      },
    }, terminalName: 'North bench')!;
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(() => _These([agent])),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final list = await ModelsService(container).list();
    final listed = [...list.models, ...list.agents].single;
    expect(listed.id, id);
    expect(listed.name, 'Codex · gpt-5.1');
    expect(listed.agent?.model, 'gpt-5.1');
    expect(listed.agent?.terminalName, 'North bench');
    // Known by its id alone, it keeps the slug without the hash.
    expect(terminalAgentDto(id)?.model, 'gpt-5-1');
  });

  test('with no list at all, the failure is the answer', () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_Failing.new)],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    await expectLater(
      ModelsService(container).list(),
      throwsA(isA<SocketException>()),
    );
  });
}
