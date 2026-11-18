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
import 'web_search_service.dart';
import 'webhooks_service.dart';
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
import 'computer_rpc_service.dart';
import 'handoff_service.dart';
import 'automations_service.dart';
import 'calendar_service.dart';
import 'hermes_admin_service.dart';
import 'hermes_cards_service.dart';
import 'hermes_rooms_service.dart';
import 'hermes_service.dart';
import 'apple_models_service.dart';
import 'location_bridge.dart';
import 'calls_service.dart';
import 'librechat_service.dart';
import 'intents_service.dart';
import 'speech_service.dart';
import 'voice_service.dart';
import 'dictation_service.dart';
import 'recordings_service.dart';
import 'core_settings_service.dart';
import 'data_service.dart';
import 'access_service.dart';
import 'chat_settings_service.dart';
import 'folder_settings_service.dart';
import 'integrations_service.dart';
import 'memories_service.dart';
import 'notifications_service.dart';
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
    this.hermesCards,
    this.composer,
    this.prompts,
    this.direct,
    this.mcp,
    this.webSearch,
    this.notes,
    this.channels,
    this.workspace,
    this.terminals,
    this.computer,
    this.hermes,
    this.hermesAdmin,
    this.voice,
    this.dictation,
    this.recordings,
    this.coreSettings,
    this.profile,
    this.memories,
    this.notifications,
    this.webhooks,
    this.integrations,
    this.libreChat,
    this.releaseNotes,
    this.data,
    this.drafts,
    this.chatSettings,
    this.valves,
    this.access,
    this.folderSettings,
    this.speech,
    this.calls,
    this.apple,
    this.location,
    this.handoff,
    this.calendar,
    this.automations,
    this.hermesRooms,
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
  final HermesCardsService? hermesCards;
  final ComposerService? composer;
  final PromptsService? prompts;
  final DirectService? direct;
  final McpService? mcp;
  final WebSearchService? webSearch;
  final NotesService? notes;
  final ChannelsService? channels;
  final WorkspaceService? workspace;
  final TerminalsService? terminals;
  final ComputerRpcService? computer;
  final HermesService? hermes;

  /// Hermes's connections, MCP servers, scheduled agents and catalog.
  final HermesAdminService? hermesAdmin;
  final VoiceService? voice;

  /// The rest of `settings.*` (core's `AppSettings` and the account's own).
  final CoreSettingsService? coreSettings;
  final ProfileService? profile;
  final MemoriesService? memories;

  /// `notifications.*`, `webhooks.*` and `integrations.*`.
  final NotificationsService? notifications;
  final WebhooksService? webhooks;
  final IntegrationsService? integrations;

  /// `librechat.*`: LibreChat sign-in, composer tools, memories, Duplicate.
  final LibreChatService? libreChat;
  final ReleaseNotesRpcService? releaseNotes;
  final DataService? data;
  final DraftsService? drafts;
  final ChatSettingsService? chatSettings;
  final ValvesService? valves;
  final AccessService? access;
  final FolderSettingsService? folderSettings;

  /// `speech.*`: read aloud.
  final SpeechService? speech;

  /// `calls.*`: voice calls.
  final CallsService? calls;

  /// `apple.*`: Apple's on-device model, run in the window.
  final AppleModelsService? apple;

  /// `location.*`: the window's location services, for `{{USER_LOCATION}}`.
  final WindowLocationBridge? location;

  /// A server's `chat:handoff`, put to the windows.
  final HandoffService? handoff;

  /// `calendar.*`: the account's calendars and agenda.
  final CalendarService? calendar;

  /// `automations.*`: the account's scheduled tasks.
  final AutomationsService? automations;

  /// `hermes.rooms.*` and `hermes.bots.*`: Bot Chats and Group Chats.
  final HermesRoomsService? hermesRooms;
  final DictationService? dictation;
  final RecordingsService? recordings;
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
  WebSearchService? get _webSearch => _services().webSearch;
  NotesService? get _notes => _services().notes;
  ChannelsService? get _channels => _services().channels;
  WorkspaceService? get _workspace => _services().workspace;
  TerminalsService? get _terminals => _services().terminals;
  ComputerRpcService? get _computer => _services().computer;
  HermesService? get _hermes => _services().hermes;
  HermesAdminService? get _hermesAdmin => _services().hermesAdmin;
  VoiceService? get _voice => _services().voice;
  DictationService? get _dictation => _services().dictation;
  RecordingsService? get _recordings => _services().recordings;
  CoreSettingsService? get _coreSettings => _services().coreSettings;
  ProfileService? get _profile => _services().profile;
  MemoriesService? get _memories => _services().memories;
  NotificationsService? get _notifications => _services().notifications;
  WebhooksService? get _webhooks => _services().webhooks;
  IntegrationsService? get _integrations => _services().integrations;
  LibreChatService? get _libreChat => _services().libreChat;
  ChatPromptsService? get _chatPrompts => _services().chatPrompts;
  McpAppsService? get _mcpApps => _services().mcpApps;
  HermesCardsService? get _hermesCards => _services().hermesCards;
  SpeechService? get _speech => _services().speech;
  CallsService? get _calls => _services().calls;
  AppleModelsService? get _apple => _services().apple;
  WindowLocationBridge? get _location => _services().location;
  ReleaseNotesRpcService? get _releaseNotes => _services().releaseNotes;
  DataService? get _data => _services().data;
  ChatSettingsService? get _chatSettings => _services().chatSettings;
  ValvesService? get _valves => _services().valves;
  AccessService? get _access => _services().access;
  FolderSettingsService? get _folderSettings => _services().folderSettings;
  HandoffService? get _handoff => _services().handoff;
  CalendarService? get _calendar => _services().calendar;
  AutomationsService? get _automations => _services().automations;
  HermesRoomsService? get _hermesRooms => _services().hermesRooms;

  /// Where a window's `online`/`offline` events go: the connectivity port,
  /// which then tells every window. Null before the core is up.
  final void Function(bool online)? _reportNetwork;

  /// Serves the window until its socket ends, however it ends (the window
  /// closed it, it dropped, or it failed), then [close]s: a window gone is
  /// cleaned up as one closed.
  Future<void> listen() async {
    try {
      await _peer.listen();
    } finally {
      await close();
    }
  }

  /// Ends the session and lets go of what it held: the one way out for
  /// every end ([listen] done or failed, the daemon stopping), once however
  /// often it is called.
  Future<void> close() => _closing ??= _close();
  Future<void>? _closing;

  Future<void> _close() async {
    _events.detach(sessionId);
    // If that was the last window, nobody is left to answer: questions
    // still waiting take their conservative default now rather than hang
    // the turn that asked them.
    _uiRequests?.onWindowsChanged();
    _handoff?.onWindowsChanged();
    // The Hermes chats it watched are no longer shown here.
    _hermesCards?.forgetWindow(sessionId);
    // And the rooms it showed or listed.
    _hermesRooms?.forgetWindow(sessionId);
    // Its Apple engine runs nothing more; its commands are not answered.
    _apple?.forgetWindow(sessionId);
    // What this window was recording is kept for its next launch.
    await _recordings?.closeOwnedBy(sessionId);
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
    _registerIntents();
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
    _on(
      ConduitMethodSpecs.serversAddressesList,
      (r) => _requireServers().addresses(r),
    );
    _on(
      ConduitMethodSpecs.serversAddressesCheck,
      (r) => _requireServers().check(r),
    );
    _on(
      ConduitMethodSpecs.serversAddressesSave,
      (r) => _requireServers().save(r),
    );
    _on(
      ConduitMethodSpecs.serversAddressesRemove,
      (r) => _requireServers().remove(r),
    );
    _on(
      ConduitMethodSpecs.serversAddressesReorder,
      (r) => _requireServers().reorder(r),
    );
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
    _on(
      ConduitMethodSpecs.authTwoStepSetup,
      (_) => _requireAuth().twoStepSetup(),
    );
    _on(
      ConduitMethodSpecs.authTwoStepVerify,
      (p) => _requireAuth().twoStepVerify(p),
    );
    _on(
      ConduitMethodSpecs.authTwoStepRedeem,
      (p) => _requireAuth().twoStepRedeem(p),
    );
    _on(
      ConduitMethodSpecs.authTwoStepFinish,
      (_) => _requireAuth().twoStepFinish(),
    );
    _on(
      ConduitMethodSpecs.authTwoStepCancel,
      (_) => _requireAuth().twoStepCancel(),
    );
    _on(ConduitMethodSpecs.authRetry, (_) => _requireAuth().retry());
    _on(ConduitMethodSpecs.authRenewProxy, (p) => _requireAuth().renewProxy(p));
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
    _on(ConduitMethodSpecs.librechatProbe, (p) => _need(_libreChat).probe(p));
    _on(ConduitMethodSpecs.librechatSignIn, (p) => _need(_libreChat).signIn(p));
    _on(ConduitMethodSpecs.librechatVerify, (p) => _need(_libreChat).verify(p));
    _on(
      ConduitMethodSpecs.librechatSsoStart,
      (p) => _need(_libreChat).ssoStart(p),
    );
    _on(
      ConduitMethodSpecs.librechatCompleteSso,
      (p) => _need(_libreChat).completeSso(p),
    );
    _on(
      ConduitMethodSpecs.librechatComposer,
      (p) => _need(_libreChat).composer(p),
    );
    _on(
      ConduitMethodSpecs.librechatMemoriesList,
      (_) => _need(_libreChat).memories(),
    );
    _on(
      ConduitMethodSpecs.librechatMemoriesSave,
      (p) => _need(_libreChat).saveMemory(p),
    );
    _on(
      ConduitMethodSpecs.librechatMemoriesDelete,
      (p) => _need(_libreChat).deleteMemory(p),
    );
    _on(
      ConduitMethodSpecs.librechatMemoriesSetEnabled,
      (p) => _need(_libreChat).setMemoriesEnabled(p),
    );
    _on(
      ConduitMethodSpecs.librechatDuplicate,
      (p) => _need(_libreChat).duplicate(p),
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
    _on(
      ConduitMethodSpecs.notificationsGet,
      (_) async => _need(_notifications).get(),
    );
    _on(
      ConduitMethodSpecs.notificationsSet,
      (p) => _need(_notifications).set(p),
    );
    _on(
      ConduitMethodSpecs.notificationsRoute,
      (p) async => _need(_notifications).route(p),
    );
    _on(ConduitMethodSpecs.webhooksList, (_) => _need(_webhooks).list());
    _on(ConduitMethodSpecs.webhooksCreate, (p) => _need(_webhooks).create(p));
    _on(ConduitMethodSpecs.webhooksUpdate, (p) => _need(_webhooks).update(p));
    _on(
      ConduitMethodSpecs.webhooksMakeDefault,
      (p) => _need(_webhooks).makeDefault(p),
    );
    _on(ConduitMethodSpecs.webhooksTest, (p) => _need(_webhooks).test(p));
    _on(ConduitMethodSpecs.webhooksDelete, (p) => _need(_webhooks).delete(p));
    _on(
      ConduitMethodSpecs.integrationsList,
      (_) => _need(_integrations).list(),
    );
    _on(
      ConduitMethodSpecs.integrationsSave,
      (p) => _need(_integrations).save(p),
    );
    _on(
      ConduitMethodSpecs.integrationsTest,
      (p) => _need(_integrations).test(p),
    );
    _on(
      ConduitMethodSpecs.integrationsClearNotice,
      (_) => _need(_integrations).clearNotice(),
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
    _on(ConduitMethodSpecs.dataReconnect, (_) => _need(_data).reconnect());
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
    _on(ConduitMethodSpecs.turnsSend, (r) async {
      final models = _models;
      // What the turn's landing may move is captured before any wait.
      final sending = models?.sending(r.chatId);
      // A turn that names no model runs with its own chat's (its pick, its
      // saved agent, else the account's default), never the account's
      // selection of the moment, which may be another chat's agent.
      final model = r.model ?? await models?.modelFor(r.chatId);
      final accepted = await _requireTurns().send(r.copyWith(model: model));
      if (sending != null) {
        models!.sent(sending, toChat: accepted.chatId, model: model);
      }
      return accepted;
    });
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

    // calendar.*: the account's Open WebUI calendars and agenda.
    _on(ConduitMethodSpecs.calendarAgenda, (r) => _need(_calendar).agenda(r));
    _on(
      ConduitMethodSpecs.calendarSetVisible,
      (r) => _need(_calendar).setVisible(r),
    );
    _on(
      ConduitMethodSpecs.calendarMakeDefault,
      (r) => _need(_calendar).makeDefault(r),
    );
    _on(
      ConduitMethodSpecs.calendarCreateCalendar,
      (r) => _need(_calendar).createCalendar(r),
    );
    _on(ConduitMethodSpecs.calendarEvent, (r) => _need(_calendar).event(r));
    _on(
      ConduitMethodSpecs.calendarDeleteEvent,
      (r) => _need(_calendar).deleteEvent(r),
    );
    _on(ConduitMethodSpecs.calendarRespond, (r) => _need(_calendar).respond(r));
    _on(ConduitMethodSpecs.calendarEditor, (r) => _need(_calendar).editor(r));
    _on(
      ConduitMethodSpecs.calendarCheckDraft,
      (r) => _need(_calendar).checkDraft(r),
    );
    _on(ConduitMethodSpecs.calendarSave, (r) => _need(_calendar).save(r));

    // automations.*: the account's Open WebUI scheduled tasks.
    _on(ConduitMethodSpecs.automationsList, (r) => _need(_automations).list(r));
    _on(
      ConduitMethodSpecs.automationsLoadMore,
      (_) => _need(_automations).loadMore(),
    );
    _on(ConduitMethodSpecs.automationsGet, (r) => _need(_automations).get(r));
    _on(ConduitMethodSpecs.automationsRuns, (r) => _need(_automations).runs(r));
    _on(
      ConduitMethodSpecs.automationsSetActive,
      (r) => _need(_automations).setActive(r),
    );
    _on(ConduitMethodSpecs.automationsRun, (r) => _need(_automations).run(r));
    _on(
      ConduitMethodSpecs.automationsRunState,
      (r) async => _need(_automations).runState(r),
    );
    _on(
      ConduitMethodSpecs.automationsDelete,
      (r) => _need(_automations).delete(r),
    );
    _on(
      ConduitMethodSpecs.automationsEditor,
      (r) => _need(_automations).editor(r),
    );
    _on(
      ConduitMethodSpecs.automationsCheckDraft,
      (r) => _need(_automations).checkDraft(r),
    );
    _on(ConduitMethodSpecs.automationsSave, (r) => _need(_automations).save(r));
    _on(
      ConduitMethodSpecs.automationsTerminals,
      (r) => _need(_automations).terminals(r),
    );

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
    _on(ConduitMethodSpecs.mcpAppsClose, (r) async => _need(_mcpApps).close(r));

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

  /// `intents.*`: Shortcuts' Ask Conduit and Open Chat (the Mac's App
  /// Intents), over the turns and chats services; Send Link to Conduit's
  /// page or transcript, over the composer's Web Page reader.
  void _registerIntents() {
    IntentsService intents() => IntentsService.over(
      turns: _requireTurns(),
      chats: _requireChats(),
      events: _events,
    );
    _on(ConduitMethodSpecs.intentsAsk, (request) => intents().ask(request));
    _on(ConduitMethodSpecs.intentsChats, (query) => intents().chats(query));
    _on(
      ConduitMethodSpecs.intentsSendLink,
      (link) => _requireComposer().sendLink(link.url),
    );
  }

  void _registerModels() {
    _on(ConduitMethodSpecs.composerOptions, (query) {
      final composer = _composer;
      if (composer == null) {
        throw const RpcError(
          code: ConduitErrorCodes.daemonUnavailable,
          debugMessage: 'the core is not up yet',
        );
      }
      return composer.options(query);
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
    _on(ConduitMethodSpecs.directReload, (_) => _requireDirect().reload());
    _on(ConduitMethodSpecs.directOptions, (_) => _requireDirect().options());
    _on(
      ConduitMethodSpecs.directSetImagesPerRequest,
      (r) => _requireDirect().setImagesPerRequest(r.count),
    );
    _on(
      ConduitMethodSpecs.directSetContextLimit,
      (r) => _requireDirect().setContextLimit(r),
    );

    // webSearch.*.
    _on(
      ConduitMethodSpecs.webSearchGet,
      (_) async => _requireWebSearch().get(),
    );
    _on(ConduitMethodSpecs.webSearchSet, (p) => _requireWebSearch().set(p));

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
    _on(
      ConduitMethodSpecs.channelsOpen,
      (ref) => _requireChannels().open(ref.id),
    );
    _on(ConduitMethodSpecs.channelsFocus, (p) async {
      await _requireChannels().focus(p.id);
      return ok;
    });
    _on(
      ConduitMethodSpecs.channelsSetMuted,
      (p) => _requireChannels().setMuted(p),
    );
    _on(
      ConduitMethodSpecs.channelsMentions,
      (q) => _requireChannels().mentions(q),
    );
    _on(
      ConduitMethodSpecs.channelsMemberPage,
      (q) => _requireChannels().memberPage(q),
    );
    _on(
      ConduitMethodSpecs.channelsAddMembers,
      (p) => _requireChannels().addMembers(p),
    );
    _on(
      ConduitMethodSpecs.channelsRemoveMember,
      (p) => _requireChannels().removeMember(p),
    );
    _on(
      ConduitMethodSpecs.channelsAppAction,
      (p) => _requireChannels().appAction(p),
    );

    // hermes.*.
    _on(ConduitMethodSpecs.hermesSettings, (_) => _requireHermes().settings());
    _on(
      ConduitMethodSpecs.hermesSaveSettings,
      (p) => _requireHermes().saveSettings(p),
    );
    _on(ConduitMethodSpecs.hermesTest, (p) => _requireHermes().test(p));
    _on(ConduitMethodSpecs.hermesStatus, (_) => _requireHermes().status());
    _on(ConduitMethodSpecs.hermesSignIn, (p) => _requireHermes().signIn(p));
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
    _on(
      ConduitMethodSpecs.hermesSessionsUpdate,
      (p) => _requireHermes().update(p),
    );
    _on(
      ConduitMethodSpecs.hermesSessionsContinue,
      (p) => _requireHermes().continueChat(p),
    );
    _on(ConduitMethodSpecs.hermesHiddenList, (_) => _requireHermes().hidden());
    _on(
      ConduitMethodSpecs.hermesHistoryBranch,
      (p) => _requireTurns().branchHermes(p),
    );
    _on(
      ConduitMethodSpecs.hermesHistoryUndo,
      (p) => _requireTurns().undoHermes(p),
    );
    // Scheduled agents, the catalog, connections and MCP servers.
    _on(ConduitMethodSpecs.hermesJobs, (_) => _need(_hermesAdmin).jobs());
    _on(
      ConduitMethodSpecs.hermesSaveJob,
      (p) => _need(_hermesAdmin).saveJob(p),
    );
    _on(
      ConduitMethodSpecs.hermesSetJobEnabled,
      (p) => _need(_hermesAdmin).setJobEnabled(p),
    );
    _on(
      ConduitMethodSpecs.hermesRunJob,
      (p) => _need(_hermesAdmin).runJob(p.id, connection: p.connection),
    );
    _on(
      ConduitMethodSpecs.hermesDeleteJob,
      (p) => _need(_hermesAdmin).deleteJob(p.id, connection: p.connection),
    );
    _on(ConduitMethodSpecs.hermesCatalog, (_) => _need(_hermesAdmin).catalog());
    _on(
      ConduitMethodSpecs.hermesJobsRuns,
      (p) => _need(_hermesAdmin).jobRuns(p.id, connection: p.connection),
    );
    _on(
      ConduitMethodSpecs.hermesJobsStop,
      (p) => _need(_hermesAdmin).stopJob(p.id, connection: p.connection),
    );
    _on(
      ConduitMethodSpecs.hermesJobsDelivery,
      (_) => _need(_hermesAdmin).deliveryOptions(),
    );
    _on(
      ConduitMethodSpecs.hermesConnectionsList,
      (_) => _need(_hermesAdmin).connections(),
    );
    _on(
      ConduitMethodSpecs.hermesConnectionsSave,
      (p) => _need(_hermesAdmin).saveConnection(p),
    );
    _on(
      ConduitMethodSpecs.hermesConnectionsTest,
      (p) => _need(_hermesAdmin).testConnection(p),
    );
    _on(
      ConduitMethodSpecs.hermesConnectionsActivate,
      (p) => _need(_hermesAdmin).activate(p.id),
    );
    _on(
      ConduitMethodSpecs.hermesConnectionsDelete,
      (p) => _need(_hermesAdmin).deleteConnection(p.id),
    );
    _on(
      ConduitMethodSpecs.hermesConnectionsSetEnabled,
      (p) => _need(_hermesAdmin).setEnabled(p.enabled),
    );
    _on(
      ConduitMethodSpecs.hermesConnectionsProfiles,
      (p) => _need(_hermesAdmin).profiles(p),
    );
    _on(
      ConduitMethodSpecs.hermesToolsetsSet,
      (p) => _need(_hermesAdmin).setToolset(p),
    );
    _on(
      ConduitMethodSpecs.hermesSkillsReload,
      (p) => _need(_hermesAdmin).reloadSkills(p),
    );
    _on(
      ConduitMethodSpecs.hermesDashboardStart,
      (p) => _need(_hermesAdmin).dashboardStart(p),
    );
    _on(
      ConduitMethodSpecs.hermesDashboardComplete,
      (p) => _need(_hermesAdmin).dashboardComplete(p),
    );
    _on(
      ConduitMethodSpecs.hermesDashboardCancel,
      (p) => _need(_hermesAdmin).dashboardCancel(p),
    );
    _on(
      ConduitMethodSpecs.hermesMcpList,
      (_) => _need(_hermesAdmin).mcpServers(),
    );
    _on(
      ConduitMethodSpecs.hermesMcpCatalog,
      (_) => _need(_hermesAdmin).mcpCatalog(),
    );
    _on(ConduitMethodSpecs.hermesMcpAdd, (p) => _need(_hermesAdmin).addMcp(p));
    _on(
      ConduitMethodSpecs.hermesMcpAddFromCatalog,
      (p) => _need(_hermesAdmin).addMcpFromCatalog(p),
    );
    _on(
      ConduitMethodSpecs.hermesMcpSetApiKey,
      (p) => _need(_hermesAdmin).setMcpApiKey(p),
    );
    _on(
      ConduitMethodSpecs.hermesMcpRemove,
      (p) => _need(_hermesAdmin).removeMcp(p),
    );
    _on(
      ConduitMethodSpecs.hermesMcpTest,
      (p) => _need(_hermesAdmin).testMcp(p),
    );
    _on(
      ConduitMethodSpecs.hermesMcpSetEnabled,
      (p) => _need(_hermesAdmin).setMcpEnabled(p),
    );
    _on(
      ConduitMethodSpecs.hermesMcpAuthenticate,
      (p) => _need(_hermesAdmin).authenticateMcp(p),
    );

    // hermes.work.*, hermes.context.*, hermes.decisions.*: a Hermes chat's
    // agent at work, its context window, and what it asks.
    _on(
      ConduitMethodSpecs.hermesWorkWatch,
      (r) => _need(_hermesCards).watch(sessionId, r),
    );
    _on(
      ConduitMethodSpecs.hermesWorkUnwatch,
      (r) => _need(_hermesCards).unwatch(sessionId, r.chatId),
    );
    _on(
      ConduitMethodSpecs.hermesWorkSteer,
      (r) => _need(_hermesCards).steer(r),
    );
    _on(ConduitMethodSpecs.hermesWorkStop, (r) => _need(_hermesCards).stop(r));
    _on(ConduitMethodSpecs.hermesWorkKill, (r) => _need(_hermesCards).kill(r));
    _on(
      ConduitMethodSpecs.hermesContextGet,
      (r) => _need(_hermesCards).context(r),
    );
    _on(
      ConduitMethodSpecs.hermesContextCompact,
      (r) => _need(_hermesCards).compact(r),
    );
    _on(
      ConduitMethodSpecs.hermesDecisionsAnswer,
      (r) => _need(_hermesCards).answer(r),
    );

    // hermes.bots.*, hermes.rooms.*: Bot Mode and Group Chats.
    _on(ConduitMethodSpecs.hermesBotsList, (_) => _need(_hermesRooms).bots());
    _on(
      ConduitMethodSpecs.hermesBotsAvatar,
      (r) => _need(_hermesRooms).avatar(r.name, connection: r.connection),
    );
    _on(
      ConduitMethodSpecs.hermesBotsOpen,
      (r) =>
          _need(_hermesRooms)
              .openBot(r.name, _requireHermes(), connection: r.connection),
    );
    _on(
      ConduitMethodSpecs.hermesRoomsList,
      (_) => _need(_hermesRooms).rooms(sessionId),
    );
    _on(
      ConduitMethodSpecs.hermesRoomsCreate,
      (r) => _need(_hermesRooms).create(r),
    );
    _on(
      ConduitMethodSpecs.hermesRoomsWatch,
      (r) =>
          _need(_hermesRooms)
              .watch(sessionId, r.roomId, connection: r.connection),
    );
    _on(
      ConduitMethodSpecs.hermesRoomsUnwatch,
      (r) => _need(_hermesRooms).unwatch(sessionId, r.roomId),
    );
    _on(ConduitMethodSpecs.hermesRoomsSend, (r) => _need(_hermesRooms).send(r));
    _on(
      ConduitMethodSpecs.hermesRoomsStop,
      (r) => _need(_hermesRooms).stop(r.roomId, connection: r.connection),
    );
    _on(
      ConduitMethodSpecs.hermesRoomsContinue,
      (r) => _need(_hermesRooms).continueDiscussion(r),
    );
    _on(
      ConduitMethodSpecs.hermesRoomsAnswer,
      (r) => _need(_hermesRooms).answer(r),
    );
    _on(
      ConduitMethodSpecs.hermesRoomsRename,
      (r) => _need(_hermesRooms).rename(r),
    );
    _on(
      ConduitMethodSpecs.hermesRoomsSaveContext,
      (r) => _need(_hermesRooms).saveContext(r),
    );
    _on(
      ConduitMethodSpecs.hermesRoomsDisband,
      (r) => _need(_hermesRooms).disband(r.roomId, connection: r.connection),
    );

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

    // dictation.*, recordings.*.
    _on(
      ConduitMethodSpecs.dictationStatus,
      (p) => _requireDictation().status(p),
    );
    _on(ConduitMethodSpecs.recordingsList, (p) => _requireRecordings().list(p));
    _on(
      ConduitMethodSpecs.recordingsBegin,
      (p) => _requireRecordings().begin(p, sessionId: sessionId),
    );
    _on(
      ConduitMethodSpecs.recordingsAppend,
      (p) => _requireRecordings().append(p),
    );
    _on(
      ConduitMethodSpecs.recordingsClose,
      (p) => _requireRecordings().close(p),
    );
    _on(
      ConduitMethodSpecs.recordingsDiscard,
      (p) => _requireRecordings().discard(p),
    );
    _on(
      ConduitMethodSpecs.recordingsTranscribe,
      (p) => _requireRecordings().transcribe(p),
    );

    // speech.*: read aloud, run here; the window speaks and plays.
    _on(ConduitMethodSpecs.speechGet, (_) async => _need(_speech).get());
    _on(ConduitMethodSpecs.speechToggle, (p) => _need(_speech).toggle(p));
    _on(ConduitMethodSpecs.speechPause, (_) => _need(_speech).pause());
    _on(ConduitMethodSpecs.speechResume, (_) => _need(_speech).resume());
    _on(ConduitMethodSpecs.speechStop, (_) => _need(_speech).stop());
    _on(ConduitMethodSpecs.speechRetry, (_) => _need(_speech).retry());
    _on(ConduitMethodSpecs.speechSeek, (p) => _need(_speech).seek(p));
    _on(ConduitMethodSpecs.speechPreview, (p) => _need(_speech).preview(p));
    _on(ConduitMethodSpecs.speechReport, (p) async {
      _need(_speech).report(p);
      return const OkResult(ok: true);
    });

    // calls.*: voice calls, run here; the window listens and plays.
    _on(ConduitMethodSpecs.callsGet, (_) async => _need(_calls).get());
    _on(ConduitMethodSpecs.callsStart, (p) => _need(_calls).start(p));
    _on(ConduitMethodSpecs.callsEnd, (_) => _need(_calls).end());
    _on(ConduitMethodSpecs.callsPause, (_) => _need(_calls).pause());
    _on(ConduitMethodSpecs.callsResume, (_) => _need(_calls).resume());
    _on(ConduitMethodSpecs.callsMute, (_) => _need(_calls).mute());
    _on(ConduitMethodSpecs.callsSkip, (_) => _need(_calls).skip());
    _on(ConduitMethodSpecs.callsReport, (p) async {
      _need(_calls).report(p);
      return const OkResult(ok: true);
    });

    // apple.*: Apple's on-device model; the chat runs here, the model in
    // the window.
    _on(ConduitMethodSpecs.appleStatus, (_) => _need(_apple).status());
    _on(ConduitMethodSpecs.appleRefresh, (_) => _need(_apple).refresh());
    _on(ConduitMethodSpecs.appleChoose, (_) => _need(_apple).choose());
    _on(ConduitMethodSpecs.appleReport, (p) async {
      _need(_apple).report(p, from: sessionId);
      return const OkResult(ok: true);
    });

    // location.*: the window answers the daemon's location questions.
    _on(ConduitMethodSpecs.locationReport, (p) async {
      _need(_location).report(p);
      return const OkResult(ok: true);
    });

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
    _on(
      ConduitMethodSpecs.terminalWatch,
      (p) async => _requireTerminals().watch(p),
    );
    _on(ConduitMethodSpecs.terminalDetach, (p) async {
      await _requireTerminals().detach(p.handle);
      return ok;
    });

    // computer.*.
    _on(
      ConduitMethodSpecs.computerStatus,
      (p) => _requireComputer().status(p.chatId),
    );
    _on(ConduitMethodSpecs.computerOpen, (p) => _requireComputer().open(p));
    _on(
      ConduitMethodSpecs.computerTabs,
      (p) => _requireComputer().tabs(p.chatId),
    );
    _on(ConduitMethodSpecs.computerCloseTab, (p) async {
      await _requireComputer().closeTab(p);
      return ok;
    });
    _on(ConduitMethodSpecs.computerShortcut, (p) async {
      await _requireComputer().shortcut(p);
      return ok;
    });
    _on(ConduitMethodSpecs.computerClose, (p) async {
      await _requireComputer().close(p.handle);
      return ok;
    });

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
    _on(
      ConduitMethodSpecs.workspaceDuplicate,
      (p) => _requireWorkspace().duplicate(p),
    );
    _on(
      ConduitMethodSpecs.workspaceAddText,
      (p) => _requireWorkspace().addText(p),
    );
    _on(
      ConduitMethodSpecs.workspaceSkillFromMarkdown,
      (p) async => _requireWorkspace().skillFromMarkdown(p.text),
    );

    // notes.*.
    _on(ConduitMethodSpecs.notesList, (r) => _requireNotes().list(r.query));
    // Wrapped, as `chats.get` is: a note deleted elsewhere is null, not an
    // error.
    _on(
      ConduitMethodSpecs.notesGet,
      (open) async => NoteResult(
        note: await _requireNotes().get(open.id, pageId: open.pageId),
      ),
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
      ConduitMethodSpecs.notesRecordings,
      (ref) => _requireNotes().recordings(ref.id),
    );
    _on(
      ConduitMethodSpecs.notesAddRecording,
      (r) => _requireNotes().addRecording(r),
    );
    _on(
      ConduitMethodSpecs.notesRetryRecording,
      (r) => _requireNotes().retryRecording(r),
    );
    _on(
      ConduitMethodSpecs.notesRemoveRecording,
      (r) => _requireNotes().removeRecording(r),
    );
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
    _on(ConduitMethodSpecs.modelsList, (q) => _requireModels().list(q));
    _on(
      ConduitMethodSpecs.modelsSelect,
      (r) => _requireModels().select(r.id, chatId: r.chatId),
    );
    _on(ConduitMethodSpecs.modelsControls, (q) => _requireModels().controls(q));
    _on(
      ConduitMethodSpecs.modelsSetControl,
      (r) => _requireModels().setControl(r),
    );
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

  DictationService _requireDictation() =>
      _dictation ??
      (throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      ));

  RecordingsService _requireRecordings() =>
      _recordings ??
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

  ComputerRpcService _requireComputer() =>
      _computer ??
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

  WebSearchService _requireWebSearch() =>
      _webSearch ??
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
