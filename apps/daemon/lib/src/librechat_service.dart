import 'dart:async';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show copyLibreChatConversation;
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart'
    show isLibreChatModel;
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_memories_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart'
    show LibreChatApiService;
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart'
    show LibreChatAuthService, LibreChatSignedIn, LibreChatTwoFactorRequired;
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/providers/account_change_superseded.dart';
import 'package:conduit_core/features/librechat/services/librechat_probe.dart'
    show
        LibreChatProbeFound,
        LibreChatProbeNotLibreChat,
        LibreChatProbeUnreachable,
        probeLibreChatServer;
import 'package:conduit_core/features/librechat/services/librechat_sso.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/providers/app_providers.dart' show modelsProvider;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'account_scope.dart';
import 'accounts_service.dart';
import 'event_bus.dart';
import 'models_service.dart' show currentModel;
import 'settled.dart';

/// Implements `librechat.*`: signing in to LibreChat accounts, and what only
/// LibreChat has -- its composer tools, memories and Duplicate.
///
/// Everything is the core's: the probe, the auth service, the account
/// registry, the primary-account switcher (which parks Open WebUI), the
/// capabilities, the memories controller and the copy of a chat. This holds
/// what the phone's sign-in form holds between steps -- the server's
/// two-step token, kept here so it never leaves -- and the boundary: the
/// window gets outcomes, never a token.
///
/// The list of LibreChat accounts, switching and signing out are
/// `accounts.*` ([AccountsService]), since the two kinds share them.
final class LibreChatService {
  LibreChatService(
    this._container, {
    required EventBus events,
    required AccountsService accounts,
    DateTime Function()? clock,
  }) : _events = events,
       _accounts = accounts,
       _clock = clock ?? DateTime.now;

  final ProviderContainer _container;
  // ignore: unused_field
  final EventBus _events;
  final AccountsService _accounts;
  final DateTime Function() _clock;

  static const Uuid _uuid = Uuid();

  /// How long a two-step sign-in waits for its code: LibreChat's token
  /// lasts five minutes.
  static const Duration twoFactorWindow = Duration(minutes: 5);

  /// Servers the window probed, by base address: signing in there reuses
  /// what the probe read (the SSO buttons, the server's own address).
  final Map<String, ({LibreChatServer server, LibreChatServerInfo info})>
  _probed = {};

  /// Two-step sign-ins waiting for their code, by flow id.
  final Map<String, _TwoFactorFlow> _flows = {};

  /// Bumped as each sign-in begins (a password sent, single sign-on
  /// started): an older one still out, a two-step flow waiting for its code
  /// or a single sign-on started before, then puts no account in charge.
  /// A code sent for a two-step flow, or a single sign-on completed, goes
  /// on in the round of the step that began it.
  int _signInRound = 0;

  /// The single sign-on started last: its id, round and account; only its
  /// completion goes ahead, in that round, under that account.
  ({String id, _Begun begun})? _ssoStarted;

  /// A newer sign-in begins: the ones before it are superseded. Captured
  /// before the step's first wait.
  _Begun _beginSignIn() {
    _flows.clear();
    _ssoStarted = null;
    return (
      round: ++_signInRound,
      account: AccountScope.capture(_container),
    );
  }

  /// Whether a step [begun] is still the sign-in under way: no newer one
  /// began, and the account in charge is the one it began under (no account
  /// change at all since).
  bool _current(_Begun begun) =>
      begun.round == _signInRound && begun.account.isCurrent;

  // -------------------------------------------------------------------------
  // Probe
  // -------------------------------------------------------------------------

