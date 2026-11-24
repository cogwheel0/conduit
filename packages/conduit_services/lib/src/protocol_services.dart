import 'package:conduit_core/ports/paths_port.dart';
import 'package:conduit_protocol/conduit_protocol.dart' show HostNamespace;
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:stream_channel/stream_channel.dart';

import 'access_service.dart';
import 'accounts_service.dart';
import 'apple_models_service.dart';
import 'auth_service.dart';
import 'automations_service.dart';
import 'calendar_service.dart';
import 'calls_service.dart';
import 'capabilities_service.dart';
import 'channels_service.dart';
import 'chat_prompts_service.dart';
import 'chat_settings_service.dart';
import 'chats_service.dart';
import 'composer_service.dart';
import 'computer_rpc_service.dart';
import 'core_settings_service.dart';
import 'data_service.dart';
import 'dictation_service.dart';
import 'direct_service.dart';
import 'drafts_service.dart';
import 'event_bus.dart';
import 'files_service.dart';
import 'folder_settings_service.dart';
import 'handoff_service.dart';
import 'hermes_admin_service.dart';
import 'hermes_cards_service.dart';
import 'hermes_rooms_service.dart';
import 'hermes_service.dart';
import 'integrations_service.dart';
import 'librechat_service.dart';
import 'local_transcriber.dart';
import 'mcp_apps_service.dart';
import 'mcp_service.dart';
import 'memories_service.dart';
import 'models_service.dart';
import 'notes_service.dart';
import 'notifications_service.dart';
import 'profile_service.dart';
import 'prompts_service.dart';
import 'queued_completions_service.dart';
import 'recordings_service.dart';
import 'release_notes_rpc_service.dart';
import 'rpc_session.dart';
import 'servers_service.dart';
import 'settings_service.dart';
import 'speech_service.dart';
import 'system_service.dart';
import 'temporary_chats.dart';
import 'terminals_service.dart';
import 'turns_service.dart';
import 'ui_requests_service.dart';
import 'valves_service.dart';
import 'voice_service.dart';
import 'web_search_service.dart';
import 'webhooks_service.dart';
import 'window_ports.dart';
import 'workspace_service.dart';

/// What the protocol's services need from their host besides the
/// container.
final class ProtocolHostPorts {
  const ProtocolHostPorts({
    required this.window,
    this.paths,
    this.localTranscriber,
    this.chatScopeOverrides,
    this.sharesAppContainer = false,
  });

  /// The ports the windows answer; the container must hold the overrides
  /// they made ([WindowPorts.overrides]).
  final WindowPorts window;

  /// Where a note's recordings wait for their upload; none without it.
  final PathsPort? paths;

  /// Transcription on this device; none without it.
  final LocalTranscriber? localTranscriber;

  /// What the host adds to every chat's scope: its own ports, such as
  /// `flushSchedulerProvider` and `postFrameSchedulerProvider`.
  ///
  /// Never a provider the scope already overrides, those of
  /// `chatSessionScopeOverrides` and the ones [TurnsService] binds there
  /// (`chatVoiceSendProvider`, `chatDraftQueueSendProvider`,
  /// `chatTurnGateSettingsProvider`, `chatTurnHostHoldsProvider`,
  /// `composerTextInsertionProvider`):
  /// Riverpod refuses a provider overridden twice in one container.
  final List<Override> Function()? chatScopeOverrides;

  /// The services run over a container an app's own interface also uses
  /// (the phone). The app keeps its read-aloud, calls, Apple models and
  /// location, so none of their window bridges is built, nothing the app
  /// installed process-wide is replaced, and [sharedContainerNotOffered]
  /// answer `rpc.unsupported`. The host applies no [WindowPorts.overrides]
  /// to that container either.
  final bool sharesAppContainer;
}

/// What a host that shares an app's container does not serve: the app does
/// these itself ([ProtocolHostPorts.sharesAppContainer]).
const List<HostNamespace> sharedContainerNotOffered = HostNamespace.values;

