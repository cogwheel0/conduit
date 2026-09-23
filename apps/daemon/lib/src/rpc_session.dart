import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';

import 'auth_service.dart';
import 'chats_service.dart';
import 'composer_service.dart';
import 'direct_service.dart';
import 'mcp_service.dart';
import 'notes_service.dart';
import 'channels_service.dart';
import 'prompts_service.dart';
import 'event_bus.dart';
import 'log.dart';
import 'models_service.dart';
import 'servers_service.dart';
import 'settings_service.dart';
import 'system_service.dart';
import 'turns_service.dart';
import 'ui_requests_service.dart';
import 'workspace_service.dart';
import 'terminals_service.dart';

/// One connected renderer window.
///
/// A [json_rpc.Peer] rather than a server, because requests flow both ways:
/// the core calls `ui.request` when a tool needs approval, and blocks on a
/// human sitting in front of this window.
class RpcSession {
  RpcSession({
    required this.sessionId,
    required StreamChannel<String> channel,
    required SystemService system,
    required EventBus events,
    required DaemonLog log,
    ServersService? servers,
    AuthService? auth,
    SettingsService? settings,
    ChatsService? chats,
    TurnsService? turns,
    ModelsService? models,
    UiRequestsService? uiRequests,
    ComposerService? composer,
    PromptsService? prompts,
    DirectService? direct,
    McpService? mcp,
    NotesService? notes,
    ChannelsService? channels,
    WorkspaceService? workspace,
    TerminalsService? terminals,
    void Function(bool online)? reportNetwork,
  }) : _events = events,
       _channels = channels,
       _workspace = workspace,
       _terminals = terminals,
       _notes = notes,
       _direct = direct,
       _mcp = mcp,
       _reportNetwork = reportNetwork,
       _composer = composer,
       _prompts = prompts,
       _uiRequests = uiRequests,
       _log = log,
       _system = system,
       _servers = servers,
       _auth = auth,
       _settings = settings,
       _chats = chats,
       _turns = turns,
       _models = models,
       _peer = json_rpc.Peer(channel) {
    _register();
  }

  final String sessionId;
  final EventBus _events;
  final DaemonLog _log;
  final SystemService _system;

  /// Null until the core is up. A session can exist before then -- the window
  /// opens while the daemon is still restoring state -- and answering
  /// `servers.list` with an empty list in that window would look to the UI
  /// like a fresh install. It gets `rpc.daemonUnavailable` instead.
  final ServersService? _servers;
  final AuthService? _auth;
  final SettingsService? _settings;
  final ChatsService? _chats;
  final TurnsService? _turns;
  final ModelsService? _models;
  final json_rpc.Peer _peer;

  /// Set by a successful `system.handshake`. Until then every other method is
  /// refused, so a client cannot skip version negotiation and then be
  /// surprised by a payload it cannot parse.
  HandshakeRequest? _handshake;

  bool get isHandshakeComplete => _handshake != null;

  /// Questions from the core, shared by every window. Null until the core
  /// is attached, when there is nothing to ask yet.
  final UiRequestsService? _uiRequests;
  final ComposerService? _composer;
  final PromptsService? _prompts;
  final DirectService? _direct;
  final McpService? _mcp;
  final NotesService? _notes;
  final ChannelsService? _channels;
  final WorkspaceService? _workspace;
  final TerminalsService? _terminals;

  /// Where a window's `online`/`offline` events go: the connectivity port,
  /// which then tells every window. Null before the core is up.
  final void Function(bool online)? _reportNetwork;

  Future<void> listen() => _peer.listen();

  Future<void> close() async {
    _events.detach(sessionId);
    // If that was the last window, nobody is left to answer: questions
    // still waiting take their conservative default now rather than hang
    // the turn that asked them.
    _uiRequests?.onWindowsChanged();
    await _peer.close();
  }

  void _register() {
    _events.attach(sessionId, (envelope) {
      // A closed peer still sitting in the bus is a bug, but dropping the
      // event is better than tearing down every other window's fan-out.
      if (_peer.isClosed) return;
      sendEvent(_peer, envelope);
    });

    registerTypedMethod<HandshakeRequest, HandshakeResponse>(
      _peer,
      ConduitMethods.systemHandshake,
      decodeParams: HandshakeRequest.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        if (request.protocolVersion != kConduitProtocolVersion) {
          throw RpcError(
            code: ConduitErrorCodes.protocolVersionMismatch,
            args: <String, String>{
              'expected': kConduitProtocolVersion,
              'actual': request.protocolVersion,
            },
            debugMessage:
                'client speaks ${request.protocolVersion}, daemon speaks '
                '$kConduitProtocolVersion',
          );
        }
        _handshake = request;
        _log.info(
          'session $sessionId: ${request.clientName} ${request.clientVersion} '
          '(${request.windowKind.name}, ${request.locale})',
        );
        return _system.handshake(sessionId: sessionId, request: request);
      },
    );