  Future<LibreChatProbeResult> probe(LibreChatProbe request) async {
    final baseUrl = LibreChatServer.normalizeBaseUrl(request.url);
    if (baseUrl == null) {
      return const LibreChatProbeResult(
        outcome: LibreChatProbeOutcome.invalidAddress,
      );
    }
    final result = await probeLibreChatServer(
      LibreChatServer(baseUrl: baseUrl),
      adapter: _container.read(libreChatHttpAdapterProvider),
    );
    switch (result) {
      case LibreChatProbeFound(:final server, :final info):
        _probed[server.baseUrl] = (server: server, info: info);
        return LibreChatProbeResult(
          outcome: LibreChatProbeOutcome.found,
          server: LibreChatServerDto(
            baseUrl: server.baseUrl,
            title: info.appTitle,
            passwordSignIn: info.passwordSignInEnabled,
            ldap: info.ldapEnabled,
            ldapUsesUsername: info.ldapUsesUsername,
            ssoProviders: <LibreChatSsoProviderDto>[
              for (final provider in info.ssoProviders)
                LibreChatSsoProviderDto(
                  kind: provider.kind.name,
                  label: provider.label,
                ),
            ],
          ),
        );
      case LibreChatProbeNotLibreChat(:final looksLikeOpenWebUi):
        return LibreChatProbeResult(
          outcome: looksLikeOpenWebUi
              ? LibreChatProbeOutcome.openWebUi
              : LibreChatProbeOutcome.notLibreChat,
        );
      case LibreChatProbeUnreachable():
        return const LibreChatProbeResult(
          outcome: LibreChatProbeOutcome.unreachable,
        );
    }
  }

  /// The server at [url] with what its probe read, probing it again when
  /// this run has not.
  Future<({LibreChatServer server, LibreChatServerInfo info})?> _server(
    String url,
  ) async {
    final baseUrl = LibreChatServer.normalizeBaseUrl(url);
    if (baseUrl == null) return null;
    final known = _probed[baseUrl];
    if (known != null) return known;
    await probe(LibreChatProbe(url: baseUrl));
    return _probed[baseUrl];
  }

  // -------------------------------------------------------------------------
  // Sign-in
  // -------------------------------------------------------------------------

  Future<LibreChatSignInResult> signIn(LibreChatSignIn request) async {
    final begun = _beginSignIn();
    final target = await _server(request.url);
    if (target == null) {
      return const LibreChatSignInResult(
        outcome: LibreChatSignInOutcome.unreachable,
      );
    }
    final auth = _auth(target.server);
    try {
      final result = await auth.signIn(
        email: request.email,
        password: request.password,
      );
      switch (result) {
        case LibreChatSignedIn(:final session):
          return await _finish(
            target,
            session,
            force: request.force,
            begun: begun,
          );
        case LibreChatTwoFactorRequired(:final tempToken):
          // Superseded meanwhile: no flow waits for its code.
          if (!_current(begun)) return _superseded;
          _expireFlows();
          final flowId = _uuid.v4();
          _flows[flowId] = _TwoFactorFlow(
            server: target.server,
            info: target.info,
            tempToken: tempToken,
            started: _clock(),
            begun: begun,
          );
          return LibreChatSignInResult(
            outcome: LibreChatSignInOutcome.twoFactorRequired,
            flowId: flowId,
          );
      }
    } on Object catch (error, stackTrace) {
      return _failure(error, stackTrace);
    } finally {
      auth.close();
    }
  }

  /// A code for a two-step flow: it goes on in the round of the password
  /// step that began the flow, under the account in charge then. A code for
  /// a flow that is gone supersedes nothing, and tries of one flow's code
  /// never supersede each other: the server takes its token once.
  Future<LibreChatSignInResult> verify(LibreChatVerify request) async {
    _expireFlows();
    final flow = _flows[request.flowId];
    if (flow == null || !_current(flow.begun)) {
      // Begun under another account than the one in charge now: the flow
      // is no good for this one.
      _flows.remove(request.flowId);
      return const LibreChatSignInResult(
        outcome: LibreChatSignInOutcome.expired,
      );
    }
    final begun = flow.begun;
    final code = request.code.trim();
    if (code.isEmpty) {
      return LibreChatSignInResult(
        outcome: LibreChatSignInOutcome.invalidCode,
        flowId: request.flowId,
      );
    }
    final auth = _auth(flow.server);
    try {
      final session = await auth.verifyTwoFactor(
        tempToken: flow.tempToken,
        code: request.backupCode ? null : code,
        backupCode: request.backupCode ? code : null,
      );
      // The server took the code: the flow is done, whatever comes next.
      if (identical(_flows[request.flowId], flow)) {
        _flows.remove(request.flowId);
      }
      return await _finish(
        (server: flow.server, info: flow.info),
        session,
        force: request.force,
        begun: begun,
      );
    } on LibreChatApiException catch (error) {
      if (error.statusCode == 401) {
        return LibreChatSignInResult(
          outcome: LibreChatSignInOutcome.invalidCode,
          flowId: request.flowId,
        );
      }
      return _failure(error, StackTrace.current);
    } on Object catch (error, stackTrace) {
      return _failure(error, stackTrace);
    } finally {
      auth.close();
    }
  }