/// The protocol's services over one container: built, wired to each other
/// and to the host's ports, and stopped in the order they depend on.
///
/// No transport and no process here. A host opens sessions over any
/// [StreamChannel] ([openSession]) and serves the byte routes from the
/// services it needs.
final class ProtocolServices {
  ProtocolServices({
    required this.events,
    required this.system,
    required ProtocolHostPorts ports,
  }) : _ports = ports;

  /// What these services tell the windows; [dispose] closes it.
  final EventBus events;
  final SystemService system;
  final ProtocolHostPorts _ports;

  /// Whether [attach] has built every service.
  bool get isAttached => _attached;
  bool _attached = false;

  /// Builds every service over [container] and wires them together.
  ///
  /// [system] answers the handshake; it may have served sessions before
  /// now, and from now on carries what the account can use. If this throws
  /// part-way, [closeTransports] and [dispose] still stop what was built.
  /// Once either of those has begun, nothing is built.
  void attach(ProviderContainer container) {
    if (_transportsClosed || _disposed) {
      throw StateError('the protocol services are closing');
    }
    if (_servers != null) throw StateError('the services are already built');
    final ports = _ports;
    final shared = ports.sharesAppContainer;
    _servers = ServersService(container, events: events);
    _auth = AuthService(container, events: events);
    _settings = SettingsService(container);
    final temporary = TemporaryChats();
    _queuedCompletions = QueuedCompletionsService(container, events);
    _hermes = HermesService(container, events: events);
    // Bot Mode and Group Chats; a bot's Bot Chat opens as its session.
    _hermesRooms = HermesRoomsService(
      container,
      events,
      connection: hermes.connection,
    );
    hermes.botChats = hermesRooms;
    _hermesAdmin = HermesAdminService(
      container,
      events: events,
      hermes: hermes,
      dashboardCookies: ports.window.dashboardCookies,
    );
    _chats = ChatsService(
      container,
      events: events,
      temporary: temporary,
      hermes: hermes,
      queued: queuedCompletions,
    );
    _files = FilesService(container);
    _uiRequests = UiRequestsService(events);
    // The core's own prompts, raised from any chat's turn, reach the windows
    // through the same broker.
    ports.window.uiRequests.attach(uiRequests);
    _chatPrompts = ChatPromptsService(events);
    _turns = TurnsService(
      container,
      events,
      temporary: temporary,
      uiRequests: uiRequests,
      hermes: hermes,
      files: files,
      chatPrompts: chatPrompts,
      queued: queuedCompletions,
      scopeOverrides: ports.chatScopeOverrides,
    );
    // A Hermes model switch is asked as the question of the chat holding
    // its session.
    ports.window.uiRequests.hermesChatOf = turns.hermesChatOf;
    // The list's unread dots and a chat's abilities read the turns.
    chats.turns = turns;
    // Changing the address in use asks first while one of them answers.
    servers.replies = turns;
    // A Hermes chat's agent cards: its work, its context, its questions.
    _hermesCards = HermesCardsService(
      container,
      events,
      hold: (chatId) => turns.holdScope(chatId),
      release: (chatId) => turns.releaseScope(chatId),
      uiRequests: uiRequests,
    );
    turns.hermesCards = hermesCards;
    // A server's `chat:handoff` for a chat the user is in: one answering
    // here, or one a window shows.
    _handoff = HandoffService(
      events,
      claims: (chatId) => turns.hasScope(chatId) || events.watches(chatId),
    );
    ports.window.handoff.attach(handoff);
    _drafts = DraftsService(container, temporary: temporary);
    _mcpApps = McpAppsService(container, events, uiRequests: uiRequests);
    _accounts = AccountsService(
      container,
      events: events,
      turns: turns,
      sharesAppContainer: shared,
    );
    _models = ModelsService(container, events: events);
    _composer = ComposerService(container);
    _prompts = PromptsService(container);
    _direct = DirectService(container);
    _mcp = McpService(container);
    _webSearch = WebSearchService(container);
    _notes = NotesService(container, events: events, paths: ports.paths);
    _channels = ChannelsService(
      container,
      events: events,
      keepsChannelList: !shared,
      announcesPosts: !shared,
    );
    _workspace = WorkspaceService(container, events: events);
    _terminals = TerminalsService(
      container,
      events: events,
      modelFor: models.modelFor,
    );
    _computer = ComputerRpcService(container, modelFor: models.modelFor);
    _voice = VoiceService(
      container,
      events: events,
      local: ports.localTranscriber,
    );
    _dictation = DictationService(container, voice: voice);
    _recordings = RecordingsService(drafts: drafts, dictation: dictation);
    _coreSettings = CoreSettingsService(container, events: events);
    _profile = ProfileService(container, accounts: accounts);
    _memories = MemoriesService(container);
    _notifications = NotificationsService(
      container,
      events: events,
      announced: turns.announced,
      announcesAnswers: !shared,
    );
    _webhooks = WebhooksService(container);
    _integrations = IntegrationsService(container);
    _libreChat = LibreChatService(
      container,
      events: events,
      accounts: accounts,
    );
    _calendar = CalendarService(container, events: events);
    _automations = AutomationsService(container, events: events);
    _releaseNotes = ReleaseNotesRpcService(container);
    _data = DataService(container, events: events);
    _chatSettings = ChatSettingsService(
      container,
      scopeOf: (chatId) => turns.scopeOf(chatId),
    );
    chats.chatSettings = chatSettings;
    _valves = ValvesService(container);
    _access = AccessService(container, workspace: workspace);
    _folderSettings = FolderSettingsService(container, events: events);
    if (!shared) {
      _speech = SpeechService(
        container,
        events: events,
        voice: voice,
        answerFor: chats.answerFor,
      );
      _calls = CallsService(
        container,
        events: events,
        turns: turns,
        ports: ports.window.calls,
        speech: speech,
      );
      // Apple's on-device model: the chat runs here, the model in the
      // window.
      ports.window.apple.bind(events);
      // `{{USER_LOCATION}}`: the window asks the device's location services.
      ports.window.location.bind(events);
      _apple = AppleModelsService(container, bridge: ports.window.apple);
    }
    voice.speechOfChat = (chatId) async =>
        SpeechService.speechForModel(container, await chats.modelOf(chatId));
    // What the active account can use: answered by `system.capabilities`
    // and the handshake, announced on change.
    _capabilities = CapabilitiesService(
      container,
      events: events,
      notOffered: shared
          ? sharedContainerNotOffered
          : const <HostNamespace>[],
      // Not from inside the constructor: a host that refuses the first
      // answer must find the watcher already held, so [dispose] stops it.
      onChange: (capabilities) {
        if (_capabilities != null) system.capabilities = capabilities;
      },
    );
    // A host reusing a system service starts from what this account can
    // use, not what the last one could.
    system.capabilities = _capabilities!.current;
    // An MCP sign-in opens the provider's page through a window.
    ports.window.openUrl.attach(events);
    _core = _buildCore(transports: true);
    _attached = true;
  }

