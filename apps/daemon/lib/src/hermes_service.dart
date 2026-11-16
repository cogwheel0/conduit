import 'dart:async';

import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_contract.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_toolset.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_open.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeServerProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// Whether [config] is a desktop gateway that signs in natively and has not
/// signed in yet: saved, with nothing to authenticate its requests by.
bool hermesAwaitsSignIn(HermesConfig config) =>
    config.mode == HermesBackendMode.desktopGateway &&
    config.desktopAuthKind == HermesDesktopAuthKind.nativePkce &&
    config.desktopCredentials?.nativeTokens == null;

/// The chat id a Hermes session opens as, the same one mobile uses.
String hermesChatId(String sessionId) => 'local:hermes_$sessionId';

/// The session behind a Hermes chat id, or null for any other chat.
String? hermesSessionOf(String chatId) =>
    chatId.startsWith('local:hermes_') && chatId.length > 'local:hermes_'.length
    ? chatId.substring('local:hermes_'.length)
    : null;

/// Implements `hermes.*` over the core's Hermes providers.
///
/// The connection, its secrets and every session action go through the
/// providers mobile uses -- which check that the connection did not change
/// under an action, and forget a session's document trust before deleting
/// it -- so the daemon adds nothing to what they already guard.
final class HermesService {
  HermesService(this._container, {EventBus? events}) : _events = events {
    // What one server said of its sessions is that server's: another
    // connection, or another account's server, starts from its own lists.
    _connectionWatch = _container.listen<HermesBackendService?>(
      hermesApiServiceProvider,
      (previous, next) {
        if (!identical(previous, next)) _forgetServer();
      },
    );
    _serverWatch = _container.listen<String?>(
      activeServerProvider.select((server) => server.value?.id),
      (previous, next) {
        if (previous != next) _forgetServer();
      },
    );
    // A session found read-only (opened, or a send Hermes refused) changes
    // what its chat offers: the window reads it again.
    _readOnlyWatch = _container.listen<Map<String, String>>(
      hermesReadOnlySessionsProvider,
      (previous, next) {
        for (final id in <String>{...?previous?.keys, ...next.keys}) {
          if (previous?[id] != next[id]) _announceChat(id);
        }
      },
    );
  }

  final ProviderContainer _container;
  final EventBus? _events;
  ProviderSubscription<Map<String, String>>? _readOnlyWatch;
  ProviderSubscription<HermesBackendService?>? _connectionWatch;
  ProviderSubscription<String?>? _serverWatch;

  /// Bumped when the connection or the account's server changes: a read
  /// begun before is the last server's.
  var _serverGeneration = 0;

  /// Another connection, or another account's server: nothing one server
  /// said of its sessions, or their messages, is kept for the next.
  void _forgetServer() {
    _serverGeneration++;
    _known.clear();
    _transcripts.clear();
    _previous.clear();
  }

  void dispose() {
    _readOnlyWatch?.close();
    _connectionWatch?.close();
    _serverWatch?.close();
  }

  void _announceChat(String sessionId) => _events?.emit(
    ConduitEventSpecs.chatsChanged,
    ChatsChanged(chatId: hermesChatId(sessionId)),
  );

  HermesConfigController get _config =>
      _container.read(hermesConfigProvider.notifier);

  void _announce() => _events?.emit(ConduitEventSpecs.hermesChanged, null);

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  Future<HermesSettings> settings() async {
    await _config.waitForSecretsHydration();
    final config = _container.read(hermesConfigProvider);
    return HermesSettings(
      enabled: config.enabled,
      baseUrl: config.baseUrl,
      mode: _modeName(config.mode),
      hasApiKey: config.apiKey?.trim().isNotEmpty ?? false,
      hasSessionKey: config.sessionKey?.trim().isNotEmpty ?? false,
      desktopProfile: config.desktopProfile,
      desktopAuthKind: config.desktopAuthKind.name,
      desktopSignedIn: config.desktopCredentials?.nativeTokens != null,
      allowSelfSignedCertificates: config.allowSelfSignedCertificates,
      // Not before its sign-in: counted usable, onboarding went straight on
      // to a chat whose every message failed as "couldn't connect", with
      // the sign-in button left behind on a page nobody was sent to.
      usable: config.isUsable && !hermesAwaitsSignIn(config),
    );
  }

