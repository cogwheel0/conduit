import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/debug_logger.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../models/hermes_chat_input.dart';
import '../models/hermes_config.dart';
import '../models/hermes_mcp.dart';
import '../models/hermes_model.dart';
import '../models/hermes_run_event.dart';
import 'hermes_backend_service.dart';
import 'hermes_http_transport.dart';
import 'hermes_dashboard_rest_bridge.dart';
import 'hermes_dashboard_webview_policy.dart';
import 'hermes_desktop_transport.dart';
import 'hermes_identifier.dart';
import 'hermes_json_guard.dart';
import 'hermes_pending_decision_store.dart';

part 'hermes_desktop_administration.dart';
part 'hermes_desktop_auth_rest.dart';
part 'hermes_desktop_event_projection.dart';
part 'hermes_desktop_live_runtime.dart';
part 'hermes_desktop_turn_runtime.dart';

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

@visibleForTesting
Future<List<Map<String, dynamic>>> loadHermesDesktopTranscriptPages(
  Future<List<Map<String, dynamic>>> Function(int offset, int limit) loadPage, {
  int maximum = 10000,
}) async {
  const pageSize = 500;
  final messages = <Map<String, dynamic>>[];
  while (messages.length < maximum) {
    final limit = min(pageSize, maximum - messages.length);
    final page = await loadPage(messages.length, limit);
    messages.addAll(page.take(limit));
    if (page.length < limit) break;
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
    with WidgetsBindingObserver
    implements HermesBackendService, HermesDesktopTurnService {
  HermesDesktopApiService({
    required this.config,
    Dio? dio,
    HermesDesktopRpcClient? rpc,
    this.onCredentialsChanged,
  }) : _nativeTokens = config.desktopCredentials?.nativeTokens,
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

  final String _origin;
  final Uri _root;
  @override
  final HermesConfig config;
  final Dio _dio;
  final HermesDesktopRpcClient _rpc;
  late final _HermesDesktopAdministration _administration;
  HermesDashboardRestBridge? _dashboardBridge;
  final HermesDesktopCredentialsWriter? onCredentialsChanged;
  HermesDesktopTokenSet? _nativeTokens;
  bool _closed = false;
  final Map<String, HermesSessionBinding> _bindings = {};
  final Map<String, int> _bindingSocketGenerations = {};
  final Set<String> _freshSessionIds = {};
  final Map<String, List<Map<String, dynamic>>> _lastTranscripts = {};
  final Map<String, String> _appliedSessionOptions = {};
  final HermesDesktopEventBuffer _eventBuffer = HermesDesktopEventBuffer();
  final _turnStates = StreamController<HermesDesktopTurnState>.broadcast();
  final _sessionTurnStateChanges = StreamController<String>.broadcast();
  final Map<String, HermesDesktopTurnState> _sessionTurnStates = {};
  final _transcriptChanges = StreamController<String>.broadcast();
  final _desktopContractChanges = StreamController<int>.broadcast();

  Map<String, dynamic>? _status;
  Future<void>? _connecting;
  Future<HermesDesktopTokenSet?>? _refreshing;
  Future<void>? _foregroundReconciliation;
  StreamSubscription<HermesDesktopEvent>? _stateSubscription;
  bool _authoritativeRunning = true;
  bool _supportsMcpRpcLifecycle = true;
  bool _reconciliationStale = false;
  bool _observingLifecycle = false;
  int _desktopContract = 0;

  void startLifecycleObservation() {
    if (_closed || _observingLifecycle) return;
    WidgetsBinding.instance.addObserver(this);
    _observingLifecycle = true;
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
      path.startsWith('/api/mcp');

  @override
  Future<bool> health() => _authHealth();
  Future<Map<String, dynamic>> statusProbe({bool refresh = false}) =>
      _authStatusProbe(refresh: refresh);
  Future<List<String>> listProfiles() => _authListProfiles();
  Future<HermesDesktopTokenSet> signInNative({String? provider}) =>
      _authSignInNative(provider: provider);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _runtimeDidChangeAppLifecycleState(state);

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
  Future<List<Map<String, dynamic>>> listSessions() => _runtimeListSessions();
  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) => _runtimeGetSessionMessages(id, cancelToken: cancelToken);
  Future<List<HermesPendingDesktopDecision>> pendingDecisionsForSession(
    String storedId,
  ) => _runtimePendingDecisionsForSession(storedId);
  @override
  Future<void> renameSession(String id, String title) =>
      _runtimeRenameSession(id, title);
  @override
  Future<void> deleteSession(String id, {CancelToken? cancelToken}) =>
      _runtimeDeleteSession(id, cancelToken: cancelToken);
  bool sessionIdsReferToSameBinding(String left, String right) =>
      _runtimeSessionIdsReferToSameBinding(left, right);
  @override
  Future<String> forkSession(String id) => _runtimeForkSession(id);

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
  }) => _administration.addMcpServer(
    name: name,
    url: url,
    command: command,
    arguments: arguments,
    bearerToken: bearerToken,
  );

  Future<void> addMcpPreset(String name) => _administration.addMcpPreset(name);

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
  Future<Map<String, dynamic>> healthDetailed() => statusProbe(refresh: true);

  @override
  Future<List<Map<String, dynamic>>> listJobs() => _administration.listJobs();

  @override
  Future<Map<String, dynamic>> createJob({
    required String name,
    required String prompt,
    required String schedule,
  }) =>
      _administration.createJob(name: name, prompt: prompt, schedule: schedule);

  @override
  Future<void> updateJob(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
    bool? enabled,
  }) => _administration.updateJob(
    id,
    name: name,
    prompt: prompt,
    schedule: schedule,
    enabled: enabled,
  );

  @override
  Future<void> deleteJob(String id) =>
      _administration.mutateJob(id, "DELETE", "");
  @override
  Future<void> pauseJob(String id) =>
      _administration.mutateJob(id, "POST", "/pause");
  @override
  Future<void> resumeJob(String id) =>
      _administration.mutateJob(id, "POST", "/resume");
  @override
  Future<void> runJob(String id) =>
      _administration.mutateJob(id, "POST", "/trigger");

  Future<List<Map<String, dynamic>>> listJobRuns(String id) =>
      _administration.listJobRuns(id);

  @override
  Future<HermesResponseStream> streamDesktopResponse(
    HermesChatInput input, {
    String? sessionId,
    required HermesDesktopSessionOptions options,
    CancelToken? cancelToken,
  }) => _runtimeStreamDesktopResponse(
    input,
    sessionId: sessionId,
    options: options,
    cancelToken: cancelToken,
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
  Future<void> resolveApprovalForSession(
    String storedSessionId, {
    required String approvalId,
    required bool approved,
  }) => _runtimeResolveApprovalForSession(
    storedSessionId,
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
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_observingLifecycle) WidgetsBinding.instance.removeObserver(this);
    _dio.close(force: true);
    unawaited(_dashboardBridge?.close());
    unawaited(_stateSubscription?.cancel());
    unawaited(_rpc.close());
    unawaited(_turnStates.close());
    unawaited(_sessionTurnStateChanges.close());
    unawaited(_transcriptChanges.close());
    unawaited(_desktopContractChanges.close());
    _eventBuffer.clear();
    _bindings.clear();
    _bindingSocketGenerations.clear();
    _freshSessionIds.clear();
    _lastTranscripts.clear();
    _appliedSessionOptions.clear();
    _sessionTurnStates.clear();
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