  ServersService? _servers;
  ServersService get servers => _servers!;
  AuthService? _auth;
  AuthService get auth => _auth!;
  SettingsService? _settings;
  SettingsService get settings => _settings!;
  QueuedCompletionsService? _queuedCompletions;
  QueuedCompletionsService get queuedCompletions => _queuedCompletions!;
  HermesService? _hermes;
  HermesService get hermes => _hermes!;
  HermesRoomsService? _hermesRooms;
  HermesRoomsService get hermesRooms => _hermesRooms!;
  HermesAdminService? _hermesAdmin;
  HermesAdminService get hermesAdmin => _hermesAdmin!;
  ChatsService? _chats;
  ChatsService get chats => _chats!;
  FilesService? _files;
  FilesService get files => _files!;
  UiRequestsService? _uiRequests;
  UiRequestsService get uiRequests => _uiRequests!;
  ChatPromptsService? _chatPrompts;
  ChatPromptsService get chatPrompts => _chatPrompts!;
  TurnsService? _turns;
  TurnsService get turns => _turns!;
  HermesCardsService? _hermesCards;
  HermesCardsService get hermesCards => _hermesCards!;
  HandoffService? _handoff;
  HandoffService get handoff => _handoff!;
  DraftsService? _drafts;
  DraftsService get drafts => _drafts!;
  McpAppsService? _mcpApps;
  McpAppsService get mcpApps => _mcpApps!;
  AccountsService? _accounts;
  AccountsService get accounts => _accounts!;
  ModelsService? _models;
  ModelsService get models => _models!;
  ComposerService? _composer;
  ComposerService get composer => _composer!;
  PromptsService? _prompts;
  PromptsService get prompts => _prompts!;
  DirectService? _direct;
  DirectService get direct => _direct!;
  McpService? _mcp;
  McpService get mcp => _mcp!;
  WebSearchService? _webSearch;
  WebSearchService get webSearch => _webSearch!;
  NotesService? _notes;
  NotesService get notes => _notes!;
  ChannelsService? _channels;
  ChannelsService get channels => _channels!;
  WorkspaceService? _workspace;
  WorkspaceService get workspace => _workspace!;
  VoiceService? _voice;
  VoiceService get voice => _voice!;
  DictationService? _dictation;
  DictationService get dictation => _dictation!;
  RecordingsService? _recordings;
  RecordingsService get recordings => _recordings!;
  CoreSettingsService? _coreSettings;
  CoreSettingsService get coreSettings => _coreSettings!;
  ProfileService? _profile;
  ProfileService get profile => _profile!;
  MemoriesService? _memories;
  MemoriesService get memories => _memories!;
  NotificationsService? _notifications;
  NotificationsService get notifications => _notifications!;
  WebhooksService? _webhooks;
  WebhooksService get webhooks => _webhooks!;
  IntegrationsService? _integrations;
  IntegrationsService get integrations => _integrations!;
  LibreChatService? _libreChat;
  LibreChatService get libreChat => _libreChat!;
  CalendarService? _calendar;
  CalendarService get calendar => _calendar!;
  AutomationsService? _automations;
  AutomationsService get automations => _automations!;
  ReleaseNotesRpcService? _releaseNotes;
  ReleaseNotesRpcService get releaseNotes => _releaseNotes!;
  DataService? _data;
  DataService get data => _data!;
  ChatSettingsService? _chatSettings;
  ChatSettingsService get chatSettings => _chatSettings!;
  ValvesService? _valves;
  ValvesService get valves => _valves!;
  AccessService? _access;
  AccessService get access => _access!;
  FolderSettingsService? _folderSettings;
  FolderSettingsService get folderSettings => _folderSettings!;
  SpeechService? _speech;
  SpeechService get speech => _speech!;
  CallsService? _calls;
  CallsService get calls => _calls!;
  AppleModelsService? _apple;
  AppleModelsService get apple => _apple!;
  CapabilitiesService? _capabilities;