  Future<HermesSettings> saveSettings(HermesSettingsEdit edit) async {
    await _config.waitForSecretsHydration();
    if (edit.onboarding) return _commitOnboarding(edit);
    try {
      await _config.saveConnection(
        baseUrl: edit.baseUrl,
        mode: _mode(edit.mode),
        desktopAuthKind: _authKind(edit.desktopAuthKind),
        desktopProfile: edit.desktopProfile,
        allowSelfSignedCertificates: edit.allowSelfSignedCertificates,
        apiKeyChanged: edit.apiKey != null,
        apiKey: _blankIsNull(edit.apiKey),
        sessionKeyChanged: edit.sessionKey != null,
        sessionKey: _blankIsNull(edit.sessionKey),
        desktopCredentialsChanged: edit.legacyToken != null,
        desktopCredentials: _desktopCredentials(edit),
      );
      await _config.setEnabled(edit.enabled);
    } on ArgumentError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: '${error.message}',
      );
    }
    _announce();
    return settings();
  }

  /// Onboarding's Hermes choice, through the core's own commit, as the
  /// phone's "Finish setup" makes it: the connection saved, Hermes turned
  /// on, a session key for an API server, and Hermes the preferred backend,
  /// all together or, when a step fails, none of them.
  ///
  /// The preferred backend is what the core routes by: without it a
  /// Hermes-only setup still read as onboarding on every launch.
  Future<HermesSettings> _commitOnboarding(HermesSettingsEdit edit) async {
    final saved = _container.read(hermesConfigProvider);
    final draft = HermesConnectionDraft(
      config: saved.copyWith(
        baseUrl: edit.baseUrl.trim(),
        mode: _mode(edit.mode),
        desktopAuthKind: _authKind(edit.desktopAuthKind),
        desktopProfile: edit.desktopProfile,
        allowSelfSignedCertificates: edit.allowSelfSignedCertificates,
        apiKey: edit.apiKey == null ? saved.apiKey : _blankIsNull(edit.apiKey),
        sessionKey: edit.sessionKey == null
            ? saved.sessionKey
            : _blankIsNull(edit.sessionKey),
        desktopCredentials: edit.legacyToken == null
            ? saved.desktopCredentials
            : _desktopCredentials(edit),
      ),
      apiKeyChanged: edit.apiKey != null,
      sessionKeyChanged: edit.sessionKey != null,
      desktopCredentialsChanged: edit.legacyToken != null,
    );
    try {
      await _container
          .read(hermesConnectionGatewayProvider)
          .commitOnboarding(draft, isCurrent: () => true);
    } on HermesConnectionCommitException catch (failure) {
      throw RpcError(
        code: failure.error is ArgumentError
            ? ConduitErrorCodes.invalidParams
            : ConduitErrorCodes.internal,
        debugMessage:
            'hermes onboarding failed at ${failure.stage.name}: '
            '${failure.error.runtimeType}',
      );
    } finally {
      _announce();
    }
    return settings();
  }

  /// Tries [edit] without saving it, as the settings form's Test does.
  Future<HermesTestResult> test(HermesSettingsEdit edit) async {
    await _config.waitForSecretsHydration();
    final saved = _container.read(hermesConfigProvider);
    // A secret left blank in the form means the saved one, when the form
    // is about the same server. Another server gets none of the saved ones:
    // not the key, the session key, nor the gateway's sign-in.
    final sameServer =
        HermesConfig.connectionEndpoint(saved.baseUrl) ==
        HermesConfig.connectionEndpoint(edit.baseUrl);
    final draft = saved.copyWith(
      enabled: true,
      baseUrl: edit.baseUrl.trim(),
      mode: _mode(edit.mode),
      desktopProfile: edit.desktopProfile,
      desktopAuthKind: _authKind(edit.desktopAuthKind),
      allowSelfSignedCertificates: edit.allowSelfSignedCertificates,
      apiKey: edit.apiKey ?? (sameServer ? saved.apiKey : null),
      sessionKey: edit.sessionKey ?? (sameServer ? saved.sessionKey : null),
      desktopCredentials: sameServer ? saved.desktopCredentials : null,
    );
    if (HermesConfig.connectionOrigin(draft.baseUrl) == null) {
      return const HermesTestResult(reason: 'invalid');
    }
    try {
      if (draft.mode == HermesBackendMode.desktopGateway) {
        final service = HermesDesktopApiService(config: draft);
        try {
          await service.statusProbe(refresh: true);
        } finally {
          service.close();
        }
        return const HermesTestResult(ok: true);
      }
      final ok = await testHermesDraftConnection(draft);
      return HermesTestResult(ok: ok, reason: ok ? null : 'unreachable');
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      return HermesTestResult(
        reason: status == 401 || status == 403 ? 'unauthorized' : 'unreachable',
      );
    } on Object {
      return const HermesTestResult(reason: 'unreachable');
    }
  }

  Future<HermesStatus> status() async {
    await _config.waitForSecretsHydration();
    final config = _container.read(hermesConfigProvider);
    final service = _container.read(hermesApiServiceProvider);
    if (!config.isUsable || service == null) {
      return HermesStatus(configured: config.isUsable);
    }
    final reachable = await service.health().catchError((Object _) => false);
    final capabilities = await readSettled(
      _container,
      hermesCapabilitiesProvider.future,
    ).catchError((Object _) => HermesCapabilities.enabledByDefault);
    final details = reachable
        ? await service.healthDetailed().catchError(
            (Object _) => const <String, dynamic>{},
          )
        : const <String, dynamic>{};
    return HermesStatus(
      configured: true,
      reachable: reachable,
      capabilities: HermesCapabilitiesDto(
        runApproval: capabilities.runApproval,
        skills: capabilities.skills,
        toolsets: capabilities.toolsets,
        jobs: capabilities.jobs,
        jobsAdmin: capabilities.jobsAdmin,
        sessions: capabilities.sessions,
        inputImages: capabilities.inputImages,
        inputFiles: capabilities.inputFiles,
      ),
      details: details,
    );
  }

  /// Signs in to a desktop gateway with native PKCE: the gateway's page
  /// opens in the system browser, and the tokens it gives back are kept
  /// with the other Hermes secrets.
  Future<HermesSettings> signIn() async {
    final service = _container.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'save a desktop-gateway connection first',
      );
    }
    // Captured before sign-in starts: the writer is bound to this
    // connection's lifetime, so an edit or sign-out while the browser is open
    // revokes it instead of writing tokens onto a different connection.
    final writeCredentials = _config.nativeCredentialsWriter();
    try {
      await const HermesDesktopConnectionCoordinator().signInNative(
        _container.read(hermesConfigProvider),
        service: service,
        onCredentialsChanged: writeCredentials,
      );
    } on DioException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.unauthorized,
        debugMessage: 'Hermes sign-in failed (${error.response?.statusCode})',
      );
    }
    _announce();
    return settings();
  }

  Future<HermesSettings> signOut() async {
    await _config.signOutDesktop();
    _announce();
    return settings();
  }

  // ---------------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------------

  Future<HermesSessions> sessions() => _guard(() async {
    if (_container.read(hermesApiServiceProvider) == null) {
      return const HermesSessions();
    }
    _container
      ..invalidate(hermesSessionsProvider)
      ..invalidate(hermesArchivedSessionsProvider);
    final sessions = await readSettled(
      _container,
      hermesSessionsProvider.future,
    );
    // The archived row has its own failure, as on a phone: it never takes
    // the conversations with it, and says so with Try Again.
    List<HermesSessionSummary> archived;
    var archivedFailed = false;
    try {
      archived = await readSettled(
        _container,
        hermesArchivedSessionsProvider.future,
      );
    } on Object {
      archived = const <HermesSessionSummary>[];
      archivedFailed = true;
    }
    for (final session in <HermesSessionSummary>[...sessions, ...archived]) {
      _known[session.id] = session;
    }
    // Read one after the other, a session archived in between is in both:
    // the later read, the archive, has it.
    final archivedIds = <String>{for (final session in archived) session.id};
    final active = sessions.where((s) => !archivedIds.contains(s.id));
    return HermesSessions(
      sessions: <HermesSessionDto>[
        // Pinned first, as the phone's list sections them.
        for (final session in active)
          if (session.pinned) _sessionDto(session),
        for (final session in active)
          if (!session.pinned) _sessionDto(session),
      ],
      archived: <HermesSessionDto>[
        for (final session in archived) _sessionDto(session),
      ],
      archivedFailed: archivedFailed,
    );
  });

  HermesSessionDto _sessionDto(HermesSessionSummary session) =>
      HermesSessionDto(
        id: session.id,
        chatId: hermesChatId(session.id),
        title: session.title,
        preview: session.preview,
        updatedAtMs: session.updatedAt?.millisecondsSinceEpoch,
        pinned: session.pinned,
        archived: session.archived,
        hidden: session.hidden,
        source: session.source,
        running: _isRunning(session.id),
      );

  /// The sessions the windows have been told of, by id: what an action on
  /// one changes from.
  final Map<String, HermesSessionSummary> _known =
      <String, HermesSessionSummary>{};

  /// Sessions with a turn of this daemon's running in them.
  final Set<String> _running = <String>{};

  bool _isRunning(String sessionId) {
    if (_running.contains(sessionId)) return true;
    // A Desktop Gateway also says when another app's turn runs in it.
    final service = _container.read(hermesApiServiceProvider);
    return service is HermesDesktopApiService &&
        service.turnStateFor(sessionId) == HermesDesktopTurnState.running;
  }

  /// A turn started or ended in [sessionId]: its row's spinner follows.
  void setRunning(String sessionId, bool running) {
    final changed = running
        ? _running.add(sessionId)
        : _running.remove(sessionId);
    if (changed) _announce();
  }

  /// Pins, archives or hides session [request.id], or undoes one of them,
  /// through the phone's own list controller (which keeps this device's
  /// way back to a session no Hermes list shows).
  Future<HermesSessions> update(HermesSessionUpdate request) =>
      _guard(() async {
        var session = await _summary(request.id);
        final controller = _sessions();
        if (request.hidden case final hidden?) {
          await controller.setHidden(session, hidden);
          session = session.copyWith(
            hidden: hidden,
            pinned: hidden && session.pinned ? false : null,
          );
        }
        if (request.archived case final archived?) {
          await controller.setArchived(session, archived);
          session = session.copyWith(
            archived: archived,
            pinned: archived && session.pinned ? false : null,
          );
        }
        if (request.pinned case final pinned?) {
          await controller.setPinned(session, pinned);
          session = session.copyWith(pinned: pinned);
        }
        _known[session.id] = session;
        _announce();
        return sessions();
      });

  /// The sessions hidden from every list, newest first: Hidden Chats.
  Future<HermesSessions> hidden() => _guard(() async {
    if (_container.read(hermesApiServiceProvider) == null) {
      return const HermesSessions();
    }
    _container.invalidate(hermesHiddenSessionsProvider);
    final hidden = await readSettled(
      _container,
      hermesHiddenSessionsProvider.future,
    );
    return HermesSessions(
      sessions: <HermesSessionDto>[
        for (final session in hidden)
          _sessionDto(_known[session.id] = session.copyWith(hidden: true)),
      ],
    );
  });

  /// Session [id] as the windows were last told of it, or as Hermes lists
  /// it now (a hidden one included).
  Future<HermesSessionSummary> _summary(String id) async {
    if (_known[id] case final known?) return known;
    await sessions();
    if (_known[id] == null) await hidden();
    return _known[id] ??
        (throw RpcError(
          code: ConduitErrorCodes.notFound,
          args: <String, String>{'sessionId': id},
          debugMessage: 'no such Hermes session',
        ));
  }

  Future<HermesSessions> rename(HermesRename request) => _guard(() async {
    await _sessions().rename(request.id, request.title.trim());
    _announce();
    return sessions();
  });

  Future<HermesSessions> delete(String id) => _guard(() async {
    final deleted = await _sessions().delete(id);
    _transcripts.remove(id);
    _previous.remove(id);
    _titles.remove(id);
    _known.remove(id);
    _running.remove(id);
    if (!deleted) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        retryable: true,
        debugMessage: 'the Hermes connection changed; try again',
      );
    }
    _announce();
    return sessions();
  });

  /// A read-only session's chat [request.chatId], continued in a session
  /// this app owns; answers with it, to open. Continue Here is Hermes's
  /// fork: every message, in a session the API server owns, which ends the
  /// original in the other app. Continue in a Copy is a new session that
  /// leaves the other app's chat alone; Hermes never stores the history a
  /// REST turn replays, so the copied messages are kept on this device as
  /// the copy's earlier messages (as the phone's notice does).
  Future<HermesSessionDto> continueChat(HermesContinue request) =>
      _guard(() async {
        final sessionId = hermesSessionOf(request.chatId);
        final service = _container.read(hermesApiServiceProvider);
        if (sessionId == null || service == null) {
          throw RpcError(
            code: ConduitErrorCodes.invalidParams,
            args: <String, String>{'chatId': request.chatId},
            debugMessage: 'not a Hermes chat',
          );
        }
        final title = await titleOf(sessionId) ?? '';
        if (!request.copy) {
          final forked = await fork(sessionId);
          return forked.title.isEmpty ? forked.copyWith(title: title) : forked;
        }
        // Read before anything is asked: the copy's messages are kept for
        // the connection that made it. A connection that keeps none (a
        // Desktop Gateway) would make an empty copy, so none is made.
        final identity = hermesSessionConnectionIdentity(
          service,
          _config.documentTrustPrincipalId(),
        ).connectionIdentity;
        final store = hermesCopiedHistoryFor(_container, service, identity);
        if (store == null || identity == null) {
          throw RpcError(
            code: ConduitErrorCodes.unsupported,
            args: <String, String>{'chatId': request.chatId},
            debugMessage: 'this Hermes connection keeps no copied messages',
          );
        }
        final transcript = await service.getSessionMessages(sessionId);
        // Untitled: Hermes refuses a second session with the same title.
        final copyId = await service.createSession();
        try {
          await saveHermesCopyHistory(
            store: store,
            connectionIdentity: identity,
            service: service,
            sessionId: copyId,
            transcript: transcript,
          );
        } on HermesCopyHistoryException catch (error) {
          _container.invalidate(hermesSessionsProvider);
          _announce();
          throw RpcError(
            code: ConduitErrorCodes.conflict,
            retryable: true,
            debugMessage: 'the copy could not keep its messages: $error',
          );
        }
        final copy = HermesSessionSummary(
          id: copyId,
          title: title,
          source: kHermesApiOwnedSessionSources.first,
          updatedAt: DateTime.now(),
        );
        _known[copyId] = copy;
        _titles[copyId] = title;
        _container.invalidate(hermesSessionsProvider);
        _announce();
        return _sessionDto(copy);
      });

  /// A branch made from a chat (Branch from Here), or another session
  /// this app made, told of before Hermes lists it: its title, and the
  /// earlier messages it opens with on REST (saved on this device).
  Future<HermesSessionDto> adopt(
    HermesSessionSummary session, {
    List<Map<String, dynamic>>? transcript,
  }) async {
    var summary = session;
    if (transcript != null) {
      final service = _container.read(hermesApiServiceProvider);
      final identity = service == null
          ? null
          : hermesSessionConnectionIdentity(
              service,
              _config.documentTrustPrincipalId(),
            ).connectionIdentity;
      final store = service == null
          ? null
          : hermesCopiedHistoryFor(_container, service, identity);
      if (service != null && store != null && identity != null) {
        await saveHermesCopyHistory(
          store: store,
          connectionIdentity: identity,
          service: service,
          sessionId: session.id,
          transcript: transcript,
        );
      }
    }
    if (summary.title.isNotEmpty) _titles[summary.id] = summary.title;
    summary = _known[summary.id] = summary;
    _transcripts.remove(summary.id);
    _container.invalidate(hermesSessionsProvider);
    _announce();
    return _sessionDto(summary);
  }

  /// What session [sessionId]'s chat is, beside its messages.
  HermesChatDto chatState(String sessionId) {
    final owner = _container.read(hermesReadOnlySessionsProvider)[sessionId];
    return HermesChatDto(
      sessionId: sessionId,
      readOnly: owner != null,
      owner: owner == null || owner.trim().isEmpty
          ? ''
          : hermesSessionSourceName(owner),
    );
  }

  /// What a Hermes chat offers: its history's actions, unless another
  /// Hermes app owns it. Undo needs a Desktop Gateway, whose session keeps
  /// the transcript.
  ChatAbilities abilities(String sessionId) {
    final readOnly = chatState(sessionId).readOnly;
    return ChatAbilities(
      branchFromHere: !readOnly,
      undoLastTurn:
          !readOnly &&
          _container.read(hermesApiServiceProvider) is HermesDesktopApiService,
    );
  }

  /// A copy of a session to go on from; answers with the copy.
  Future<HermesSessionDto> fork(String id) => _guard(() async {
    final forked = await _sessions().fork(id);
    if (forked == null) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'the session could not be forked',
      );
    }
    _announce();
    final all = await sessions();
    return all.sessions.firstWhere(
      (s) => s.id == forked,
      orElse: () => HermesSessionDto(id: forked, chatId: hermesChatId(forked)),
    );
  });

  HermesSessionsController _sessions() =>
      _container.read(hermesSessionsProvider.notifier);

  // ---------------------------------------------------------------------------
  // Transcripts
  // ---------------------------------------------------------------------------

  /// Each open session's messages: read from Hermes once, then kept as
  /// turns add to them. Hermes is where they are stored; this is what the
  /// window is shown between reads.
  final Map<String, List<ChatMessage>> _transcripts =
      <String, List<ChatMessage>>{};

  Future<List<ChatMessage>> transcript(
    String sessionId, {
    bool reload = false,
  }) async {
    final cached = _transcripts[sessionId];
    if (cached != null && !reload) return List<ChatMessage>.of(cached);
    final generation = _serverGeneration;
    final service = _container.read(hermesApiServiceProvider);
    if (service == null) return const <ChatMessage>[];
    final identity = hermesSessionConnectionIdentity(
      service,
      _config.documentTrustPrincipalId(),
    ).connectionIdentity;
    // A REST copy opens with the earlier messages this device keeps for it.
    final raw = await _guard(
      () async => withHermesCopiedHistory(
        hermesCopiedHistoryFor(_container, service, identity),
        identity,
        sessionId,
        await service.getSessionMessages(sessionId),
      ),
    );
    final read = hermesMessagesToChatMessages(
      raw,
      modelId: kHermesDefaultModelId,
      trustedLocalDocumentKeys: identity == null
          ? const <String>{}
          : HermesLocalDocumentTrustStore.trustedDocumentKeys(
              connectionIdentity: identity,
              sessionId: sessionId,
            ),
      sensitiveValues: service.config.sensitiveValues,
    );
    // Hermes's rows carry no ids of their own, so each read names them
    // anew: what a window or a chat's scope already calls a message keeps
    // that name, or a reply chosen in the window is not found in the
    // scope (Branch from Here, edit).
    // Answered after the connection or server changed: the last server's
    // messages, never shown or kept for this one.
    if (generation != _serverGeneration) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the Hermes connection changed during the read',
      );
    }
    final messages = _keepIds(
      read,
      _transcripts[sessionId] ?? _previous.remove(sessionId),
    );
    // Another Hermes app's session opens read-only on REST, as on a phone.
    if (_known[sessionId] case final summary?
        when await hermesSessionOpensReadOnly(_container, service, summary)) {
      _container
          .read(hermesReadOnlySessionsProvider.notifier)
          .mark(sessionId, source: summary.source);
    }
    _transcripts[sessionId] = messages;
    return List<ChatMessage>.of(messages);
  }

  /// Drops what is kept of [sessionId]'s transcript, so the next read is
  /// Hermes's own record: a turn has added to it there. Its messages'
  /// ids -- [latest]'s, the chat scope's, when given -- name the same
  /// messages in that read.
  void forget(String sessionId, {List<ChatMessage>? latest}) {
    final kept = latest ?? _transcripts[sessionId];
    _transcripts.remove(sessionId);
    if (kept != null) _previous[sessionId] = List<ChatMessage>.of(kept);
  }

  /// Transcripts dropped by [forget], until the next read takes their ids.
  final Map<String, List<ChatMessage>> _previous =
      <String, List<ChatMessage>>{};

  /// [read] with [known]'s ids where the same message stands at the same
  /// place (same role and text), unless the read already uses that id.
  static List<ChatMessage> _keepIds(
    List<ChatMessage> read,
    List<ChatMessage>? known,
  ) {
    if (known == null || known.isEmpty) return read;
    final taken = <String>{for (final m in read) m.id};
    return <ChatMessage>[
      for (final (i, message) in read.indexed)
        if (i < known.length &&
            known[i].id != message.id &&
            !taken.contains(known[i].id) &&
            known[i].role == message.role &&
            known[i].content.trim() == message.content.trim())
          message.copyWith(id: known[i].id)
        else
          message,
    ];
  }

  /// Titles of sessions this app made that Hermes leaves untitled (a copy
  /// keeps its chat's title while the list does not).
  final Map<String, String> _titles = <String, String>{};

  /// The session's title as the list has it, for a chat header.
  Future<String?> titleOf(String sessionId) async {
    final sessions = _container.read(hermesSessionsProvider).value;
    final listed = sessions?.where((s) => s.id == sessionId).firstOrNull?.title;
    if (listed != null && listed != 'Untitled session') return listed;
    return _titles[sessionId] ?? listed ?? _known[sessionId]?.title;
  }

  void announceSessions() {
    _container.invalidate(hermesSessionsProvider);
    _announce();
  }

  // ---------------------------------------------------------------------------
  // Jobs and catalog
  // ---------------------------------------------------------------------------

  Future<HermesJobs> jobs() => _guard(() async {
    if (_container.read(hermesApiServiceProvider) == null) {
      return const HermesJobs();
    }
    _container.invalidate(hermesJobsProvider);
    final jobs = await readSettled(_container, hermesJobsProvider.future);
    return HermesJobs(jobs: jobs.map(_job).toList(growable: false));
  });

  Future<HermesJobs> saveJob(HermesJobEdit edit) => _guard(() async {
    final prompt = edit.prompt.trim();
    final schedule = edit.schedule.trim();
    if (prompt.isEmpty || schedule.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a job needs a prompt and a schedule',
      );
    }
    final name = edit.name?.trim();
    final jobs = _container.read(hermesJobsProvider.notifier);
    if (edit.id == null) {
      await jobs.create(
        name: name == null || name.isEmpty ? prompt : name,
        prompt: prompt,
        schedule: schedule,
      );
    } else {
      await jobs.edit(edit.id!, name: name, prompt: prompt, schedule: schedule);
    }
    _announce();
    return this.jobs();
  });

  Future<HermesJobs> setJobEnabled(HermesJobToggle toggle) => _guard(() async {
    await _container
        .read(hermesJobsProvider.notifier)
        .setEnabled(toggle.id, toggle.enabled);
    _announce();
    return jobs();
  });

  Future<HermesJobs> runJob(String id) => _guard(() async {
    await _container.read(hermesJobsProvider.notifier).runNow(id);
    return jobs();
  });

  Future<HermesJobs> deleteJob(String id) => _guard(() async {
    await _container.read(hermesJobsProvider.notifier).delete(id);
    _announce();
    return jobs();
  });

  Future<HermesCatalog> catalog() => _guard(() async {
    final service = _container.read(hermesApiServiceProvider);
    if (service == null) return const HermesCatalog();
    final skills = await service.listSkills().catchError(
      (Object _) => const <Map<String, dynamic>>[],
    );
    _container.invalidate(hermesToolsetsProvider);
    final toolsets = await readSettled(
      _container,
      hermesToolsetsProvider.future,
    ).catchError((Object _) => <HermesToolset>[]);
    return HermesCatalog(
      skills: <HermesSkillDto>[
        for (final skill in skills)
          if ((skill['name'] ?? skill['id'])?.toString() case final name?
              when name.trim().isNotEmpty)
            HermesSkillDto(
              name: name,
              description: skill['description']?.toString(),
            ),
      ],
      toolsets: <HermesToolsetDto>[
        for (final toolset in toolsets)
          HermesToolsetDto(
            name: toolset.name,
            label: toolset.label,
            description: toolset.description,
            enabled: toolset.enabled,
            tools: toolset.tools,
          ),
      ],
    );
  });

  static HermesJobDto _job(HermesJob job) => HermesJobDto(
    id: job.id,
    name: job.name,
    prompt: job.prompt,
    schedule: job.schedule,
    scheduleText: describeHermesCronSchedule(job.schedule),
    enabled: job.enabled,
    lastStatus: job.lastStatus,
    lastError: job.lastError,
    lastRunAtMs: job.lastRun?.millisecondsSinceEpoch,
    nextRunAtMs: job.nextRun?.millisecondsSinceEpoch,
  );

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  static String _modeName(HermesBackendMode mode) => switch (mode) {
    HermesBackendMode.responsesApi => 'responses',
    HermesBackendMode.desktopGateway => 'desktop',
  };

  static HermesBackendMode _mode(String name) => name == 'desktop'
      ? HermesBackendMode.desktopGateway
      : HermesBackendMode.responsesApi;

  static HermesDesktopAuthKind _authKind(String name) =>
      HermesDesktopAuthKind.values.where((k) => k.name == name).firstOrNull ??
      HermesDesktopAuthKind.legacyToken;

  /// The saved Desktop Gateway credentials with [edit]'s legacy token in
  /// place (null: the edit leaves them alone). With another server's
  /// address only the token goes: the saved sign-in and access headers
  /// belong to the old server, as the core's connection form keeps them.
  HermesDesktopCredentials? _desktopCredentials(HermesSettingsEdit edit) {
    final token = edit.legacyToken;
    if (token == null) return null;
    final config = _container.read(hermesConfigProvider);
    final saved =
        HermesConfig.connectionOrigin(config.baseUrl) ==
            HermesConfig.connectionOrigin(edit.baseUrl.trim())
        ? config.desktopCredentials
        : null;
    return HermesDesktopCredentials(
      legacyToken: _blankIsNull(token),
      nativeTokens: saved?.nativeTokens,
      accessHeaders: saved?.accessHeaders ?? const <String, String>{},
    );
  }

  static String? _blankIsNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on RpcError {
      rethrow;
    } on StateError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        retryable: true,
        debugMessage: error.message,
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw RpcError(
        code: switch (status) {
          401 || 403 => ConduitErrorCodes.unauthorized,
          404 => ConduitErrorCodes.notFound,
          null => ConduitErrorCodes.connectionFailed,
          _ => ConduitErrorCodes.serverError,
        },
        args: <String, String>{'status': '${status ?? ''}'},
        debugMessage: 'Hermes request failed ($status)',
        retryable: status == null || status >= 500,
      );
    }
  }
}