  /// Where single sign-on with [request]'s provider starts, and the rules
  /// the window's browser follows (the core's, which the phone's web view
  /// follows too).
  Future<LibreChatSsoPlan> ssoStart(LibreChatSsoStart request) async {
    final begun = _beginSignIn();
    final startId = _uuid.v4();
    _ssoStarted = (id: startId, begun: begun);
    final target = await _server(request.url);
    if (target == null) {
      throw RpcError(
        code: ConduitErrorCodes.connectionFailed,
        args: <String, String>{'url': request.url},
        debugMessage: 'no LibreChat server answered there',
      );
    }
    final provider = target.info.ssoProviders
        .where((provider) => provider.kind.name == request.provider)
        .firstOrNull;
    if (provider == null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'provider': request.provider},
        debugMessage: 'the server offers no such sign-in',
      );
    }
    final base = libreChatSsoBase(
      target.server.baseUrl,
      target.info.serverDomain,
    );
    final path = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return LibreChatSsoPlan(
      startUrl: '$base${provider.path}',
      cookieUrl: libreChatSsoCookieUrl(base).toString(),
      serverOrigins: <String>[base.origin],
      basePath: path,
      startId: startId,
    );
  }

  /// Completes the single sign-on started last, in its round and under the
  /// account in charge when it started: one started before another sign-in
  /// began, or under another account, puts no account in charge.
  Future<LibreChatSignInResult> completeSso(
    LibreChatSsoCompletion request,
  ) async {
    final started = _ssoStarted;
    // Cookies from another start than the one started last (an older
    // sign-in window), or naming none, put no account in charge.
    if (started == null || started.id != request.startId) return _superseded;
    final begun = started.begun;
    if (!_current(begun)) return _superseded;
    final target = await _server(request.url);
    if (target == null) {
      return const LibreChatSignInResult(
        outcome: LibreChatSignInOutcome.unreachable,
      );
    }
    final cookies = libreChatCookiesFrom(<String, String>{
      for (final entry in request.cookies.entries)
        if (entry.key == LibreChatCookies.refreshTokenName ||
            entry.key == LibreChatCookies.tokenProviderName)
          entry.key: entry.value,
    });
    if (!cookies.hasRefreshToken) {
      return const LibreChatSignInResult(
        outcome: LibreChatSignInOutcome.ssoUnfinished,
      );
    }
    final auth = _auth(target.server);
    try {
      final session = await auth.sessionFromCookies(cookies);
      return await _finish(target, session, force: request.force, begun: begun);
    } on LibreChatSessionExpiredException {
      return const LibreChatSignInResult(
        outcome: LibreChatSignInOutcome.ssoUnfinished,
      );
    } on Object catch (error, stackTrace) {
      return _failure(error, stackTrace);
    } finally {
      auth.close();
    }
  }

  /// Saves the account signed in to and puts it in charge of the chats, as
  /// the phone's sign-in does: saved first, then switched to through the
  /// core's switcher, which parks Open WebUI.
  ///
  /// A sign-in another step superseded, or begun under another account
  /// than the one in charge now (the user chose one meanwhile), saves and
  /// switches nothing: the round and the account it began under are asked
  /// again after every wait, last inside the save (before the session is
  /// written) and inside the switch (before the account is put in charge).
  /// One superseded after its save, before its switch, stays saved, not in
  /// charge.
  Future<LibreChatSignInResult> _finish(
    ({LibreChatServer server, LibreChatServerInfo info}) target,
    LibreChatSession session, {
    required bool force,
    required _Begun begun,
  }) async {
    if (!_current(begun)) return _superseded;
    final LibreChatAccount account;
    try {
      account = await _container
          .read(libreChatAccountsProvider)
          .saveSignedIn(
            server: target.server,
            session: session,
            info: target.info,
            activate: false,
            stillCurrent: () => _current(begun),
          );
    } on AccountChangeSuperseded {
      return _superseded;
    } on Object catch (error, stackTrace) {
      return _failure(error, stackTrace);
    }
    final AccountChangeResult result;
    try {
      // Parking Open WebUI moves the account in charge: past the switch's
      // own check of where it starts from, only the round is asked.
      result = await _accounts.useLibreChat(
        account.id,
        force: force,
        scope: begun.account,
        stillCurrent: () => begun.round == _signInRound,
      );
    } on AccountChangeSuperseded {
      return _superseded;
    }
    return LibreChatSignInResult(
      outcome: result.outcome == AccountChangeOutcome.blockedByActiveReply
          ? LibreChatSignInOutcome.blockedByActiveReply
          : LibreChatSignInOutcome.signedIn,
      accountId: account.id,
      accounts: result.accounts,
    );
  }

  static const _superseded = LibreChatSignInResult(
    outcome: LibreChatSignInOutcome.expired,
  );

  LibreChatAuthService _auth(LibreChatServer server) => LibreChatAuthService(
    server,
    adapter: _container.read(libreChatHttpAdapterProvider),
  );

  void _expireFlows() {
    final now = _clock();
    _flows.removeWhere(
      (_, flow) => now.difference(flow.started) > twoFactorWindow,
    );
  }

  /// A step that failed: the server's refusal in its own words, as the
  /// phone's form shows it, or a plain failure.
  LibreChatSignInResult _failure(Object error, StackTrace stackTrace) {
    if (error is LibreChatApiException) {
      return LibreChatSignInResult(
        outcome: LibreChatSignInOutcome.rejected,
        serverMessage: error.message,
      );
    }
    DebugLogger.error(
      'librechat-sign-in-failed',
      scope: 'daemon/librechat',
      error: error,
      stackTrace: stackTrace,
    );
    return const LibreChatSignInResult(outcome: LibreChatSignInOutcome.failed);
  }

  // -------------------------------------------------------------------------
  // Composer
  // -------------------------------------------------------------------------

  Future<LibreChatComposer> composer(LibreChatComposerTarget request) async {
    final model = await _model(request.modelId);
    if (model == null || !isLibreChatModel(model)) {
      return const LibreChatComposer();
    }
    final options = await libreChatComposerOptionsFor(
      model,
      capabilities: () =>
          readSettled(_container, libreChatCapabilitiesProvider.future),
      api: () => _container.read(libreChatApiServiceProvider),
    );
    return LibreChatComposer(
      libreChat: true,
      webSearchToolId: options.webSearch ? kLibreChatWebSearchToolId : null,
      codeInterpreterToolId: options.codeInterpreter
          ? kLibreChatCodeToolId
          : null,
      fileSearchToolId: options.fileSearch ? kLibreChatFileSearchToolId : null,
      mcpServers: <LibreChatMcpServerDto>[
        for (final server in options.mcpServers)
          LibreChatMcpServerDto(
            name: server.name,
            toolId: server.toolId,
            toolCount: server.toolCount,
            needsConnection: server.needsConnection,
          ),
      ],
      prompts: options.prompts,
      webUrl: _container.read(libreChatFileBaseUrlProvider),
    );
  }

  Future<core.Model?> _model(String? id) async {
    if (id == null || id.isEmpty) return currentModel(_container);
    final List<core.Model> models;
    try {
      models = await readSettled(_container, modelsProvider.future);
    } on Object {
      return null;
    }
    return models.where((model) => model.id == id).firstOrNull;
  }

  // -------------------------------------------------------------------------
  // Memories
  // -------------------------------------------------------------------------

  /// The account's memories with its own rights: if another account signs
  /// in while they are read, nothing goes out (one account's memories never
  /// with another's rights).
  Future<LibreChatMemories> memories() async {
    _requireSignedIn();
    final account = _container.read(libreChatApiServiceProvider);
    final state = await readSettled(
      _container,
      libreChatMemoriesProvider.future,
    );
    final capabilities = await readSettled(
      _container,
      libreChatCapabilitiesProvider.future,
    );
    _sameAccount(account);
    final usage = state.memories.usage;
    return LibreChatMemories(
      enabled: state.enabled,
      memories: <LibreChatMemoryDto>[
        for (final memory in state.memories.memories)
          LibreChatMemoryDto(
            key: memory.key,
            value: memory.value,
            tokenCount: memory.tokenCount ?? 0,
            updatedMs: memory.updatedAt?.millisecondsSinceEpoch,
          ),
      ],
      totalTokens: state.memories.totalTokens,
      tokenLimit: state.memories.tokenLimit,
      usagePercent: usage == null ? null : (usage * 100).round(),
      canCreate: capabilities.createMemories,
      canUpdate: capabilities.updateMemories,
      canOptOut: capabilities.optOutMemories,
    );
  }

  Future<LibreChatMemories> saveMemory(LibreChatMemoryEdit request) async {
    _requireSignedIn();
    final key = request.key.trim();
    if (!RegExp(r'^[a-z_]+$').hasMatch(key)) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'key': key},
        debugMessage: 'a memory key takes lowercase letters and underscores',
      );
    }
    await _write(
      () => _container
          .read(libreChatMemoriesProvider.notifier)
          .save(
            originalKey: request.originalKey,
            key: key,
            value: request.value,
          ),
    );
    return memories();
  }

  Future<LibreChatMemories> deleteMemory(LibreChatMemoryRef request) async {
    _requireSignedIn();
    await _write(
      () => _container
          .read(libreChatMemoriesProvider.notifier)
          .delete(request.key),
    );
    return memories();
  }

  Future<LibreChatMemories> setMemoriesEnabled(
    LibreChatMemoryToggle request,
  ) async {
    _requireSignedIn();
    await _write(
      () => _container
          .read(libreChatMemoriesProvider.notifier)
          .setEnabled(request.enabled),
    );
    return memories();
  }

  /// The memories controller lives only while read: it is read first, so a
  /// write lands on a built one, and refused writes leave as the server's
  /// words. A write is the account's it was asked for: if another account
  /// signed in while the list was read, it is refused, never sent there.
  Future<void> _write(Future<void> Function() write) async {
    final account = _container.read(libreChatApiServiceProvider);
    await readSettled(_container, libreChatMemoriesProvider.future);
    _sameAccount(account);
    try {
      await write();
    } on LibreChatApiException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        args: <String, String>{'detail': error.message},
        debugMessage: 'LibreChat refused: ${error.message}',
      );
    }
  }

  /// Refuses (session expired) once another LibreChat account than
  /// [account] -- the one a request began under -- is signed in.
  void _sameAccount(LibreChatApiService? account) {
    if (!identical(_container.read(libreChatApiServiceProvider), account)) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'another LibreChat account signed in meanwhile',
      );
    }
  }

  void _requireSignedIn() {
    if (_container.read(libreChatApiServiceProvider) == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no LibreChat account is signed in',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Duplicate
  // -------------------------------------------------------------------------

  /// Copies LibreChat chat [request] whole, on its server, and stores the
  /// copy: the phone's Duplicate.
  Future<ChatForked> duplicate(ChatRef request) async {
    _requireSignedIn();
    try {
      final copy = await copyLibreChatConversation(_container, request.id);
      return ChatForked(chatId: copy.id);
    } on LibreChatApiException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        args: <String, String>{'detail': error.message},
        debugMessage: 'the chat could not be duplicated: ${error.message}',
      );
    }
  }
}

/// A sign-in's round and the account in charge when it began.
typedef _Begun = ({int round, AccountScope account});

final class _TwoFactorFlow {
  _TwoFactorFlow({
    required this.server,
    required this.info,
    required this.tempToken,
    required this.started,
    required this.begun,
  });

  final LibreChatServer server;
  final LibreChatServerInfo info;
  final String tempToken;
  final DateTime started;

  /// The password step's round and account in charge.
  final _Begun begun;
}