    registerTypedMethodNoParams<PongResult>(
      _peer,
      ConduitMethods.systemPing,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _system.ping();
      },
    );

    registerTypedMethodNoParams<Capabilities>(
      _peer,
      ConduitMethods.systemCapabilities,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _system.capabilities;
      },
    );

    registerTypedMethodNoParams<ShutdownResult>(
      _peer,
      ConduitMethods.systemShutdown,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _system.shutdown();
      },
    );

    registerTypedMethodNoParams<DiagnosticsExport>(
      _peer,
      ConduitMethods.systemExportDiagnostics,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _system.exportDiagnostics();
      },
    );

    registerTypedMethod<NetworkReport, Map<String, dynamic>>(
      _peer,
      ConduitMethods.systemNetwork,
      decodeParams: NetworkReport.fromJson,
      encodeResult: (result) => result,
      handler: (report) {
        _requireHandshake();
        _reportNetwork?.call(report.online);
        return <String, dynamic>{'ok': true};
      },
    );

    registerTypedMethod<EventSubscription, EventSubscription>(
      _peer,
      ConduitMethods.eventsSubscribe,
      decodeParams: EventSubscription.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (subscription) {
        _requireHandshake();
        for (final event in subscription.events) {
          if (!ConduitEvents.all.contains(event)) {
            throw RpcError(
              code: ConduitErrorCodes.invalidParams,
              args: <String, String>{'event': event},
              debugMessage: 'unknown event name "$event"',
            );
          }
        }
        _events.subscribe(sessionId, subscription);
        // A window that opens while a question is waiting sees it too.
        // Otherwise a tool approval asked before the window existed could
        // only be answered by one that no longer does.
        for (final request in _uiRequests?.pending ?? const <UiRequest>[]) {
          sendEvent(
            _peer,
            EventEnvelope(
              event: ConduitEvents.uiRequest,
              seq: _events.lastSeq,
              payload: request.toJson(),
            ),
          );
        }
        // Echo the accepted filter back so the client can assert on what the
        // daemon actually stored rather than on what it hoped it sent.
        return subscription;
      },
    );

    registerTypedMethod<UiResponse, Map<String, dynamic>>(
      _peer,
      ConduitMethods.uiRespond,
      decodeParams: UiResponse.fromJson,
      encodeResult: (result) => result,
      handler: (response) {
        _requireHandshake();
        final accepted = _uiRequests?.respond(response) ?? false;
        if (!accepted) {
          // Late or duplicate answer — the request already timed out or
          // another window answered first. Not an error worth surfacing.
          _log.debug(
            'session $sessionId: ui.respond for unknown request '
            '${response.requestId}',
          );
        }
        return <String, dynamic>{'accepted': accepted};
      },
    );

    _registerServers();
    _registerAuth();
    _registerSettings();
    _registerChats();
    _registerTurns();
    _registerModels();

    _peer.registerFallback((json_rpc.Parameters params) {
      final method = params.method;
      throw RpcError(
        code: ConduitMethods.isReserved(method)
            // A reserved namespace that is not wired up yet is a milestone
            // that has not landed, which is worth telling apart from a typo.
            ? ConduitErrorCodes.unsupported
            : ConduitErrorCodes.methodNotFound,
        args: <String, String>{'method': method},
      ).toException();
    });
  }

  void _registerServers() {
    registerTypedMethodNoParams<ServerList>(
      _peer,
      ConduitMethods.serversList,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireServers().list();
      },
    );

    registerTypedMethod<ServerDraft, ServerSummary>(
      _peer,
      ConduitMethods.serversAdd,
      decodeParams: ServerDraft.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (draft) {
        _requireHandshake();
        return _requireServers().add(draft);
      },
    );

    registerTypedMethod<ServerDraft, ServerSummary>(
      _peer,
      ConduitMethods.serversUpdate,
      decodeParams: ServerDraft.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (draft) {
        _requireHandshake();
        return _requireServers().update(draft);
      },
    );

    registerTypedMethod<ServerRef, ServerList>(
      _peer,
      ConduitMethods.serversRemove,
      decodeParams: ServerRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireServers().remove(ref.id);
      },
    );

    registerTypedMethodNoParams<ServerStatus>(
      _peer,
      ConduitMethods.serversStatus,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireServers().status();
      },
    );

    registerTypedMethod<ServerRef, ServerList>(
      _peer,
      ConduitMethods.serversConnect,
      decodeParams: ServerRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireServers().connect(ref.id);
      },
    );
  }

  void _registerAuth() {
    registerTypedMethodNoParams<AuthSnapshot>(
      _peer,
      ConduitMethods.authStatus,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireAuth().status();
      },
    );

    registerTypedMethod<PasswordLogin, AuthSnapshot>(
      _peer,
      ConduitMethods.authLoginWithPassword,
      decodeParams: PasswordLogin.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        return _requireAuth().loginWithPassword(params);
      },
    );

    registerTypedMethod<PasswordLogin, AuthSnapshot>(
      _peer,
      ConduitMethods.authLoginWithLdap,
      decodeParams: PasswordLogin.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        return _requireAuth().loginWithLdap(params);
      },
    );

    registerTypedMethod<ApiKeyLogin, AuthSnapshot>(
      _peer,
      ConduitMethods.authLoginWithApiKey,
      decodeParams: ApiKeyLogin.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        return _requireAuth().loginWithApiKey(params);
      },
    );

    registerTypedMethodNoParams<AuthSnapshot>(
      _peer,
      ConduitMethods.authSilentLogin,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireAuth().silentLogin();
      },
    );

    registerTypedMethod<ExternalAuthCompletion, AuthSnapshot>(
      _peer,
      ConduitMethods.authCompleteExternal,
      decodeParams: ExternalAuthCompletion.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        return _requireAuth().completeExternal(params);
      },
    );

    registerTypedMethodNoParams<Map<String, dynamic>>(
      _peer,
      ConduitMethods.authHasSavedCredentials,
      encodeResult: (result) => result,
      handler: () async {
        _requireHandshake();
        return <String, dynamic>{
          'hasSavedCredentials': await _requireAuth().hasSavedCredentials(),
        };
      },
    );

    registerTypedMethod<SignOutRequest, SignOutResult>(
      _peer,
      ConduitMethods.authSignOut,
      decodeParams: SignOutRequest.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireAuth().signOut(request);
      },
    );

    registerTypedMethod<Map<String, dynamic>, AuthSnapshot>(
      _peer,
      ConduitMethods.authSetReviewerMode,
      decodeParams: (json) => json,
      encodeResult: (result) => result.toJson(),
      handler: (params) {
        _requireHandshake();
        final enabled = params['enabled'];
        if (enabled is! bool) {
          throw const RpcError(
            code: ConduitErrorCodes.invalidParams,
            debugMessage: 'auth.setReviewerMode needs a boolean "enabled"',
          );
        }
        return _requireAuth().setReviewerMode(enabled: enabled);
      },
    );
  }

  void _registerSettings() {
    registerTypedMethodNoParams<AppPreferences>(
      _peer,
      ConduitMethods.settingsGetApp,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireSettings().read();
      },
    );

    registerTypedMethod<AppPreferencesPatch, AppPreferences>(
      _peer,
      ConduitMethods.settingsSetApp,
      decodeParams: AppPreferencesPatch.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (patch) {
        _requireHandshake();
        return _requireSettings().write(patch);
      },
    );
  }

  void _registerChats() {
    registerTypedMethodNoParams<ChatList>(
      _peer,
      ConduitMethods.chatsList,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireChats().list();
      },
    );

    registerTypedMethodNoParams<ChatList>(
      _peer,
      ConduitMethods.chatsLoadMore,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireChats().loadMore();
      },
    );

    registerTypedMethod<ChatRef, Map<String, dynamic>>(
      _peer,
      ConduitMethods.chatsGet,
      decodeParams: ChatRef.fromJson,
      // Nullable result, so the envelope carries the absence rather than an
      // error: opening a chat that was deleted on another device is ordinary.
      encodeResult: (result) => result,
      handler: (ref) async {
        _requireHandshake();
        final detail = await _requireChats().get(ref.id);
        return <String, dynamic>{'chat': detail?.toJson()};
      },
    );

    registerTypedMethod<RenameChat, ChatList>(
      _peer,
      ConduitMethods.chatsRename,
      decodeParams: RenameChat.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().rename(request.id, request.title);
      },
    );

    registerTypedMethod<SetChatFlag, ChatList>(
      _peer,
      ConduitMethods.chatsSetPinned,
      decodeParams: SetChatFlag.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().setPinned(request.id, value: request.value);
      },
    );

    registerTypedMethod<SetChatFlag, ChatList>(
      _peer,
      ConduitMethods.chatsSetArchived,
      decodeParams: SetChatFlag.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().setArchived(request.id, value: request.value);
      },
    );

    registerTypedMethod<ChatRef, ChatList>(
      _peer,
      ConduitMethods.chatsDelete,
      decodeParams: ChatRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireChats().delete(ref.id);
      },
    );

    registerTypedMethodNoParams<SyncState>(
      _peer,
      ConduitMethods.syncGet,
      encodeResult: (result) => result.toJson(),
      handler: () async {
        _requireHandshake();
        return _requireChats().syncState();
      },
    );

    registerTypedMethod<ArchivedVisibility, ChatList>(
      _peer,
      ConduitMethods.chatsSetArchivedVisible,
      decodeParams: ArchivedVisibility.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().setArchivedVisible(visible: request.visible);
      },
    );

    registerTypedMethod<ChatRef, ChatShare>(
      _peer,
      ConduitMethods.chatsShare,
      decodeParams: ChatRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireChats().share(ref.id);
      },
    );

    registerTypedMethod<ChatRef, ChatShare>(
      _peer,
      ConduitMethods.chatsUnshare,
      decodeParams: ChatRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireChats().unshare(ref.id);
      },
    );

    registerTypedMethod<BulkChats, BulkChatsResult>(
      _peer,
      ConduitMethods.chatsBulk,
      decodeParams: BulkChats.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().bulk(request);
      },
    );

    registerTypedMethod<ChatSystemPrompt, Map<String, dynamic>>(
      _peer,
      ConduitMethods.chatsSetSystemPrompt,
      decodeParams: ChatSystemPrompt.fromJson,
      encodeResult: (result) => result,
      handler: (request) async {
        _requireHandshake();
        final detail = await _requireChats().setSystemPrompt(request);
        return <String, dynamic>{'chat': detail?.toJson()};
      },
    );

    registerTypedMethod<ChatRef, ChatTree>(
      _peer,
      ConduitMethods.chatsTree,
      decodeParams: ChatRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().tree(request.id);
      },
    );

    registerTypedMethod<ChatCurrent, Map<String, dynamic>>(
      _peer,
      ConduitMethods.chatsSetCurrent,
      decodeParams: ChatCurrent.fromJson,
      encodeResult: (result) => result,
      handler: (request) async {
        _requireHandshake();
        final detail = await _requireChats().setCurrent(request);
        return <String, dynamic>{'chat': detail?.toJson()};
      },
    );

    registerTypedMethod<FolderRef, FolderContents>(
      _peer,
      ConduitMethods.chatsFolder,
      decodeParams: FolderRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().folder(request.folderId);
      },
    );

    registerTypedMethod<MoveChat, ChatList>(
      _peer,
      ConduitMethods.chatsMove,
      decodeParams: MoveChat.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().move(request);
      },
    );

    registerTypedMethodNoParams<TagList>(
      _peer,
      ConduitMethods.chatsTagsAll,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireChats().allTags();
      },
    );

    registerTypedMethod<ChatTagEdit, TagList>(
      _peer,
      ConduitMethods.chatsTagsAdd,
      decodeParams: ChatTagEdit.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().addTag(request);
      },
    );

    registerTypedMethod<ChatTagEdit, TagList>(
      _peer,
      ConduitMethods.chatsTagsRemove,
      decodeParams: ChatTagEdit.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireChats().removeTag(request);
      },
    );

    registerTypedMethod<ChatSearchQuery, ChatSearchResults>(
      _peer,
      ConduitMethods.chatsSearch,
      decodeParams: ChatSearchQuery.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (query) {
        _requireHandshake();
        return _requireChats().search(query);
      },
    );
  }

  void _registerTurns() {
    registerTypedMethod<SendTurn, SendTurnAccepted>(
      _peer,
      ConduitMethods.turnsSend,
      decodeParams: SendTurn.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireTurns().send(request);
      },
    );

    registerTypedMethod<RegenerateTurn, SendTurnAccepted>(
      _peer,
      ConduitMethods.turnsRegenerate,
      decodeParams: RegenerateTurn.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireTurns().regenerate(request);
      },
    );

    registerTypedMethod<EditTurn, SendTurnAccepted>(
      _peer,
      ConduitMethods.turnsEdit,
      decodeParams: EditTurn.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireTurns().edit(request);
      },
    );

    registerTypedMethod<RateTurn, Map<String, dynamic>>(
      _peer,
      ConduitMethods.turnsRate,
      decodeParams: RateTurn.fromJson,
      encodeResult: (result) => result,
      handler: (request) async {
        _requireHandshake();
        await _requireTurns().rate(request);
        return <String, dynamic>{'rated': true};
      },
    );

    registerTypedMethod<StopTurn, Map<String, dynamic>>(
      _peer,
      ConduitMethods.turnsStop,
      decodeParams: StopTurn.fromJson,
      encodeResult: (result) => result,
      handler: (request) async {
        _requireHandshake();
        await _requireTurns().stop(request.chatId);
        return <String, dynamic>{'stopped': true};
      },
    );
  }

  void _registerModels() {
    registerTypedMethodNoParams<ComposerOptions>(
      _peer,
      ConduitMethods.composerOptions,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        final composer = _composer;
        if (composer == null) {
          throw const RpcError(
            code: ConduitErrorCodes.daemonUnavailable,
            debugMessage: 'the core is not up yet',
          );
        }
        return composer.options();
      },
    );

    registerTypedMethod<KnowledgeQuery, KnowledgeList>(
      _peer,
      ConduitMethods.composerKnowledge,
      decodeParams: KnowledgeQuery.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        final composer = _composer;
        if (composer == null) {
          throw const RpcError(
            code: ConduitErrorCodes.daemonUnavailable,
            debugMessage: 'the core is not up yet',
          );
        }
        return composer.knowledge(request.query);
      },
    );

    registerTypedMethodNoParams<DirectConnectionList>(
      _peer,
      ConduitMethods.directList,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireDirect().list();
      },
    );

    registerTypedMethod<DirectConnectionEdit, DirectConnectionList>(
      _peer,
      ConduitMethods.directSave,
      decodeParams: DirectConnectionEdit.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (edit) {
        _requireHandshake();
        return _requireDirect().save(edit);
      },
    );

    registerTypedMethod<DirectRef, DirectConnectionList>(
      _peer,
      ConduitMethods.directRemove,
      decodeParams: DirectRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireDirect().remove(ref.id);
      },
    );

    registerTypedMethod<DirectEnable, DirectConnectionList>(
      _peer,
      ConduitMethods.directSetEnabled,
      decodeParams: DirectEnable.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireDirect().setEnabled(request.id, request.enabled);
      },
    );

    registerTypedMethod<DirectConnectionEdit, DirectTestResult>(
      _peer,
      ConduitMethods.directTest,
      decodeParams: DirectConnectionEdit.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (edit) {
        _requireHandshake();
        return _requireDirect().test(edit);
      },
    );

    registerTypedMethod<DirectHistory, DirectConnectionList>(
      _peer,
      ConduitMethods.directSetHistory,
      decodeParams: DirectHistory.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireDirect().setHistory(localOnly: request.localOnly);
      },
    );

    registerTypedMethod<DirectPreferred, DirectConnectionList>(
      _peer,
      ConduitMethods.directSetPreferred,
      decodeParams: DirectPreferred.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireDirect().setPreferred(preferred: request.preferred);
      },
    );

    registerTypedMethod<DirectRef, OllamaModelList>(
      _peer,
      ConduitMethods.directOllamaModels,
      decodeParams: DirectRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireDirect().ollamaModels(ref.id);
      },
    );

    for (final (method, run)
        in <(String, Future<OllamaModelList> Function(OllamaModelAction))>[
          (
            ConduitMethods.directOllamaLoad,
            (a) => _requireDirect().ollamaLoad(a),
          ),
          (
            ConduitMethods.directOllamaUnload,
            (a) => _requireDirect().ollamaUnload(a),
          ),
          (
            ConduitMethods.directOllamaKeepAlive,
            (a) => _requireDirect().ollamaKeepAlive(a),
          ),
          (
            ConduitMethods.directOllamaThinking,
            (a) => _requireDirect().ollamaThinking(a),
          ),
        ]) {
      registerTypedMethod<OllamaModelAction, OllamaModelList>(
        _peer,
        method,
        decodeParams: OllamaModelAction.fromJson,
        encodeResult: (result) => result.toJson(),
        handler: (action) {
          _requireHandshake();
          return run(action);
        },
      );
    }

    registerTypedMethodNoParams<ChannelList>(
      _peer,
      ConduitMethods.channelsList,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireChannels().list();
      },
    );

    registerTypedMethod<ChannelEdit, ChannelList>(
      _peer,
      ConduitMethods.channelsSave,
      decodeParams: ChannelEdit.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (edit) {
        _requireHandshake();
        return _requireChannels().save(edit);
      },
    );

    registerTypedMethod<ChannelRef, ChannelList>(
      _peer,
      ConduitMethods.channelsDelete,
      decodeParams: ChannelRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireChannels().delete(ref.id);
      },
    );

    registerTypedMethod<ChannelRef, ChannelList>(
      _peer,
      ConduitMethods.channelsLeave,
      decodeParams: ChannelRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireChannels().leave(ref.id);
      },
    );

    registerTypedMethod<ChannelMessagesQuery, ChannelMessages>(
      _peer,
      ConduitMethods.channelsMessages,
      decodeParams: ChannelMessagesQuery.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (query) {
        _requireHandshake();
        return _requireChannels().messages(query);
      },
    );

    registerTypedMethod<ChannelPost, ChannelMessageDto>(
      _peer,
      ConduitMethods.channelsPost,
      decodeParams: ChannelPost.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (post) {
        _requireHandshake();
        return _requireChannels().post(post);
      },
    );

    registerTypedMethod<ChannelMessageEdit, ChannelMessageDto>(
      _peer,
      ConduitMethods.channelsEditMessage,
      decodeParams: ChannelMessageEdit.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (edit) {
        _requireHandshake();
        return _requireChannels().editMessage(edit);
      },
    );

    for (final (method, decode, run)
        in <
          (
            String,
            Object Function(Map<String, dynamic>),
            Future<void> Function(Object),
          )
        >[
          (
            ConduitMethods.channelsDeleteMessage,
            ChannelMessageRef.fromJson,
            (p) => _requireChannels().deleteMessage(p as ChannelMessageRef),
          ),
          (
            ConduitMethods.channelsReact,
            ChannelReact.fromJson,
            (p) => _requireChannels().react(p as ChannelReact),
          ),
          (
            ConduitMethods.channelsPin,
            ChannelPin.fromJson,
            (p) => _requireChannels().pin(p as ChannelPin),
          ),
          (
            ConduitMethods.channelsTyping,
            ChannelTyping.fromJson,
            (p) async => _requireChannels().typing(p as ChannelTyping),
          ),
          (
            ConduitMethods.channelsMarkRead,
            ChannelRef.fromJson,
            (p) => _requireChannels().markRead((p as ChannelRef).id),
          ),
        ]) {
      registerTypedMethod<Object, Map<String, dynamic>>(
        _peer,
        method,
        decodeParams: decode,
        encodeResult: (result) => result,
        handler: (params) async {
          _requireHandshake();
          await run(params);
          return <String, dynamic>{'ok': true};
        },
      );
    }

    registerTypedMethod<ChannelRef, ChannelMembers>(
      _peer,
      ConduitMethods.channelsMembers,
      decodeParams: ChannelRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireChannels().members(ref.id);
      },
    );

    // terminal.* (M7).
    void terminal<P, R>(
      String method,
      P Function(Map<String, dynamic>) decode,
      Map<String, dynamic> Function(R) encode,
      Future<R> Function(TerminalsService service, P params) run,
    ) => registerTypedMethod<P, R>(
      _peer,
      method,
      decodeParams: decode,
      encodeResult: encode,
      handler: (params) {
        _requireHandshake();
        return run(_requireTerminals(), params);
      },
    );
    terminal<TerminalScope, TerminalServers>(
      ConduitMethods.terminalServers,
      TerminalScope.fromJson,
      (r) => r.toJson(),
      (s, p) => s.servers(p.scopeId),
    );
    terminal<TerminalSelect, TerminalServers>(
      ConduitMethods.terminalSelect,
      TerminalSelect.fromJson,
      (r) => r.toJson(),
      (s, p) => s.select(p.serverId),
    );
    terminal<TerminalAttach, TerminalAttached>(
      ConduitMethods.terminalAttach,
      TerminalAttach.fromJson,
      (r) => r.toJson(),
      (s, p) => s.attach(p),
    );
    terminal<TerminalPath, TerminalListing>(
      ConduitMethods.terminalList,
      TerminalPath.fromJson,
      (r) => r.toJson(),
      (s, p) => s.list(p),
    );
    terminal<TerminalPath, TerminalFileContent>(
      ConduitMethods.terminalRead,
      TerminalPath.fromJson,
      (r) => r.toJson(),
      (s, p) => s.read(p),
    );
    terminal<TerminalPath, TerminalFileContent>(
      ConduitMethods.terminalDownload,
      TerminalPath.fromJson,
      (r) => r.toJson(),
      (s, p) => s.download(p),
    );
    terminal<TerminalFileAction, void>(
      ConduitMethods.terminalFileAction,
      TerminalFileAction.fromJson,
      (_) => <String, dynamic>{'ok': true},
      (s, p) => s.fileAction(p),
    );
    terminal<TerminalHandleRef, TerminalPorts>(
      ConduitMethods.terminalPorts,
      TerminalHandleRef.fromJson,
      (r) => r.toJson(),
      (s, p) => s.ports(p.handle),
    );
    terminal<TerminalPortRef, TerminalPreview>(
      ConduitMethods.terminalPreviewPort,
      TerminalPortRef.fromJson,
      (r) => r.toJson(),
      (s, p) => s.previewPort(p),
    );

    // workspace.* (M6).
    void workspace<P, R>(
      String method,
      P Function(Map<String, dynamic>) decode,
      Map<String, dynamic> Function(R) encode,
      Future<R> Function(WorkspaceService service, P params) run,
    ) => registerTypedMethod<P, R>(
      _peer,
      method,
      decodeParams: decode,
      encodeResult: encode,
      handler: (params) {
        _requireHandshake();
        return run(_requireWorkspace(), params);
      },
    );
    Map<String, dynamic> ok(void _) => <String, dynamic>{'ok': true};

    registerTypedMethodNoParams<WorkspaceAccess>(
      _peer,
      ConduitMethods.workspaceCapabilities,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireWorkspace().capabilities();
      },
    );
    registerTypedMethodNoParams<WorkspaceModelOptions>(
      _peer,
      ConduitMethods.workspaceModelOptions,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireWorkspace().modelOptions();
      },
    );
    workspace<WorkspaceQuery, WorkspacePage>(
      ConduitMethods.workspaceList,
      WorkspaceQuery.fromJson,
      (r) => r.toJson(),
      (s, p) => s.list(p),
    );
    workspace<WorkspaceRef, WorkspaceDetail>(
      ConduitMethods.workspaceGet,
      WorkspaceRef.fromJson,
      (r) => r.toJson(),
      (s, p) => s.get(p),
    );
    workspace<WorkspaceSave, WorkspaceDetail>(
      ConduitMethods.workspaceSave,
      WorkspaceSave.fromJson,
      (r) => r.toJson(),
      (s, p) => s.save(p),
    );
    workspace<WorkspaceRef, void>(
      ConduitMethods.workspaceDelete,
      WorkspaceRef.fromJson,
      ok,
      (s, p) => s.delete(p),
    );
    workspace<WorkspaceRef, WorkspaceItem>(
      ConduitMethods.workspaceToggle,
      WorkspaceRef.fromJson,
      (r) => r.toJson(),
      (s, p) => s.toggle(p),
    );
    workspace<WorkspaceAccessEdit, WorkspaceDetail>(
      ConduitMethods.workspaceSetAccess,
      WorkspaceAccessEdit.fromJson,
      (r) => r.toJson(),
      (s, p) => s.setAccess(p),
    );
    workspace<WorkspacePrincipalQuery, WorkspacePrincipals>(
      ConduitMethods.workspacePrincipals,
      WorkspacePrincipalQuery.fromJson,
      (r) => r.toJson(),
      (s, p) => s.principals(p),
    );
    workspace<WorkspaceExportQuery, WorkspaceExportFile>(
      ConduitMethods.workspaceExport,
      WorkspaceExportQuery.fromJson,
      (r) => r.toJson(),
      (s, p) => s.export(p),
    );
    workspace<WorkspaceImport, WorkspaceImportResult>(
      ConduitMethods.workspaceImport,
      WorkspaceImport.fromJson,
      (r) => r.toJson(),
      (s, p) => s.import(p),
    );
    workspace<WorkspaceRef, WorkspacePromptHistory>(
      ConduitMethods.workspacePromptHistory,
      WorkspaceRef.fromJson,
      (r) => r.toJson(),
      (s, p) => s.promptHistory(p.id),
    );
    workspace<WorkspacePromptDiffQuery, WorkspacePromptDiff>(
      ConduitMethods.workspacePromptDiff,
      WorkspacePromptDiffQuery.fromJson,
      (r) => r.toJson(),
      (s, p) => s.promptDiff(p),
    );
    workspace<WorkspacePromptVersionRef, WorkspaceDetail>(
      ConduitMethods.workspacePromptSetVersion,
      WorkspacePromptVersionRef.fromJson,
      (r) => r.toJson(),
      (s, p) => s.promptSetVersion(p),
    );
    workspace<WorkspacePromptVersionRef, void>(
      ConduitMethods.workspacePromptDeleteVersion,
      WorkspacePromptVersionRef.fromJson,
      ok,
      (s, p) => s.promptDeleteVersion(p),
    );
    workspace<WorkspaceValvesQuery, WorkspaceValves>(
      ConduitMethods.workspaceValves,
      WorkspaceValvesQuery.fromJson,
      (r) => r.toJson(),
      (s, p) => s.valves(p),
    );
    workspace<WorkspaceValves, WorkspaceValves>(
      ConduitMethods.workspaceSaveValves,
      WorkspaceValves.fromJson,
      (r) => r.toJson(),
      (s, p) => s.saveValves(p),
    );
    workspace<WorkspaceUrl, WorkspaceToolDto>(
      ConduitMethods.workspaceToolFromUrl,
      WorkspaceUrl.fromJson,
      (r) => r.toJson(),
      (s, p) => s.toolFromUrl(p.url),
    );
    workspace<WorkspaceFilesQuery, WorkspaceFiles>(
      ConduitMethods.workspaceFiles,
      WorkspaceFilesQuery.fromJson,
      (r) => r.toJson(),
      (s, p) => s.files(p),
    );
    workspace<WorkspaceFilesAttach, WorkspaceFiles>(
      ConduitMethods.workspaceAttachFiles,
      WorkspaceFilesAttach.fromJson,
      (r) => r.toJson(),
      (s, p) => s.attachFiles(p),
    );
    workspace<WorkspaceFileAction, WorkspaceFiles>(
      ConduitMethods.workspaceFileAction,
      WorkspaceFileAction.fromJson,
      (r) => r.toJson(),
      (s, p) => s.fileAction(p),
    );
    workspace<WorkspaceDirectoryAction, WorkspaceFiles>(
      ConduitMethods.workspaceDirectoryAction,
      WorkspaceDirectoryAction.fromJson,
      (r) => r.toJson(),
      (s, p) => s.directoryAction(p),
    );
    workspace<WorkspaceRef, WorkspaceDetail>(
      ConduitMethods.workspaceKnowledgeReset,
      WorkspaceRef.fromJson,
      (r) => r.toJson(),
      (s, p) => s.knowledgeReset(p.id),
    );
    workspace<WorkspaceRef, WorkspaceFiles>(
      ConduitMethods.workspaceKnowledgeCleanup,
      WorkspaceRef.fromJson,
      (r) => r.toJson(),
      (s, p) => s.knowledgeCleanup(p.id),
    );

    registerTypedMethod<NoteQuery, NoteList>(
      _peer,
      ConduitMethods.notesList,
      decodeParams: NoteQuery.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireNotes().list(request.query);
      },
    );

    registerTypedMethod<NoteRef, Map<String, dynamic>>(
      _peer,
      ConduitMethods.notesGet,
      decodeParams: NoteRef.fromJson,
      encodeResult: (result) => result,
      handler: (ref) async {
        _requireHandshake();
        // Wrapped, as `chats.get` is: a note deleted elsewhere is null,
        // not an error.
        final note = await _requireNotes().get(ref.id);
        return <String, dynamic>{'note': note?.toJson()};
      },
    );

    registerTypedMethod<NoteSave, NoteDetail>(
      _peer,
      ConduitMethods.notesSave,
      decodeParams: NoteSave.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireNotes().save(request);
      },
    );

    registerTypedMethod<NoteRef, Map<String, dynamic>>(
      _peer,
      ConduitMethods.notesDelete,
      decodeParams: NoteRef.fromJson,
      encodeResult: (result) => result,
      handler: (ref) async {
        _requireHandshake();
        await _requireNotes().delete(ref.id);
        return <String, dynamic>{'deleted': true};
      },
    );

    registerTypedMethod<NoteAi, NoteTitle>(
      _peer,
      ConduitMethods.notesGenerateTitle,
      decodeParams: NoteAi.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireNotes().generateTitle(request);
      },
    );

    registerTypedMethod<NoteAi, NoteBody>(
      _peer,
      ConduitMethods.notesEnhance,
      decodeParams: NoteAi.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireNotes().enhance(request);
      },
    );

    registerTypedMethod<NoteAttach, NoteDetail>(
      _peer,
      ConduitMethods.notesAttach,
      decodeParams: NoteAttach.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireNotes().attach(request);
      },
    );

    registerTypedMethod<NoteDetach, NoteDetail>(
      _peer,
      ConduitMethods.notesDetach,
      decodeParams: NoteDetach.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireNotes().detach(request);
      },
    );

    registerTypedMethod<NotePin, NoteSummary>(
      _peer,
      ConduitMethods.notesSetPinned,
      decodeParams: NotePin.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireNotes().setPinned(request.id, pinned: request.pinned);
      },
    );

    registerTypedMethodNoParams<McpServerList>(
      _peer,
      ConduitMethods.mcpList,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireMcp().list();
      },
    );

    registerTypedMethod<McpServerEdit, McpServerList>(
      _peer,
      ConduitMethods.mcpSave,
      decodeParams: McpServerEdit.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (edit) {
        _requireHandshake();
        return _requireMcp().save(edit);
      },
    );

    registerTypedMethod<McpRef, McpServerList>(
      _peer,
      ConduitMethods.mcpRemove,
      decodeParams: McpRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireMcp().remove(ref.id);
      },
    );

    registerTypedMethod<McpEnable, McpServerList>(
      _peer,
      ConduitMethods.mcpSetEnabled,
      decodeParams: McpEnable.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireMcp().setEnabled(request.id, request.enabled);
      },
    );

    registerTypedMethod<McpServerEdit, McpTestResult>(
      _peer,
      ConduitMethods.mcpTest,
      decodeParams: McpServerEdit.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (edit) {
        _requireHandshake();
        return _requireMcp().test(edit);
      },
    );

    registerTypedMethod<McpRef, McpServerList>(
      _peer,
      ConduitMethods.mcpConnect,
      decodeParams: McpRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireMcp().connect(ref.id);
      },
    );

    registerTypedMethod<McpRef, Map<String, dynamic>>(
      _peer,
      ConduitMethods.mcpCancelConnect,
      decodeParams: McpRef.fromJson,
      encodeResult: (result) => result,
      handler: (ref) async {
        _requireHandshake();
        await _requireMcp().cancelConnect(ref.id);
        return <String, dynamic>{'cancelled': true};
      },
    );

    registerTypedMethod<McpRef, McpServerList>(
      _peer,
      ConduitMethods.mcpDisconnect,
      decodeParams: McpRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireMcp().disconnect(ref.id);
      },
    );

    registerTypedMethod<McpForgetApproval, McpServerList>(
      _peer,
      ConduitMethods.mcpForgetApproval,
      decodeParams: McpForgetApproval.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireMcp().forgetApproval(request);
      },
    );

    registerTypedMethod<McpRef, McpContent>(
      _peer,
      ConduitMethods.mcpContent,
      decodeParams: McpRef.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (ref) {
        _requireHandshake();
        return _requireMcp().content(ref.id);
      },
    );

    registerTypedMethod<McpGetPrompt, McpContentPreview>(
      _peer,
      ConduitMethods.mcpGetPrompt,
      decodeParams: McpGetPrompt.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireMcp().getPrompt(request);
      },
    );

    registerTypedMethod<McpReadResource, McpContentPreview>(
      _peer,
      ConduitMethods.mcpReadResource,
      decodeParams: McpReadResource.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireMcp().readResource(request);
      },
    );

    registerTypedMethodNoParams<PromptList>(
      _peer,
      ConduitMethods.promptsList,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requirePrompts().list();
      },
    );

    registerTypedMethod<RenderPrompt, RenderedPrompt>(
      _peer,
      ConduitMethods.promptsRender,
      decodeParams: RenderPrompt.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requirePrompts().render(request);
      },
    );

    registerTypedMethodNoParams<ModelList>(
      _peer,
      ConduitMethods.modelsList,
      encodeResult: (result) => result.toJson(),
      handler: () {
        _requireHandshake();
        return _requireModels().list();
      },
    );

    registerTypedMethod<SelectModel, ModelList>(
      _peer,
      ConduitMethods.modelsSelect,
      decodeParams: SelectModel.fromJson,
      encodeResult: (result) => result.toJson(),
      handler: (request) {
        _requireHandshake();
        return _requireModels().select(request.id);
      },
    );
  }

  ChannelsService _requireChannels() =>
      _channels ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  TerminalsService _requireTerminals() =>
      _terminals ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  WorkspaceService _requireWorkspace() =>
      _workspace ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  NotesService _requireNotes() =>
      _notes ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  McpService _requireMcp() =>
      _mcp ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  DirectService _requireDirect() =>
      _direct ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  PromptsService _requirePrompts() =>
      _prompts ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  ModelsService _requireModels() =>
      _models ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  TurnsService _requireTurns() =>
      _turns ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  ChatsService _requireChats() =>
      _chats ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  SettingsService _requireSettings() =>
      _settings ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  ServersService _requireServers() =>
      _servers ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  AuthService _requireAuth() =>
      _auth ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  void _requireHandshake() {
    if (_handshake == null) {
      throw const RpcError(
        code: ConduitErrorCodes.protocolViolation,
        debugMessage: 'system.handshake must be the first call on a session',
      );
    }
  }
}
