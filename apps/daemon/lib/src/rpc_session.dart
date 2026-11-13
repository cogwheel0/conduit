import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';

import 'accounts_service.dart';
import 'auth_service.dart';
import 'chat_prompts_service.dart';
import 'chats_service.dart';
import 'composer_service.dart';
import 'drafts_service.dart';
import 'direct_service.dart';
import 'mcp_apps_service.dart';
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
import 'valves_service.dart';
import 'ui_requests_service.dart';
import 'workspace_service.dart';
import 'terminals_service.dart';
import 'handoff_service.dart';
import 'hermes_service.dart';
import 'voice_service.dart';
import 'core_settings_service.dart';
import 'data_service.dart';
import 'access_service.dart';
import 'chat_settings_service.dart';
import 'folder_settings_service.dart';
import 'memories_service.dart';
import 'profile_service.dart';
import 'release_notes_rpc_service.dart';

/// The services that need the core. The daemon swaps in a full set when the
/// core attaches; until then every one is null.
final class CoreServices {
  const CoreServices({
    this.accounts,
    this.servers,
    this.auth,
    this.settings,
    this.chats,
    this.turns,
    this.models,
    this.uiRequests,
    this.chatPrompts,
    this.mcpApps,
    this.composer,
    this.prompts,
    this.direct,
    this.mcp,
    this.notes,
    this.channels,
    this.workspace,
    this.terminals,
    this.hermes,
    this.voice,
    this.coreSettings,
    this.profile,
    this.memories,
    this.releaseNotes,
    this.data,
    this.drafts,
    this.chatSettings,
    this.valves,
    this.access,
    this.folderSettings,
    this.handoff,
  });

  final AccountsService? accounts;
  final ServersService? servers;
  final AuthService? auth;
  final SettingsService? settings;
  final ChatsService? chats;
  final TurnsService? turns;
  final ModelsService? models;
  final UiRequestsService? uiRequests;
  final ChatPromptsService? chatPrompts;
  final McpAppsService? mcpApps;
  final ComposerService? composer;
  final PromptsService? prompts;
  final DirectService? direct;
  final McpService? mcp;
  final NotesService? notes;
  final ChannelsService? channels;
  final WorkspaceService? workspace;
  final TerminalsService? terminals;
  final HermesService? hermes;
  final VoiceService? voice;

  /// The rest of `settings.*` (core's `AppSettings` and the account's own).
  final CoreSettingsService? coreSettings;
  final ProfileService? profile;
  final MemoriesService? memories;
  final ReleaseNotesRpcService? releaseNotes;
  final DataService? data;
  final DraftsService? drafts;
  final ChatSettingsService? chatSettings;
  final ValvesService? valves;
  final AccessService? access;
  final FolderSettingsService? folderSettings;

