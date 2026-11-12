import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:conduit_core/conduit_core.dart';
import 'package:meta/meta.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/network/external_link.dart';
import 'package:conduit_core/network/upload_timeout.dart';

import 'package:conduit_core/features/hermes/models/hermes_background_work.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_clarify_form.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_context_usage.dart';
import 'package:conduit_core/features/hermes/models/hermes_error_surface.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';
import 'package:conduit_core/features/hermes/models/hermes_mcp.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/models/hermes_todo.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_http_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_access.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/services/hermes_history_edit.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_json_guard.dart';
import 'package:conduit_core/features/hermes/services/hermes_pending_decision_store.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart'
    show kHermesScheduledSessionSource;

part 'hermes_desktop_administration.dart';
part 'hermes_desktop_audio.dart';
part 'hermes_desktop_auth_rest.dart';
part 'hermes_desktop_bots.dart';
part 'hermes_desktop_background_work.dart';
part 'hermes_desktop_canonical.dart';
part 'hermes_desktop_context.dart';
part 'hermes_desktop_event_projection.dart';
part 'hermes_desktop_live_runtime.dart';
part 'hermes_desktop_raw_rest.dart';
part 'hermes_desktop_rooms.dart';
part 'hermes_desktop_todos.dart';
part 'hermes_desktop_turn_runtime.dart';
part 'hermes_desktop_working_directories.dart';

typedef HermesDesktopCredentialsWriter = Future<void> Function(
  HermesDesktopCredentials credentials,
);

({String? model, String? provider}) hermesDesktopSessionModelSelection(
  String? model,
  String? provider,
) {
  final rawModel = model?.trim();
  final rawProvider = provider?.trim();
  final safeModel = validateHermesOpaqueIdentifier(rawModel);
  final safeProvider = validateHermesOpaqueIdentifier(rawProvider);
  if (safeModel == null ||
      (rawProvider?.isNotEmpty == true && safeProvider == null)) {
    return (model: null, provider: null);
  }
  // The synthetic fallback means "use Hermes' configured default"; sending
  // the literal model name "default" creates the wrong per-session override.
  if (safeModel == 'default' && safeProvider == null) {
    return (model: null, provider: null);
  }
  return (model: safeModel, provider: safeProvider);
}

/// Returns models discovered from explicitly configured providers in a
/// `model.options` response.
List<Map<String, dynamic>> parseHermesDesktopConfiguredModels(
  Map<String, dynamic> result,
) {
  final models = <Map<String, dynamic>>[];
  final seen = <String>{};

  void addModel(Object? rawModel, String provider, Object? capabilities) {
    if (models.length >= 1000 || provider.isEmpty) return;
    final model = rawModel is Map
        ? (rawModel['id'] ?? rawModel['name'])?.toString().trim()
        : rawModel?.toString().trim();
    if (model == null || model.isEmpty || !seen.add('$provider\u0000$model')) {
      return;
    }
    models.add({
      'id': model,
      'name': rawModel is Map ? (rawModel['name'] ?? model).toString() : model,
      'provider': provider,
      if (capabilities is Map)
        'capabilities': Map<String, dynamic>.from(capabilities),
    });
  }

  final providers = result['providers'];
  if (providers is List) {
    for (final raw in providers.take(1000)) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      if (row['authenticated'] == false) continue;
      final provider = (row['slug'] ?? row['id'] ?? row['name'])
          ?.toString()
          .trim();
      if (provider == null || provider.isEmpty) continue;
      final providerModels = row['models'];
      if (providerModels is! List) continue;
      final capabilities = row['capabilities'];
      for (final model in providerModels) {
        final modelId = model is Map
            ? (model['id'] ?? model['name'])?.toString()
            : model?.toString();
        addModel(
          model,
          provider,
          capabilities is Map ? capabilities[modelId] : null,
        );
        if (models.length >= 1000) break;
      }
    }
  }

  return models;
}

/// Default and smallest page sizes for `GET /api/sessions/{id}/messages`.
///
/// A single 500-message page of a long tool-heavy conversation can exceed the
/// REST transport's character cap, so the pager starts smaller and shrinks
/// further whenever a page is rejected as too large.
const int kHermesDesktopTranscriptPageSize = 200;
const int kHermesDesktopTranscriptMinimumPageSize = 25;