  TerminalsService? _terminals;
  ComputerRpcService? _computer;
  bool _transportsClosed = false;
  bool _speechStopped = false;
  bool _callsStopped = false;
  bool _disposed = false;

  /// Null once [closeTransports] has begun.
  TerminalsService? get terminals => _transportsClosed ? null : _terminals;
  ComputerRpcService? get computer => _transportsClosed ? null : _computer;

  /// What sessions see of the services: none until [attach] has built them,
  /// none of those [closeTransports] closes once it begins, and none at all
  /// once [dispose] begins.
  CoreServices get core => _core;
  CoreServices _core = const CoreServices();

  CoreServices _buildCore({required bool transports}) => CoreServices(
    accounts: _accounts,
    servers: _servers,
    auth: _auth,
    settings: _settings,
    chats: _chats,
    turns: _turns,
    models: _models,
    uiRequests: _uiRequests,
    chatPrompts: _chatPrompts,
    mcpApps: _mcpApps,
    hermesCards: _hermesCards,
    composer: _composer,
    prompts: _prompts,
    direct: _direct,
    mcp: _mcp,
    webSearch: _webSearch,
    notes: _notes,
    channels: _channels,
    workspace: _workspace,
    terminals: transports ? _terminals : null,
    computer: transports ? _computer : null,
    hermes: _hermes,
    hermesAdmin: _hermesAdmin,
    voice: _voice,
    dictation: _dictation,
    recordings: _recordings,
    coreSettings: _coreSettings,
    profile: _profile,
    memories: _memories,
    notifications: _notifications,
    webhooks: _webhooks,
    integrations: _integrations,
    libreChat: _libreChat,
    releaseNotes: _releaseNotes,
    data: transports ? _data : null,
    drafts: _drafts,
    chatSettings: _chatSettings,
    valves: _valves,
    access: _access,
    folderSettings: _folderSettings,
    speech: transports ? _speech : null,
    speechReports: _speechStopped ? null : _speech,
    callsReports: _callsStopped ? null : _calls,
    calls: transports ? _calls : null,
    apple: _apple,
    location: _ports.sharesAppContainer ? null : _ports.window.location,
    handoff: _handoff,
    calendar: _calendar,
    automations: _automations,
    hermesRooms: _hermesRooms,
  );