  /// A server's `chat:handoff`, put to the windows.
  final HandoffService? handoff;
}

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
    required CoreServices Function() services,
    void Function(bool online)? reportNetwork,
  }) : _events = events,
       _reportNetwork = reportNetwork,
       _log = log,
       _services = services,
       _system = system,
       _peer = json_rpc.Peer(channel) {
    _register();
  }

  final String sessionId;
  final EventBus _events;
  final DaemonLog _log;
  final SystemService _system;

  /// The daemon's services as they are now: null until the core is up. A
  /// session can exist before then -- the window opens while the daemon is
  /// still restoring state -- and answering `servers.list` with an empty
  /// list in that window would look to the UI like a fresh install. It gets
  /// `rpc.daemonUnavailable` instead, and the real services once the core
  /// attaches, without reconnecting.
  final CoreServices Function() _services;
  AccountsService? get _accounts => _services().accounts;
  ServersService? get _servers => _services().servers;
  AuthService? get _auth => _services().auth;
  SettingsService? get _settings => _services().settings;
  ChatsService? get _chats => _services().chats;
  TurnsService? get _turns => _services().turns;
  ModelsService? get _models => _services().models;
  final json_rpc.Peer _peer;

  /// Set by a successful `system.handshake`. Until then every other method is
  /// refused, so a client cannot skip version negotiation and then be
  /// surprised by a payload it cannot parse.
  HandshakeRequest? _handshake;

  bool get isHandshakeComplete => _handshake != null;

  /// Questions from the core, shared by every window. Null until the core
  /// is attached, when there is nothing to ask yet.
  UiRequestsService? get _uiRequests => _services().uiRequests;
  ComposerService? get _composer => _services().composer;
  DraftsService? get _drafts => _services().drafts;
  PromptsService? get _prompts => _services().prompts;
  DirectService? get _direct => _services().direct;
  McpService? get _mcp => _services().mcp;
  NotesService? get _notes => _services().notes;
  ChannelsService? get _channels => _services().channels;
  WorkspaceService? get _workspace => _services().workspace;
  TerminalsService? get _terminals => _services().terminals;
  HermesService? get _hermes => _services().hermes;
  VoiceService? get _voice => _services().voice;
  CoreSettingsService? get _coreSettings => _services().coreSettings;
  ProfileService? get _profile => _services().profile;
  MemoriesService? get _memories => _services().memories;
  ChatPromptsService? get _chatPrompts => _services().chatPrompts;
  McpAppsService? get _mcpApps => _services().mcpApps;
  ReleaseNotesRpcService? get _releaseNotes => _services().releaseNotes;
  DataService? get _data => _services().data;
  ChatSettingsService? get _chatSettings => _services().chatSettings;
  ValvesService? get _valves => _services().valves;
  AccessService? get _access => _services().access;
  FolderSettingsService? get _folderSettings => _services().folderSettings;
  HandoffService? get _handoff => _services().handoff;

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
    _handoff?.onWindowsChanged();
    await _peer.close();
  }

  /// Every method this session answers, with the spec it was registered
  /// from. The daemon's tests hold it equal to [ConduitMethodSpecs.all].
  Map<String, ConduitMethodSpec<Object?, Object?>> get registeredMethods =>
      Map<String, ConduitMethodSpec<Object?, Object?>>.unmodifiable(
        _registered,
      );
  final Map<String, ConduitMethodSpec<Object?, Object?>> _registered =
      <String, ConduitMethodSpec<Object?, Object?>>{};

  /// Registers [handler] for [spec]'s method: the only way this session
  /// adds one, so every method it answers decodes its params, and encodes
  /// its result, as the protocol's tables say. Every method but the
  /// handshake needs the handshake first.
  void _on<P, R>(
    ConduitMethodSpec<P, R> spec,
    FutureOr<R> Function(P params) handler, {
    bool beforeHandshake = false,
  }) {
    if (_registered.containsKey(spec.name)) {
      throw StateError('${spec.name} is registered twice');
    }
    _registered[spec.name] = spec;
    registerSpecMethod<P, R>(_peer, spec, (params) {
      if (!beforeHandshake) _requireHandshake();
      return handler(params);
    });
  }

  void _register() {
    _events.attach(sessionId, (envelope) {
      // A closed peer still sitting in the bus is a bug, but dropping the
      // event is better than tearing down every other window's fan-out.
      if (_peer.isClosed) return;
      sendEvent(_peer, envelope);
    });

    _on(ConduitMethodSpecs.systemHandshake, beforeHandshake: true, (request) {
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
    });

    _on(ConduitMethodSpecs.systemPing, (_) => _system.ping());
    _on(ConduitMethodSpecs.systemCapabilities, (_) => _system.capabilities);
    _on(ConduitMethodSpecs.systemShutdown, (_) => _system.shutdown());
    _on(
      ConduitMethodSpecs.systemExportDiagnostics,
      (_) => _system.exportDiagnostics(),
    );

    _on(ConduitMethodSpecs.systemNetwork, (report) {
      _reportNetwork?.call(report.online);
      return const OkResult(ok: true);
    });

    _on(ConduitMethodSpecs.eventsSubscribe, (subscription) {
      for (final event in subscription.events) {
        if (!ConduitEvents.all.contains(event)) {
          throw RpcError(
            code: ConduitErrorCodes.invalidParams,
            args: <String, String>{'event': event},
            debugMessage: 'unknown event name "$event"',
          );
        }
      }
      final previous = _events.subscribe(sessionId, subscription);
      // A window that opens while a question is waiting sees it too.
      // Otherwise a tool approval asked before the window existed could
      // only be answered by one that no longer does.
      for (final request in _uiRequests?.pending ?? const <UiRequest>[]) {
        _events.emitTo(sessionId, ConduitEventSpecs.uiRequest, request);
      }
      for (final request in _handoff?.pending ?? const <HandoffRequest>[]) {
        _events.emitTo(sessionId, ConduitEventSpecs.handoffRequested, request);
      }
      // And a chat already answering, or one whose answer finished before
      // the window could listen: see [TurnsService.catchUp].
      _turns?.catchUp(sessionId, subscription, alreadySubscribed: previous);
      // Echo the accepted filter back so the client can assert on what the
      // daemon actually stored rather than on what it hoped it sent.
      return subscription;
    });

    _on(ConduitMethodSpecs.uiRespond, (response) {
      final accepted = _uiRequests?.respond(response) ?? false;
      if (!accepted) {
        // Late or duplicate answer — the request already timed out or
        // another window answered first. Not an error worth surfacing.
        _log.debug(
          'session $sessionId: ui.respond for unknown request '
          '${response.requestId}',
        );
      }
      return AcceptedResult(accepted: accepted);
    });

    _registerAccounts();
    _registerServers();
    _registerAuth();
    _registerSettings();
    _registerProfile();
    _registerReleaseNotesAndData();
    _registerChats();
    _registerTurns();
    _registerModels();

    _peer.registerFallback((json_rpc.Parameters params) {
      final method = params.method;
      throw RpcError(
        code: ConduitMethods.isReserved(method)
            // A reserved namespace that is not wired up yet is a feature
            // that has not landed, which is worth telling apart from a typo.
            ? ConduitErrorCodes.unsupported
            : ConduitErrorCodes.methodNotFound,
        args: <String, String>{'method': method},
      ).toException();
    });
  }

  void _registerAccounts() {
    _on(ConduitMethodSpecs.accountsList, (_) => _requireAccounts().list());
    _on(ConduitMethodSpecs.accountsAdd, (r) => _requireAccounts().add(r));
    _on(
      ConduitMethodSpecs.accountsCancelAdd,
      (_) => _requireAccounts().cancelAdd(),
    );
    _on(
      ConduitMethodSpecs.accountsSwitch,
      (r) => _requireAccounts().switchTo(r),
    );
    _on(ConduitMethodSpecs.accountsRemove, (r) => _requireAccounts().remove(r));
    _on(
      ConduitMethodSpecs.accountsSignOut,
      (r) => _requireAccounts().signOut(r),
    );
  }

  void _registerServers() {
    _on(ConduitMethodSpecs.serversUpdate, (d) => _requireServers().update(d));
    _on(ConduitMethodSpecs.serversStatus, (_) => _requireServers().status());
  }

  void _registerAuth() {
    _on(ConduitMethodSpecs.authStatus, (_) => _requireAuth().status());
    _on(
      ConduitMethodSpecs.authLoginWithPassword,
      (p) => _requireAuth().loginWithPassword(p),
    );
    _on(
      ConduitMethodSpecs.authLoginWithLdap,
      (p) => _requireAuth().loginWithLdap(p),
    );
    _on(
      ConduitMethodSpecs.authLoginWithApiKey,
      (p) => _requireAuth().loginWithApiKey(p),
    );
    _on(
      ConduitMethodSpecs.authSilentLogin,
      (_) => _requireAuth().silentLogin(),
    );
    _on(
      ConduitMethodSpecs.authCompleteExternal,
      (p) => _requireAuth().completeExternal(p),
    );
    _on(
      ConduitMethodSpecs.authHasSavedCredentials,
      (_) async => SavedCredentialsResult(
        hasSavedCredentials: await _requireAuth().hasSavedCredentials(),
      ),
    );
    _on(
      ConduitMethodSpecs.authSetReviewerMode,
      (p) => _requireAuth().setReviewerMode(enabled: p.enabled),
    );
  }

  void _registerSettings() {
    _on(ConduitMethodSpecs.settingsGetApp, (_) => _requireSettings().read());
    _on(
      ConduitMethodSpecs.settingsSetApp,
      (patch) => _requireSettings().write(patch),
    );
    _on(ConduitMethodSpecs.settingsGet, (_) => _need(_coreSettings).get());
    _on(ConduitMethodSpecs.settingsSet, (p) => _need(_coreSettings).set(p));
    _on(
      ConduitMethodSpecs.settingsGetAccount,
      (_) => _need(_coreSettings).getAccount(),
    );
    _on(
      ConduitMethodSpecs.settingsSetAccount,
      (p) => _need(_coreSettings).setAccount(p),
    );
    _on(
      ConduitMethodSpecs.settingsModelPrompt,
      (p) => _need(_coreSettings).modelPrompt(p),
    );
    _on(
      ConduitMethodSpecs.settingsSetModelPrompt,
      (p) => _need(_coreSettings).setModelPrompt(p),
    );
    _on(
      ConduitMethodSpecs.settingsQuickPills,
      (_) => _need(_coreSettings).quickPills(),
    );
    _on(
      ConduitMethodSpecs.settingsVoiceProviders,
      (_) => _need(_coreSettings).voiceProviders(),
    );
    _on(ConduitMethodSpecs.settingsAbout, (_) => _need(_coreSettings).about());
  }

  void _registerProfile() {
    _on(ConduitMethodSpecs.profileGet, (_) => _need(_profile).get());
    _on(ConduitMethodSpecs.profileUpdate, (p) => _need(_profile).update(p));
    _on(ConduitMethodSpecs.profileSetImage, (p) => _need(_profile).setImage(p));
    _on(
      ConduitMethodSpecs.profileRemoveImage,
      (_) => _need(_profile).removeImage(),
    );
    _on(
      ConduitMethodSpecs.profileChangePassword,
      (p) => _need(_profile).changePassword(p),
    );
    _on(
      ConduitMethodSpecs.profileSignOutAll,
      (p) => _need(_profile).signOutAll(p),
    );
    _on(ConduitMethodSpecs.memoriesList, (_) => _need(_memories).list());
    _on(ConduitMethodSpecs.memoriesAdd, (p) => _need(_memories).add(p));
    _on(ConduitMethodSpecs.memoriesUpdate, (p) => _need(_memories).update(p));
    _on(ConduitMethodSpecs.memoriesDelete, (p) => _need(_memories).delete(p));
    _on(ConduitMethodSpecs.memoriesClear, (_) => _need(_memories).clear());
    _on(
      ConduitMethodSpecs.memoriesSetEnabled,
      (p) => _need(_memories).setEnabled(p),
    );
  }

  void _registerReleaseNotesAndData() {
    _on(
      ConduitMethodSpecs.releaseNotesCheck,
      (q) => _need(_releaseNotes).check(q),
    );
    _on(
      ConduitMethodSpecs.releaseNotesLatest,
      (q) => _need(_releaseNotes).latest(q),
    );
    _on(
      ConduitMethodSpecs.releaseNotesDismiss,
      (_) => _need(_releaseNotes).dismiss(),
    );
    // A window's Delete All answers to the summary that window was shown.
    _on(
      ConduitMethodSpecs.dataSummary,
      (_) => _need(_data).summary(caller: this),
    );
    _on(ConduitMethodSpecs.dataSync, (_) => _need(_data).sync(caller: this));
    _on(ConduitMethodSpecs.dataExport, (r) => _need(_data).export(r));
    _on(
      ConduitMethodSpecs.dataPreviewImport,
      (r) => _need(_data).previewImport(r),
    );
    _on(ConduitMethodSpecs.dataImport, (r) => _need(_data).import(r));
    _on(ConduitMethodSpecs.dataArchiveAll, (_) => _need(_data).archiveAll());
    _on(
      ConduitMethodSpecs.dataUnarchiveAll,
      (_) => _need(_data).unarchiveAll(),
    );
    _on(ConduitMethodSpecs.dataUnshareAll, (_) => _need(_data).unshareAll());
    _on(
      ConduitMethodSpecs.dataDeleteAll,
      (r) => _need(_data).deleteAll(r, caller: this),
    );
    _on(ConduitMethodSpecs.dataConnection, (_) => _need(_data).connection());
  }

  /// [service], or `rpc.daemonUnavailable` while the core is coming up.
  static T _need<T extends Object>(T? service) =>
      service ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  void _registerChats() {
    _on(ConduitMethodSpecs.chatsList, (_) => _requireChats().list());
    _on(ConduitMethodSpecs.chatsLoadMore, (_) => _requireChats().loadMore());

    // A null chat travels as data rather than as an error: opening a chat
    // that was deleted on another device is ordinary.
    _on(
      ConduitMethodSpecs.chatsGet,
      (ref) async => ChatResult(chat: await _requireChats().get(ref.id)),
    );
    _on(
      ConduitMethodSpecs.chatsRename,
      (r) => _requireChats().rename(r.id, r.title),
    );
    _on(
      ConduitMethodSpecs.chatsSetPinned,
      (r) => _requireChats().setPinned(r.id, value: r.value),
    );
    _on(
      ConduitMethodSpecs.chatsSetArchived,
      (r) => _requireChats().setArchived(r.id, value: r.value),
    );
    _on(
      ConduitMethodSpecs.chatsDelete,
      (ref) => _requireChats().delete(ref.id),
    );
    _on(ConduitMethodSpecs.syncGet, (_) => _requireChats().syncState());
    _on(
      ConduitMethodSpecs.chatsSetArchivedVisible,
      (r) => _requireChats().setArchivedVisible(visible: r.visible),
    );
    _on(ConduitMethodSpecs.chatsShare, (r) => _requireChats().share(r));
    _on(ConduitMethodSpecs.chatsFork, (r) => _requireChats().fork(r));
    _on(ConduitMethodSpecs.chatsExport, (r) => _requireChats().export(r));
    _on(
      ConduitMethodSpecs.chatsGenerateTitle,
      (r) => _requireChats().generateTitle(r.id),
    );
    _on(
      ConduitMethodSpecs.chatsMarkUnread,
      (r) => _requireChats().markUnread(r),
    );
    _on(
      ConduitMethodSpecs.chatsSaveTemporary,
      (r) => _requireTurns().saveTemporary(r.id),
    );
    // The count from the chat's scope, then the chat as it is afterwards.
    _on(ConduitMethodSpecs.messagesDelete, (r) async {
      final count = await _requireTurns().deleteMessages(r);
      if (r.dryRun) return MessagesDeleted(count: count);
      return MessagesDeleted(
        count: count,
        chat: await _requireChats().get(r.chatId),
      );
    });
    _on(
      ConduitMethodSpecs.chatsUnshare,
      (ref) => _requireChats().unshare(ref.id),
    );
    _on(ConduitMethodSpecs.chatsBulk, (r) => _requireChats().bulk(r));
    _on(
      ConduitMethodSpecs.chatsSetSystemPrompt,
      (r) async => ChatResult(chat: await _requireChats().setSystemPrompt(r)),
    );
    _on(ConduitMethodSpecs.chatsTree, (r) => _requireChats().tree(r.id));
    _on(
      ConduitMethodSpecs.chatsSetCurrent,
      (r) async => ChatResult(chat: await _requireChats().setCurrent(r)),
    );
    _on(
      ConduitMethodSpecs.chatsFolder,
      (r) => _requireChats().folder(r.folderId),
    );
    _on(ConduitMethodSpecs.chatsMove, (r) => _requireChats().move(r));
    _on(
      ConduitMethodSpecs.foldersCreate,
      (r) => _requireChats().createFolder(r),
    );
    _on(
      ConduitMethodSpecs.foldersRename,
      (r) => _requireChats().renameFolder(r),
    );
    _on(
      ConduitMethodSpecs.foldersDelete,
      (r) => _requireChats().deleteFolder(r.folderId),
    );
    _on(
      ConduitMethodSpecs.foldersGet,
      (r) => _need(_folderSettings).get(r.folderId),
    );
    _on(
      ConduitMethodSpecs.foldersUpdate,
      (r) => _need(_folderSettings).update(r),
    );
    _on(
      ConduitMethodSpecs.foldersDraftModel,
      (r) => _need(_folderSettings).draftModel(r.folderId),
    );
    _on(ConduitMethodSpecs.chatsTagsAll, (_) => _requireChats().allTags());
    _on(ConduitMethodSpecs.chatsTagsAdd, (r) => _requireChats().addTag(r));
    _on(
      ConduitMethodSpecs.chatsTagsRemove,
      (r) => _requireChats().removeTag(r),
    );
    _on(ConduitMethodSpecs.chatsSearch, (q) => _requireChats().search(q));
  }

  void _registerTurns() {
    _on(ConduitMethodSpecs.turnsSend, (r) => _requireTurns().send(r));
    _on(
      ConduitMethodSpecs.turnsRegenerate,
      (r) => _requireTurns().regenerate(r),
    );
    _on(ConduitMethodSpecs.turnsEdit, (r) => _requireTurns().edit(r));
    _on(ConduitMethodSpecs.turnsRate, (r) async {
      await _requireTurns().rate(r);
      return const RatedResult(rated: true);
    });
    _on(ConduitMethodSpecs.turnsStop, (r) async {
      await _requireTurns().stop(r.chatId);
      return const StoppedResult(stopped: true);
    });
    _on(ConduitMethodSpecs.turnsSteer, (r) => _requireTurns().steer(r));
    _on(ConduitMethodSpecs.turnsMerge, (r) => _requireTurns().merge(r));
    _on(ConduitMethodSpecs.handoffAnswer, (r) async {
      final handoff = _handoff;
      if (handoff == null) return const HandoffAnswered(open: false);
      return handoff.answer(r);
    });

    _on(
      ConduitMethodSpecs.turnsRetryQueued,
      (r) => _requireTurns().retryQueued(r),
    );
    _on(
      ConduitMethodSpecs.turnsRemoveQueued,
      (r) => _requireTurns().removeQueued(r),
    );

    // chatPrompts.*: Open WebUI's questions and approvals in a chat.
    _on(ConduitMethodSpecs.chatPromptsGet, (r) => _need(_chatPrompts).get(r));
    _on(
      ConduitMethodSpecs.chatPromptsAnswer,
      (r) => _need(_chatPrompts).answer(r),
    );
    _on(
      ConduitMethodSpecs.chatPromptsDecide,
      (r) => _need(_chatPrompts).decide(r),
    );

    // mcpApps.*: MCP Apps in Open WebUI chats, hosted here.
    _on(ConduitMethodSpecs.mcpAppsOpen, (r) => _need(_mcpApps).open(r));
    _on(ConduitMethodSpecs.mcpAppsMessage, (r) => _need(_mcpApps).message(r));
    _on(
      ConduitMethodSpecs.mcpAppsContext,
      (r) async => _need(_mcpApps).context(r),
    );
    _on(
      ConduitMethodSpecs.mcpAppsClose,
      (r) async => _need(_mcpApps).close(r),
    );

    // queue.*: messages queued behind a running answer.
    _on(ConduitMethodSpecs.queueGet, (r) => _requireTurns().queueGet(r.id));
    _on(ConduitMethodSpecs.queueAdd, (r) => _requireTurns().queueAdd(r));
    _on(ConduitMethodSpecs.queueEdit, (r) => _requireTurns().queueEdit(r));
    _on(ConduitMethodSpecs.queueRemove, (r) => _requireTurns().queueRemove(r));
    _on(
      ConduitMethodSpecs.queueSendNow,
      (r) => _requireTurns().queueSendNow(r),
    );
    _on(ConduitMethodSpecs.queueRetry, (r) => _requireTurns().queueRetry(r.id));
  }

  void _registerModels() {
    _on(ConduitMethodSpecs.composerOptions, (_) {
      final composer = _composer;
      if (composer == null) {
        throw const RpcError(
          code: ConduitErrorCodes.daemonUnavailable,
          debugMessage: 'the core is not up yet',
        );
      }
      return composer.options();
    });
    // drafts.*, mentions.*, skills.*, context.*, files.*: what the composer
    // holds and draws on.
    _on(ConduitMethodSpecs.draftsGet, (r) => _requireDrafts().get(r));
    _on(ConduitMethodSpecs.draftsSave, (r) => _requireDrafts().save(r));
    _on(
      ConduitMethodSpecs.mentionsSearch,
      (r) => _requireComposer().mentions(r.query),
    );
    _on(
      ConduitMethodSpecs.skillsSearch,
      (r) => _requireComposer().skills(r.query),
    );
    _on(
      ConduitMethodSpecs.contextSearch,
      (r) => _requireComposer().context(r.query),
    );
    _on(
      ConduitMethodSpecs.contextFetchUrl,
      (r) => _requireComposer().fetchUrl(r.url),
    );
    _on(
      ConduitMethodSpecs.filesList,
      (r) => _requireComposer().serverFiles(r.query),
    );
    _on(ConduitMethodSpecs.composerKnowledge, (request) {
      final composer = _composer;
      if (composer == null) {
        throw const RpcError(
          code: ConduitErrorCodes.daemonUnavailable,
          debugMessage: 'the core is not up yet',
        );
      }
      return composer.knowledge(request.query);
    });

    // direct.*.
    _on(ConduitMethodSpecs.directList, (_) => _requireDirect().list());
    _on(ConduitMethodSpecs.directSave, (e) => _requireDirect().save(e));
    _on(
      ConduitMethodSpecs.directRemove,
      (ref) => _requireDirect().remove(ref.id),
    );
    _on(
      ConduitMethodSpecs.directSetEnabled,
      (r) => _requireDirect().setEnabled(r.id, r.enabled),
    );
    _on(ConduitMethodSpecs.directTest, (e) => _requireDirect().test(e));
    _on(
      ConduitMethodSpecs.directSetHistory,
      (r) => _requireDirect().setHistory(localOnly: r.localOnly),
    );
    _on(
      ConduitMethodSpecs.directSetPreferred,
      (r) => _requireDirect().setPreferred(preferred: r.preferred),
    );
    _on(
      ConduitMethodSpecs.directOllamaModels,
      (ref) => _requireDirect().ollamaModels(ref.id),
    );
    _on(
      ConduitMethodSpecs.directOllamaLoad,
      (a) => _requireDirect().ollamaLoad(a),
    );
    _on(
      ConduitMethodSpecs.directOllamaUnload,
      (a) => _requireDirect().ollamaUnload(a),
    );
    _on(
      ConduitMethodSpecs.directOllamaKeepAlive,
      (a) => _requireDirect().ollamaKeepAlive(a),
    );
    _on(
      ConduitMethodSpecs.directOllamaThinking,
      (a) => _requireDirect().ollamaThinking(a),
    );

    // channels.*.
    const ok = OkResult(ok: true);
    _on(ConduitMethodSpecs.channelsList, (_) => _requireChannels().list());
    _on(ConduitMethodSpecs.channelsSave, (e) => _requireChannels().save(e));
    _on(
      ConduitMethodSpecs.channelsDelete,
      (ref) => _requireChannels().delete(ref.id),
    );
    _on(
      ConduitMethodSpecs.channelsLeave,
      (ref) => _requireChannels().leave(ref.id),
    );
    _on(
      ConduitMethodSpecs.channelsMessages,
      (q) => _requireChannels().messages(q),
    );
    _on(ConduitMethodSpecs.channelsPost, (p) => _requireChannels().post(p));
    _on(
      ConduitMethodSpecs.channelsEditMessage,
      (e) => _requireChannels().editMessage(e),
    );
    _on(ConduitMethodSpecs.channelsDeleteMessage, (p) async {
      await _requireChannels().deleteMessage(p);
      return ok;
    });
    _on(ConduitMethodSpecs.channelsReact, (p) async {
      await _requireChannels().react(p);
      return ok;
    });
    _on(ConduitMethodSpecs.channelsPin, (p) async {
      await _requireChannels().pin(p);
      return ok;
    });
    _on(ConduitMethodSpecs.channelsTyping, (p) {
      _requireChannels().typing(p);
      return ok;
    });
    _on(ConduitMethodSpecs.channelsMarkRead, (ref) async {
      await _requireChannels().markRead(ref.id);
      return ok;
    });
    _on(
      ConduitMethodSpecs.channelsMembers,
      (ref) => _requireChannels().members(ref.id),
    );

    // hermes.*.
    _on(ConduitMethodSpecs.hermesSettings, (_) => _requireHermes().settings());
    _on(
      ConduitMethodSpecs.hermesSaveSettings,
      (p) => _requireHermes().saveSettings(p),
    );
    _on(ConduitMethodSpecs.hermesTest, (p) => _requireHermes().test(p));
    _on(ConduitMethodSpecs.hermesStatus, (_) => _requireHermes().status());
    _on(ConduitMethodSpecs.hermesSignIn, (_) => _requireHermes().signIn());
    _on(ConduitMethodSpecs.hermesSignOut, (_) => _requireHermes().signOut());
    _on(ConduitMethodSpecs.hermesSessions, (_) => _requireHermes().sessions());
    _on(
      ConduitMethodSpecs.hermesRenameSession,
      (p) => _requireHermes().rename(p),
    );
    _on(
      ConduitMethodSpecs.hermesDeleteSession,
      (p) => _requireHermes().delete(p.id),
    );
    _on(
      ConduitMethodSpecs.hermesForkSession,
      (p) => _requireHermes().fork(p.id),
    );
    _on(ConduitMethodSpecs.hermesJobs, (_) => _requireHermes().jobs());
    _on(ConduitMethodSpecs.hermesSaveJob, (p) => _requireHermes().saveJob(p));
    _on(
      ConduitMethodSpecs.hermesSetJobEnabled,
      (p) => _requireHermes().setJobEnabled(p),
    );
    _on(ConduitMethodSpecs.hermesRunJob, (p) => _requireHermes().runJob(p.id));
    _on(
      ConduitMethodSpecs.hermesDeleteJob,
      (p) => _requireHermes().deleteJob(p.id),
    );
    _on(ConduitMethodSpecs.hermesCatalog, (_) => _requireHermes().catalog());

    // voice.*.
    _on(ConduitMethodSpecs.voiceSettings, (_) => _requireVoice().settings());
    _on(ConduitMethodSpecs.voiceSaveSettings, (p) => _requireVoice().save(p));
    _on(ConduitMethodSpecs.voiceVoices, (_) => _requireVoice().voices());
    _on(ConduitMethodSpecs.voiceSpeak, (p) => _requireVoice().speak(p));
    _on(ConduitMethodSpecs.voiceModels, (_) => _requireVoice().models());
    _on(
      ConduitMethodSpecs.voiceDownloadModel,
      (p) => _requireVoice().downloadModel(p.id),
    );
    _on(
      ConduitMethodSpecs.voiceDeleteModel,
      (p) => _requireVoice().deleteModel(p.id),
    );

    // terminal.*.
    _on(
      ConduitMethodSpecs.terminalServers,
      (p) => _requireTerminals().servers(p.scopeId),
    );
    _on(
      ConduitMethodSpecs.terminalSelect,
      (p) => _requireTerminals().select(p.serverId),
    );
    _on(
      ConduitMethodSpecs.terminalAttach,
      (p) => _requireTerminals().attach(p),
    );
    _on(ConduitMethodSpecs.terminalList, (p) => _requireTerminals().list(p));
    _on(ConduitMethodSpecs.terminalRead, (p) => _requireTerminals().read(p));
    _on(
      ConduitMethodSpecs.terminalDownload,
      (p) => _requireTerminals().download(p),
    );
    _on(ConduitMethodSpecs.terminalFileAction, (p) async {
      await _requireTerminals().fileAction(p);
      return ok;
    });
    _on(
      ConduitMethodSpecs.terminalPorts,
      (p) => _requireTerminals().ports(p.handle),
    );
    _on(
      ConduitMethodSpecs.terminalPreviewPort,
      (p) => _requireTerminals().previewPort(p),
    );

    // workspace.*.
    _on(
      ConduitMethodSpecs.workspaceCapabilities,
      (_) => _requireWorkspace().capabilities(),
    );
    _on(
      ConduitMethodSpecs.workspaceModelOptions,
      (_) => _requireWorkspace().modelOptions(),
    );
    _on(ConduitMethodSpecs.workspaceList, (p) => _requireWorkspace().list(p));
    _on(ConduitMethodSpecs.workspaceGet, (p) => _requireWorkspace().get(p));
    _on(ConduitMethodSpecs.workspaceSave, (p) => _requireWorkspace().save(p));
    _on(ConduitMethodSpecs.workspaceDelete, (p) async {
      await _requireWorkspace().delete(p);
      return ok;
    });
    _on(
      ConduitMethodSpecs.workspaceToggle,
      (p) => _requireWorkspace().toggle(p),
    );
    _on(
      ConduitMethodSpecs.workspaceSetAccess,
      (p) => _requireWorkspace().setAccess(p),
    );
    _on(
      ConduitMethodSpecs.workspacePrincipals,
      (p) => _requireWorkspace().principals(p),
    );
    _on(
      ConduitMethodSpecs.workspaceExport,
      (p) => _requireWorkspace().export(p),
    );
    _on(
      ConduitMethodSpecs.workspaceImport,
      (p) => _requireWorkspace().import(p),
    );
    _on(
      ConduitMethodSpecs.workspacePromptHistory,
      (p) => _requireWorkspace().promptHistory(p.id),
    );
    _on(
      ConduitMethodSpecs.workspacePromptDiff,
      (p) => _requireWorkspace().promptDiff(p),
    );
    _on(
      ConduitMethodSpecs.workspacePromptSetVersion,
      (p) => _requireWorkspace().promptSetVersion(p),
    );
    _on(ConduitMethodSpecs.workspacePromptDeleteVersion, (p) async {
      await _requireWorkspace().promptDeleteVersion(p);
      return ok;
    });
    _on(
      ConduitMethodSpecs.workspaceValves,
      (p) => _requireWorkspace().valves(p),
    );
    _on(
      ConduitMethodSpecs.workspaceSaveValves,
      (p) => _requireWorkspace().saveValves(p),
    );
    _on(
      ConduitMethodSpecs.workspaceToolFromUrl,
      (p) => _requireWorkspace().toolFromUrl(p.url),
    );
    _on(ConduitMethodSpecs.workspaceFiles, (p) => _requireWorkspace().files(p));
    _on(
      ConduitMethodSpecs.workspaceAttachFiles,
      (p) => _requireWorkspace().attachFiles(p),
    );
    _on(
      ConduitMethodSpecs.workspaceFileAction,
      (p) => _requireWorkspace().fileAction(p),
    );
    _on(
      ConduitMethodSpecs.workspaceDirectoryAction,
      (p) => _requireWorkspace().directoryAction(p),
    );
    _on(
      ConduitMethodSpecs.workspaceKnowledgeReset,
      (p) => _requireWorkspace().knowledgeReset(p.id),
    );
    _on(
      ConduitMethodSpecs.workspaceKnowledgeCleanup,
      (p) => _requireWorkspace().knowledgeCleanup(p.id),
    );

    // notes.*.
    _on(ConduitMethodSpecs.notesList, (r) => _requireNotes().list(r.query));
    // Wrapped, as `chats.get` is: a note deleted elsewhere is null, not an
    // error.
    _on(
      ConduitMethodSpecs.notesGet,
      (ref) async => NoteResult(note: await _requireNotes().get(ref.id)),
    );
    _on(ConduitMethodSpecs.notesSave, (r) => _requireNotes().save(r));
    _on(ConduitMethodSpecs.notesDelete, (ref) async {
      await _requireNotes().delete(ref.id);
      return const DeletedResult(deleted: true);
    });
    _on(
      ConduitMethodSpecs.notesGenerateTitle,
      (r) => _requireNotes().generateTitle(r),
    );
    _on(ConduitMethodSpecs.notesEnhance, (r) => _requireNotes().enhance(r));
    _on(ConduitMethodSpecs.notesAttach, (r) => _requireNotes().attach(r));
    _on(ConduitMethodSpecs.notesDetach, (r) => _requireNotes().detach(r));
    _on(
      ConduitMethodSpecs.notesSetPinned,
      (r) => _requireNotes().setPinned(r.id, pinned: r.pinned),
    );

    // mcp.*.
    _on(ConduitMethodSpecs.mcpList, (_) => _requireMcp().list());
    _on(ConduitMethodSpecs.mcpSave, (e) => _requireMcp().save(e));
    _on(ConduitMethodSpecs.mcpRemove, (ref) => _requireMcp().remove(ref.id));
    _on(
      ConduitMethodSpecs.mcpSetEnabled,
      (r) => _requireMcp().setEnabled(r.id, r.enabled),
    );
    _on(ConduitMethodSpecs.mcpTest, (e) => _requireMcp().test(e));
    _on(ConduitMethodSpecs.mcpConnect, (ref) => _requireMcp().connect(ref.id));
    _on(ConduitMethodSpecs.mcpCancelConnect, (ref) async {
      await _requireMcp().cancelConnect(ref.id);
      return const CancelledResult(cancelled: true);
    });
    _on(
      ConduitMethodSpecs.mcpDisconnect,
      (ref) => _requireMcp().disconnect(ref.id),
    );
    _on(
      ConduitMethodSpecs.mcpForgetApproval,
      (r) => _requireMcp().forgetApproval(r),
    );
    _on(ConduitMethodSpecs.mcpContent, (ref) => _requireMcp().content(ref.id));
    _on(ConduitMethodSpecs.mcpGetPrompt, (r) => _requireMcp().getPrompt(r));
    _on(
      ConduitMethodSpecs.mcpReadResource,
      (r) => _requireMcp().readResource(r),
    );

    // prompts.*, models.*.
    _on(ConduitMethodSpecs.promptsList, (_) => _requirePrompts().list());
    _on(ConduitMethodSpecs.promptsRender, (r) => _requirePrompts().render(r));
    _on(ConduitMethodSpecs.modelsList, (_) => _requireModels().list());
    _on(ConduitMethodSpecs.modelsSelect, (r) => _requireModels().select(r.id));
    _on(
      ConduitMethodSpecs.modelsSetPinned,
      (r) => _requireModels().setPinned(r),
    );
    _on(ConduitMethodSpecs.modelsOptions, (r) => _requireModels().options(r));
    _on(
      ConduitMethodSpecs.modelsSetReasoningEffort,
      (r) => _requireModels().setReasoningEffort(r),
    );
    _on(
      ConduitMethodSpecs.modelsSetFastTier,
      (r) => _requireModels().setFastTier(r),
    );
    // chatSettings.*, valves.*, access.*: a chat's own settings, the user's
    // valves for its tools, and who may reach a folder (later a note or a
    // Workspace item).
    _on(ConduitMethodSpecs.chatSettingsGet, (r) => _need(_chatSettings).get(r));
    _on(
      ConduitMethodSpecs.chatSettingsCheck,
      (r) => _need(_chatSettings).check(r),
    );
    _on(
      ConduitMethodSpecs.chatSettingsSave,
      (r) => _need(_chatSettings).save(r),
    );
    _on(ConduitMethodSpecs.valvesTargets, (r) => _need(_valves).targets(r));
    _on(ConduitMethodSpecs.valvesGet, (r) => _need(_valves).get(r));
    _on(ConduitMethodSpecs.valvesSave, (r) => _need(_valves).save(r));
    _on(ConduitMethodSpecs.accessGet, (r) => _need(_access).get(r));
    _on(ConduitMethodSpecs.accessSet, (r) => _need(_access).set(r));
    _on(
      ConduitMethodSpecs.accessPrincipals,
      (r) => _need(_access).principals(r),
    );
  }

  ChannelsService _requireChannels() =>
      _channels ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  VoiceService _requireVoice() =>
      _voice ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  HermesService _requireHermes() =>
      _hermes ??
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

  ComposerService _requireComposer() =>
      _composer ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  DraftsService _requireDrafts() =>
      _drafts ??
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

  AccountsService _requireAccounts() =>
      _accounts ??
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