@visibleForTesting
Future<List<Map<String, dynamic>>> loadHermesDesktopTranscriptPages(
  Future<List<Map<String, dynamic>>> Function(int offset, int limit) loadPage, {
  int maximum = 10000,
  int pageSize = kHermesDesktopTranscriptPageSize,
  int minimumPageSize = kHermesDesktopTranscriptMinimumPageSize,
  bool complete = false,
}) async {
  assert(pageSize > 0 && minimumPageSize > 0);
  final messages = <Map<String, dynamic>>[];
  var currentPageSize = pageSize;
  while (messages.length < maximum) {
    final limit = min(currentPageSize, maximum - messages.length);
    final List<Map<String, dynamic>> page;
    try {
      page = await loadPage(messages.length, limit);
    } on HermesResponseTooLargeException {
      if (limit <= minimumPageSize) rethrow;
      currentPageSize = max(minimumPageSize, limit ~/ 2);
      DebugLogger.warning(
        'transcript-page-too-large',
        scope: 'hermes/desktop',
        data: {
          'offset': messages.length,
          'limit': limit,
          'retryLimit': currentPageSize,
        },
      );
      continue;
    }
    messages.addAll(page.take(limit));
    if (page.length < limit) return messages;
  }
  // A [complete] read is for changing the history (an edit's cut, an undo,
  // a branch): a row past the bound could be the very turn it targets.
  if (complete && (await loadPage(messages.length, 1)).isNotEmpty) {
    throw StateError(
      'This Hermes chat is too long to change from here: it has more than '
      '$maximum messages.',
    );
  }
  return messages;
}

@visibleForTesting
List<Map<String, dynamic>> preferLastUsableHermesTranscript(
  List<Map<String, dynamic>> previous,
  List<Map<String, dynamic>> candidate,
) => candidate.length < previous.length ? previous : candidate;

@visibleForTesting
bool hermesNativeRefreshAllowsRetry(
  HermesDesktopTokenSet? previous,
  HermesDesktopTokenSet? refreshed,
) => refreshed != null && !identical(previous, refreshed);

@visibleForTesting
bool hermesSlashNeedsCommandDispatch(HermesDesktopRpcException error) =>
    error.code == -32601 || error.code == 4018;

@visibleForTesting
String hermesExpandedAliasCommand(String target, String original) {
  final argument = original
      .replaceFirst(RegExp(r'^/+'), '')
      .split(' ')
      .skip(1)
      .join(' ')
      .trim();
  return argument.isEmpty ? target : '$target $argument';
}

@visibleForTesting
bool hermesTranscriptHasNewPrompt(Set<String> baseline, Set<String> current) =>
    current.difference(baseline).isNotEmpty;

@visibleForTesting
Uri? parseHermesOAuthUrl(Object? value) {
  final uri = parseAllowedExternalLink(value?.toString() ?? '');
  return uri != null && const {'http', 'https'}.contains(uri.scheme)
      ? uri
      : null;
}