  /// A window's session over [channel]. The caller runs
  /// [RpcSession.listen], which closes the session when the channel ends.
  /// None opens once [dispose] has begun. [eventGate] is the transport's
  /// say over the events it is sent ([EventBus.attach]).
  RpcSession openSession(
    StreamChannel<String> channel, {
    required String sessionId,
    void Function(bool online)? reportNetwork,
    EventGate? eventGate,
  }) {
    if (_disposed) throw StateError('the protocol services are disposed');
    return RpcSession(
      sessionId: sessionId,
      channel: channel,
      system: system,
      events: events,
      services: () => core,
      reportNetwork: reportNetwork,
      eventGate: eventGate,
    );
  }

  /// Closes what holds sockets, streams or audio: calls, read-aloud,
  /// terminals, the computer view and data exports. First, before the
  /// host's own transport goes.
  Future<void> closeTransports() async {
    // Sessions lose these before the first wait, so a request meanwhile
    // cannot start again what is being closed.
    _transportsClosed = true;
    if (_attached && !_disposed) _core = _buildCore(transports: false);
    // The reading lets go before anything here waits (a call's stop can take
    // seconds), so a sentence ending meanwhile starts no next one. Its stop
    // asks the window, whose answer reaches it until the stop is done.
    final speechStopping = _speech?.dispose();
    try {
      // A call still starting finishes its start, on the window's answer,
      // before it stops.
      await _calls?.dispose();
    } finally {
      _callsStopped = true;
      await speechStopping;
    }
    _speechStopped = true;
    if (_attached && !_disposed) _core = _buildCore(transports: false);
    await _terminals?.dispose();
    await _computer?.dispose();
    await _data?.dispose();
  }

  /// Stops the services that hold chats and watches, all of them or those
  /// a failed [attach] built, while the core they read is still there:
  /// stopping an answer that is still running, and closing a chat that
  /// lingers after its answer, both read its container. The host disposes
  /// the core after this.
  Future<void> dispose() async {
    _disposed = true;
    // Sessions still open answer "unavailable" from here on.
    _core = const CoreServices();
    _accounts?.dispose();
    _servers?.dispose();
    _auth?.dispose();
    _notifications?.dispose();
    await _turns?.dispose();
    _queuedCompletions?.dispose();
    _mcpApps?.dispose();
    _hermesCards?.dispose();
    _hermesRooms?.dispose();
    _hermesAdmin?.dispose();
    // After the services built on it: its connection and watches.
    _hermes?.dispose();
    _ports.window.uiRequests.hermesChatOf = null;
    if (_uiRequests != null) _ports.window.uiRequests.detach();
    _chats?.dispose();
    _models?.dispose();
    _channels?.dispose();
    _coreSettings?.dispose();
    _ports.window.handoff.detach();
    // The window ports the host keeps reach none of this aggregate's
    // windows once it is gone.
    if (_apple != null) {
      _ports.window.apple.unbind();
      _ports.window.location.unbind();
    }
    if (_attached) _ports.window.openUrl.detach();
    _calendar?.dispose();
    _automations?.dispose();
    _capabilities?.dispose();
    // What windows still open were recording is kept for the next launch,
    // as their closing would have kept it: they no longer reach the
    // recordings service.
    await _recordings?.closeAll();
    // Waits for the recordings' writers: nothing writes once the database
    // closes.
    await _notes?.close();
    // Last, so what the services said while stopping still reached the
    // windows; work still in flight after this says nothing.
    events.close();
  }
}