/// Hermes Dashboard REST + Desktop Gateway implementation.
///
final class HermesDesktopApiService
    implements HermesBackendService, HermesDesktopTurnService {
  HermesDesktopApiService({
    required this.config,
    Dio? dio,
    HermesDesktopRpcClient? rpc,
    OpenExternalUrlPort? openExternalUrl,
    HermesDashboardBridgeFactory? dashboardBridgeFactory,
    this.onCredentialsChanged,
    HermesModelSwitchPrompt? confirmModelSwitch,
    @visibleForTesting
    this.gatewayStartRetryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    @visibleForTesting
    this.receiptRetryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
    ],
    @visibleForTesting
    this.pendingCompactionDeadline = const Duration(minutes: 15),
  }) : _openExternalUrl = openExternalUrl ?? const NullOpenExternalUrlPort(),
       _dashboardBridgeFactory = dashboardBridgeFactory,
       _confirmModelSwitch = confirmModelSwitch,
       _nativeTokens = config.desktopCredentials?.nativeTokens,
       _origin =
           HermesConfig.connectionOrigin(config.baseUrl) ??
           (throw const FormatException('Invalid Hermes Desktop URL.')),
       _root = _normalizeDesktopRoot(config.baseUrl),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 60),
               followRedirects: false,
               receiveDataWhenStatusError: false,
             ),
           ),
       _rpc = rpc ?? HermesDesktopRpcClient() {
    configureHermesTransport(_dio, config);
    _administration = _HermesDesktopAdministration(this);
    _rpc.setDefaultParams({'profile': config.desktopProfile});
  }

  /// Opens OAuth sign-in pages.
  ///
  /// Hermes sign-in hands the user to their browser and waits for a loopback
  /// callback. Which is a host capability, so it arrives as a port: the
  /// sidecar has no browser and refuses, and the flow reports that it could
  /// not start rather than waiting for a callback nothing will send.
  final OpenExternalUrlPort _openExternalUrl;

  /// How long to wait before each new attempt to reach a gateway that said
  /// it is not ready (starting, restarting or draining).
  final List<Duration> gatewayStartRetryDelays;

  /// How long to wait before asking again for the receipt of a turn's own
  /// prompt, after a reconnect, when Hermes could not give it.
  final List<Duration> receiptRetryDelays;

  /// How long a compaction Hermes finishes in the background is waited for:
  /// past Hermes' own wait (about ten minutes) its end may never be seen (a
  /// socket down at the time, a runtime id that changed).
  final Duration pendingCompactionDeadline;

  /// Supplies the WebView-backed dashboard bridge, when the host has one.
  final HermesDashboardBridgeFactory? _dashboardBridgeFactory;

  final String _origin;
  final Uri _root;
  @override
  final HermesConfig config;
  final Dio _dio;
  final HermesDesktopRpcClient _rpc;
  late final _HermesDesktopAdministration _administration;
  HermesDashboardBridge? _dashboardBridge;

  /// Run now triggers not yet answered, by job: on a dashboard sign-in they
  /// can still wait in the request queue, where a Stop withdraws them. A
  /// job has several when Run now was chosen again, as from another card.
  final Map<String, Set<_QueuedJobTrigger>> _jobTriggers = {};
  final HermesDesktopCredentialsWriter? onCredentialsChanged;

  /// Asks the user about a model switch Hermes holds for confirmation;
  /// without one, a held switch is refused as before.
  final HermesModelSwitchPrompt? _confirmModelSwitch;
  HermesDesktopTokenSet? _nativeTokens;
  bool _closed = false;
  final Map<String, HermesSessionBinding> _bindings = {};
  final Map<String, int> _bindingSocketGenerations = {};
  final Set<String> _freshSessionIds = {};
  final Map<String, List<Map<String, dynamic>>> _lastTranscripts = {};

  /// Chats whose next transcript may be shorter than the one shown.
  final Set<String> _shortenedTranscripts = {};
  final Map<String, String> _appliedSessionOptions = {};

  /// The model selection last applied to each session (stored id), which a
  /// chat returns to when the user keeps it over a held switch.
  final Map<String, ({String model, String? provider})> _appliedSessionModels =
      {};

  /// The `usage` of each session's last finished turn, by stored id.
  final Map<String, Map<String, dynamic>> _lastTurnUsage = {};

  /// Stored ids an explicit compaction rewrote since their chat last read
  /// them: that read may hold fewer messages (a Bot Chat's history leaves
  /// compacted rows out) and still replaces what the chat shows.
  final Set<String> _compactedTranscripts = {};

  /// Compactions still running on the server, by stored session id (a
  /// reconnect can change the runtime id), until the session reports in or
  /// [pendingCompactionDeadline] passes.
  final Map<String, _PendingCompaction> _pendingCompactions = {};

  /// Connection targets (operation/target card ids) the user approved on
  /// this device, whose authorization link this device then opens.
  final Set<String> _approvedConnectionTargets = {};

  /// Sessions owned by another profile (Bot Mode chats), keyed by stored id.
  /// Absent means the connection's configured profile owns the session.
  final Map<String, String> _sessionProfiles = {};

  /// What a session authority fences each session's edits and controls
  /// with (canonical wire only), by session id.
  final Map<String, _HermesCanonicalSession> _canonicalSessions = {};

  /// Canonical `session.create` request ids whose answer was lost, by the
  /// create's parameters: a retry of the same create names the same id, so
  /// Hermes answers it with the session the first attempt made.
  final Map<String, String> _canonicalCreateIds = {};

  /// Canonical `session.mutate` requests whose answer was lost, by session,
  /// operation and payload: a retry of the same edit is sent as it was.
  final Map<String, Map<String, Object?>> _canonicalMutations = {};
  final HermesDesktopEventBuffer _eventBuffer = HermesDesktopEventBuffer();
  final _turnStates = StreamController<HermesDesktopTurnState>.broadcast();
  final _sessionTurnStateChanges = StreamController<String>.broadcast();
  final Map<String, HermesDesktopTurnState> _sessionTurnStates = {};
  final _transcriptChanges = StreamController<String>.broadcast();

  /// The agent's task list per chat (stored id), and which chat's changed.
  final Map<String, HermesTodoState> _todoStates = {};
  final _todoChanges = StreamController<String>.broadcast();

  /// The working directory each chat (stored id) runs its tools in, and
  /// which chat's changed.
  final Map<String, String> _workingDirectories = {};
  final _workingDirectoryChanges = StreamController<String>.broadcast();

  /// Chats whose subagents or background processes may have changed.
  final _backgroundWorkHints = StreamController<String>.broadcast();
  final _desktopContractChanges = StreamController<int>.broadcast();

  Map<String, dynamic>? _status;
  Future<void>? _connecting;
  Future<HermesDesktopTokenSet?>? _refreshing;
  Future<void>? _foregroundReconciliation;
  StreamSubscription<HermesDesktopEvent>? _stateSubscription;
  bool _authoritativeRunning = true;
  bool _supportsMcpRpcLifecycle = true;
  bool _reconciliationStale = false;
  StreamSubscription<AppLifecyclePhase>? _lifecycleSubscription;
  int _desktopContract = 0;

  /// Starts reconciling the desktop transport across foreground changes.
  ///
  /// Takes the lifecycle from the host rather than `WidgetsBinding`: this
  /// runtime is meant to run in the sidecar too, where there is no widget
  /// tree to observe. A host with no lifecycle notion never emits, and the
  /// reconciliation simply never becomes necessary.
  void startLifecycleObservation(AppLifecyclePort lifecycle) {
    if (_closed || _lifecycleSubscription != null) return;
    _lifecycleSubscription = lifecycle.changes.listen(
      _runtimeDidChangeAppLifecycleState,
    );
  }

  Stream<HermesDesktopTurnState> get turnStates => _turnStates.stream;
  Stream<HermesDesktopTurnState> turnStatesFor(String storedId) =>
      Stream<HermesDesktopTurnState>.multi((controller) {
        final subscription = _sessionTurnStateChanges.stream.listen(
          (changedId) {
            final binding = _bindings[storedId];
            if (changedId == storedId ||
                changedId == binding?.storedId ||
                changedId == binding?.runtimeId) {
              controller.add(turnStateFor(storedId));
            }
          },
          onError: controller.addError,
          onDone: controller.close,
        );
        controller
          ..add(turnStateFor(storedId))
          ..onCancel = subscription.cancel;
      });

  HermesDesktopTurnState turnStateFor(String storedId) {
    if (!_authoritativeRunning) {
      return HermesDesktopTurnState.unsupportedGateway;
    }
    final binding = _bindings[storedId];
    return _sessionTurnStates[storedId] ??
        _sessionTurnStates[binding?.storedId] ??
        _sessionTurnStates[binding?.runtimeId] ??
        HermesDesktopTurnState.idle;
  }

  Stream<String> get transcriptChanges => _transcriptChanges.stream;

  /// Asks the open chat of [storedId] to read its transcript again.
  void refreshTranscript(String storedId) => _emitTranscriptChange(storedId);

  /// Asks the open chat of [storedId] to read its transcript again after a
  /// change that shortened it (an undo the chat did not see): the read is
  /// taken as it is, not refused as an incomplete one.
  void refreshShortenedTranscript(String storedId) {
    _lastTranscripts.remove(storedId);
    _shortenedTranscripts.add(storedId);
    _emitTranscriptChange(storedId);
  }

  /// Whether [storedId]'s next transcript may be shorter than the one shown
  /// ([refreshShortenedTranscript]); asking consumes it.
  bool takeShortenedTranscript(String storedId) =>
      _shortenedTranscripts.remove(storedId);

  /// The agent's task list for the chat [storedId], then every change to it
  /// (`todo.updated`, the todo tool's results, a resume's `todo_state`).
  Stream<HermesTodoState?> todoStatesFor(String storedId) =>
      _todoStatesFor(storedId);

  /// The agent's task list for the chat [storedId], when one was reported.
  HermesTodoState? todoStateFor(String storedId) => _todoStateFor(storedId);

  /// The working directory the chat [storedId] runs its tools in, then
  /// every change to it. Null until Hermes has reported one: a session's
  /// info gives it when the chat is opened or created.
  Stream<String?> workingDirectoriesFor(String storedId) =>
      _workingDirectoriesFor(storedId);
  Stream<int> get desktopContractChanges => _desktopContractChanges.stream;
  Stream<int> desktopContracts() => Stream<int>.multi((controller) {
    final subscription = _desktopContractChanges.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller
      ..add(_desktopContract)
      ..onCancel = subscription.cancel;
  });
  int get desktopContract => _desktopContract;
  bool get supportsAuthoritativeRunning => _authoritativeRunning;
  bool get supportsMcpCredentialUpdate => _supportsMcpRpcLifecycle;
  HermesDesktopRpcClient get rpc => _rpc;
  static Uri _normalizeDesktopRoot(String value) {
    final endpoint = HermesConfig.connectionEndpoint(value);
    if (endpoint == null) {
      throw const FormatException('Invalid Hermes Desktop URL.');
    }
    return Uri.parse(endpoint);
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final prefix = _root.path == '/' ? '' : _root.path;
    return _root.replace(
      path: '$prefix$path'.replaceAll(RegExp(r'//+'), '/'),
      queryParameters: query?.map(
        (key, value) => MapEntry(key, value.toString()),
      ),
    );
  }

  bool _isProfileScopedRestPath(String path) =>
      path.startsWith('/api/sessions') ||
      path.startsWith('/api/cron') ||
      path.startsWith('/api/mcp') ||
      path.startsWith('/api/audio');

  @override
  Future<bool> health() => _authHealth();
  Future<Map<String, dynamic>> statusProbe({bool refresh = false}) =>
      _authStatusProbe(refresh: refresh);
  Future<List<String>> listProfiles() => _authListProfiles();
  Future<HermesDesktopTokenSet> signInNative({String? provider}) =>
      _authSignInNative(provider: provider);

  @override
  Future<String> createSession({String? title, CancelToken? cancelToken}) =>
      _runtimeCreateSession(title: title, cancelToken: cancelToken);
  @override
  Future<String> createDesktopSession({
    String? title,
    HermesDesktopSessionOptions options = const HermesDesktopSessionOptions(),
    CancelToken? cancelToken,
  }) => _runtimeCreateDesktopSession(
    title: title,
    options: options,
    cancelToken: cancelToken,
  );
  @override
  Future<List<Map<String, dynamic>>> listSessions({
    bool excludeScheduledRuns = false,
  }) => _runtimeListSessions(excludeScheduledRuns: excludeScheduledRuns);
  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) => _runtimeGetSessionMessages(id, cancelToken: cancelToken);
  @override
  Future<List<Map<String, dynamic>>> getCurrentSessionMessages(String id) =>
      _runtimeGetSessionMessages(id, current: true);
  Future<List<HermesPendingDesktopDecision>> pendingDecisionsForSession(
    String storedId,
  ) => _runtimePendingDecisionsForSession(storedId);
  @override
  Future<void> renameSession(String id, String title) =>
      _runtimeRenameSession(id, title);
  @override
  Future<void> setSessionFlags(
    String id, {
    bool? pinned,
    bool? archived,
    bool? hidden,
  }) => _runtimeSetSessionFlags(
    id,
    pinned: pinned,
    archived: archived,
    hidden: hidden,
  );
  @override
  Future<List<Map<String, dynamic>>?> listArchivedSessions() =>
      _runtimeListArchivedSessions();
  @override
  Future<Map<String, dynamic>?> getSession(String id) => _runtimeGetSession(id);
  @override
  Future<void> deleteSession(String id, {CancelToken? cancelToken}) =>
      _runtimeDeleteSession(id, cancelToken: cancelToken);
  bool sessionIdsReferToSameBinding(String left, String right) =>
      _runtimeSessionIdsReferToSameBinding(left, right);
  @override
  Future<String> forkSession(String id) => _runtimeForkSession(id);

  /// Branches session [id] from a message: the legacy wire keeps its first
  /// [count] user and assistant rows with text, a session authority the
  /// rows through [throughRowId]. Returns the branch's stored id.
  Future<String> branchSession(String id, {int? count, int? throughRowId}) =>
      _runtimeForkSession(id, count: count, throughRowId: throughRowId);

  /// Drops session [id]'s last user turn and everything after it, on the
  /// server. False when there was no turn to drop.
  ///
  /// [rowId] is that turn's row as the caller read it: a session authority
  /// rewinds to exactly that row. The legacy wire drops whatever turn is
  /// last, and refuses while a turn runs.
  Future<bool> undoLastTurn(String id, {int? rowId}) =>
      _runtimeUndoLastTurn(id, rowId: rowId);

  /// Session [id]'s context window, token totals and plan allowances.
  Future<HermesContextReport> contextReport(String id) => _contextReport(id);

  /// Summarizes session [id]'s older messages on the server, optionally
  /// keeping [focus] in view.
  Future<HermesCompactResult> compactSession(String id, {String? focus}) =>
      _compactSession(id, focus: focus);

  /// Whether a compaction of [storedId] is still running on the server.
  bool compactionPending(String storedId) => _pendingCompactions.containsKey(
    _bindings[storedId]?.storedId ?? storedId,
  );

  /// Whether a compaction rewrote session [id]'s transcript since the chat
  /// last took it; true once, so that read may replace a longer one.
  bool takeCompactedTranscript(String id) => _compactedTranscripts.remove(id);

  /// Lets a window plan keep going on credits past its limit. False when
  /// Hermes could not turn it on.
  Future<bool> keepGoingOnCredits() => _keepGoingOnCredits();

  /// The text the gateway's speech-to-text heard in [audio]; empty when it
  /// heard none.
  Future<String> transcribeAudio(Uint8List audio, {required String mimeType}) =>
      _audioTranscribe(audio, mimeType: mimeType);

  /// [text] spoken by the gateway's text-to-speech.
  Future<({Uint8List bytes, String mimeType})> speak(String text) =>
      _audioSpeak(text);

  /// Whether this profile's voice calls run through GPT-Live.
  Future<HermesVoiceLiveStatus> voiceLiveStatus() => _voiceLiveStatus();

  /// Opens a GPT-Live call for the WebRTC offer [sdp], sent as it is.
  Future<HermesVoiceLiveSession> createVoiceLiveSession({
    required String sdp,
    List<Map<String, Object?>> history = const [],
  }) => _createVoiceLiveSession(sdp: sdp, history: history);

  /// Bot Mode roster; empty when the gateway does not support Bot Mode.
  Future<List<HermesBot>> listBots() => _listBots();

  /// A bot's avatar as a data URL, or null when it has none.
  Future<String?> botAvatar(String profile) => _botAvatar(profile);

  /// A name for this connection suggested by the gateway: the selected
  /// profile's Bot Mode title, or the profile name.
  Future<String?> suggestedDisplayName() => _suggestedDisplayName();

  /// Opens (creating when needed) a bot's canonical chat and returns its
  /// stored session id. Later calls for that session stay scoped to the bot.
  Future<String> openBotChat(HermesBot bot) => _openBotChat(bot);

  Future<List<HermesDesktopModelOption>> configuredModels() =>
      _administration.configuredModels();

  @override
  Future<List<Map<String, dynamic>>> listSkills() =>
      _administration.listSkills();
  Future<List<Map<String, dynamic>>> listCommands() =>
      _administration.listCommands();

  Future<Map<String, dynamic>> reloadSkills() => _administration.reloadSkills();

  @override
  Future<List<Map<String, dynamic>>> listToolsets() =>
      _administration.listToolsets();

  Future<void> configureTools(List<String> names, {required bool enabled}) =>
      _administration.configureTools(names, enabled: enabled);

  Future<List<HermesMcpServer>> mcpServers() => _administration.mcpServers();

  Future<List<HermesMcpCatalogEntry>> mcpCatalog() =>
      _administration.mcpCatalog();

  Future<void> addMcpServer({
    required String name,
    String? url,
    String? command,
    List<String> arguments = const [],
    String? bearerToken,
    HermesMcpToolFilter? toolFilter,
  }) => _administration.addMcpServer(
    name: name,
    url: url,
    command: command,
    arguments: arguments,
    bearerToken: bearerToken,
    toolFilter: toolFilter,
  );

  Future<bool> addMcpCatalogEntry(
    HermesMcpCatalogEntry entry, {
    Map<String, String> credentials = const {},
  }) => _administration.addMcpCatalogEntry(entry, credentials: credentials);

  Future<HermesMcpTestResult> testMcpServer(String name) =>
      _administration.testMcpServer(name);

  Future<void> setMcpApiKey(String name, String value) =>
      _administration.setMcpApiKey(name, value);

  Future<void> removeMcpServer(String name) =>
      _administration.removeMcpServer(name);

  Future<bool> authenticateMcpServer(String name) =>
      _administration.authenticateMcpServer(name);

  Future<void> setMcpServerEnabled(String name, bool enabled) =>
      _administration.setMcpServerEnabled(name, enabled);

  Future<void> reloadMcp({String? runtimeId}) =>
      _administration.reloadMcp(runtimeId: runtimeId);

  @override
  Future<Map<String, dynamic>> getCapabilities() =>
      _administration.capabilities();

  @override
  Future<Map<String, dynamic>> healthDetailed() => _authDetailedStatus();

  @override
  Future<List<Map<String, dynamic>>> listJobs({bool live = false}) =>
      _administration.listJobs(live: live);

  @override
  Future<Map<String, dynamic>> createJob({
    required String name,
    required String prompt,
    required String schedule,
    String deliver = kHermesLocalDeliveryTarget,
    HermesJobCatchUp catchUp = HermesJobCatchUp.hermesDefault,
  }) => _administration.createJob(
    name: name,
    prompt: prompt,
    schedule: schedule,
    deliver: deliver,
    catchUp: catchUp,
  );

  @override
  Future<void> updateJob(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
    bool? enabled,
    String? deliver,
    HermesJobCatchUp? catchUp,
  }) => _administration.updateJob(
    id,
    name: name,
    prompt: prompt,
    schedule: schedule,
    enabled: enabled,
    deliver: deliver,
    catchUp: catchUp,
  );

  /// [method] [path] against the dashboard with its authentication, answering
  /// any status rather than throwing on one.
  Future<HermesDashboardResponse> dashboardRequest(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) => _rawRequest(method, path, body: body, query: query);

  /// Stops the job's running run (`POST /api/cron/jobs/{id}/cancel`).
  /// Throws [HermesJobStopUnsupportedException] on Hermes before 0.22.6.
  Future<HermesJobStopResult> stopJobRun(String id) =>
      _administration.cancelJobRun(id);

  /// Where a job can deliver (`GET /api/cron/delivery-targets`).
  Future<List<Map<String, dynamic>>> listJobDeliveryTargets() =>
      _administration.listJobDeliveryTargets();

  /// Group Chats hosted by this gateway (`groups.list`); empty without rooms.
  Future<List<HermesRoom>> listRooms({bool includeDisbanded = false}) =>
      _administration.listRooms(includeDisbanded: includeDisbanded);

  /// What this gateway can do with Group Chats (`groups.capabilities`).
  Future<HermesRoomCapabilities> roomCapabilities() => _roomCapabilities();

  /// A room's roster, settings and live work (`groups.state`).
  Future<HermesRoomState> roomState(String roomId) => _roomState(roomId);

  /// A room's log after [sinceSeq] (0: its newest events), every page.
  Future<List<HermesRoomEvent>> roomEventsSince(
    String roomId, {
    required int sinceSeq,
    int? latestSeq,
  }) => _roomEventsSince(roomId, sinceSeq: sinceSeq, latestSeq: latestSeq);

  /// Seats [members] in a new room named [name].
  Future<HermesRoom> createRoom({
    required String name,
    required List<HermesRoomMember> members,
  }) => _createRoom(name: name, members: members);

  /// Posts [send] to the room; sending the same [HermesRoomSend] again
  /// never posts it twice.
  Future<void> sendRoomMessage(String roomId, HermesRoomSend send) =>
      _sendRoomMessage(roomId, send);

  Future<void> renameRoom(String roomId, String name) =>
      _renameRoom(roomId, name);

  /// Saves the room's purpose, notes and who answers.
  Future<HermesRoomContext?> setRoomContext(
    String roomId,
    HermesRoomContext context,
  ) => _setRoomContext(roomId, context);

  /// Stops the room's work and ends it for good.
  Future<void> disbandRoom(String roomId) => _disbandRoom(roomId);

  /// Stops the room's queued and running work; how many tasks it stopped.
  /// Repeating [cancelId] repeats the same stop.
  Future<int> stopRoom(String roomId, {required String cancelId}) =>
      _stopRoom(roomId, cancelId);

  /// Gives a discussion paused at its limit one more round.
  Future<void> continueRoomDiscussion(
    String roomId,
    String discussionEventId,
  ) => _continueRoomDiscussion(roomId, discussionEventId);

  /// Answers [action]: an approval with [choice] (`once` or `deny`), or
  /// a retry.
  Future<void> answerRoomAction(
    String roomId,
    HermesRoomPendingAction action, {
    String? choice,
  }) => _answerRoomAction(roomId, action, choice: choice);

  @override
  Future<void> deleteJob(String id) =>
      _administration.mutateJob(id, "DELETE", "");
  @override
  Future<void> pauseJob(String id) =>
      _administration.mutateJob(id, "POST", "/pause");
  @override
  Future<void> resumeJob(String id) =>
      _administration.mutateJob(id, "POST", "/resume");
  /// Throws [HermesDashboardRequestWithdrawn] when a Stop withdrew it
  /// before it reached Hermes: the job did not run.
  @override
  Future<void> runJob(String id) => _administration.runJob(id);

  Future<List<Map<String, dynamic>>> listJobRuns(String id) =>
      _administration.listJobRuns(id);

  @override
  Future<HermesResponseStream> streamDesktopResponse(
    HermesChatInput input, {
    String? sessionId,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
    String? voiceContext,
    int? truncateBeforeRowId,
    int? truncateSeenThroughRowId,
  }) => _runtimeStreamDesktopResponse(
    input,
    sessionId: sessionId,
    options: options,
    cancelToken: cancelToken,
    voiceContext: voiceContext,
    truncateBeforeRowId: truncateBeforeRowId,
    truncateSeenThroughRowId: truncateSeenThroughRowId,
  );
  Future<void> interrupt(String storedId) => _runtimeInterrupt(storedId);
  Future<bool> steer(String storedId, String text) =>
      _runtimeSteer(storedId, text);
  Future<void> queue(String storedId, String text) =>
      _runtimeQueue(storedId, text);
  @override
  Future<void> resolveApproval(
    String runId, {
    required String approvalId,
    required bool approved,
  }) => _runtimeResolveApproval(
    runId,
    approvalId: approvalId,
    approved: approved,
  );
  Future<void> resolveApprovalChoice(
    String runtimeId, {
    required String approvalId,
    required String choice,
  }) => _runtimeResolveApprovalChoice(
    runtimeId,
    approvalId: approvalId,
    choice: choice,
  );
  Future<void> resolveApprovalChoiceForSession(
    String storedSessionId, {
    required String approvalId,
    required String choice,
  }) => _runtimeResolveApprovalChoiceForSession(
    storedSessionId,
    approvalId: approvalId,
    choice: choice,
  );
  Future<void> respondToDecision({
    required String runtimeId,
    String? storedSessionId,
    required String requestId,
    required HermesDecisionKind kind,
    required String value,
    String? mcpServer,
    String? mcpAction,
  }) => _runtimeRespondToDecision(
    runtimeId: runtimeId,
    storedSessionId: storedSessionId,
    requestId: requestId,
    kind: kind,
    value: value,
    mcpServer: mcpServer,
    mcpAction: mcpAction,
  );

  /// Answers a whole clarify form [requestId] at once: [answers] holds the
  /// questions still open, by id, with null for a skipped one.
  Future<void> respondToClarifyForm({
    required String runtimeId,
    String? storedSessionId,
    required String requestId,
    required Map<String, String?> answers,
  }) => _runtimeRespondToClarifyForm(
    runtimeId: runtimeId,
    storedSessionId: storedSessionId,
    requestId: requestId,
    answers: answers,
  );
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_lifecycleSubscription?.cancel());
    _dio.close(force: true);
    unawaited(_dashboardBridge?.close());
    unawaited(_stateSubscription?.cancel());
    unawaited(_rpc.close());
    unawaited(_turnStates.close());
    unawaited(_sessionTurnStateChanges.close());
    unawaited(_transcriptChanges.close());
    unawaited(_todoChanges.close());
    unawaited(_workingDirectoryChanges.close());
    unawaited(_backgroundWorkHints.close());
    unawaited(_desktopContractChanges.close());
    _eventBuffer.clear();
    _bindings.clear();
    _bindingSocketGenerations.clear();
    _freshSessionIds.clear();
    _lastTranscripts.clear();
    _appliedSessionOptions.clear();
    _appliedSessionModels.clear();
    _lastTurnUsage.clear();
    _compactedTranscripts.clear();
    for (final watch in _pendingCompactions.values) {
      unawaited(watch.cancel());
    }
    _pendingCompactions.clear();
    _sessionTurnStates.clear();
    _canonicalSessions.clear();
    _canonicalCreateIds.clear();
    _canonicalMutations.clear();
  }

  void _emitTurnState(HermesDesktopTurnState state) {
    if (!_closed) _turnStates.add(state);
  }

  void _emitSessionTurnState(String id) {
    if (!_closed) _sessionTurnStateChanges.add(id);
  }

  void _emitTranscriptChange(String id) {
    if (!_closed) _transcriptChanges.add(id);
  }

  void _emitDesktopContract(int value) {
    if (!_closed) _desktopContractChanges.add(value);
  }
}

/// Writes a pending decision down without waiting for it. The store refuses
/// writes while the app signs out, and a write can fail outright; started
/// from an event handler, nothing would catch either. Only the error's type
/// is logged: a decision's prompt may hold what the user typed.
void _persistPendingQuietly(Future<void> write) {
  unawaited(
    write.catchError((Object error) {
      DebugLogger.warning(
        'pending-decision-write-failed',
        scope: 'hermes/desktop',
        data: {'error': error.runtimeType.toString()},
      );
    }),
  );
}
