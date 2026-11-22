import 'package:conduit_core/ports/paths_port.dart';
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
import 'hermes_dashboard_cookies.dart';
import 'hermes_rooms_service.dart';
import 'hermes_service.dart';
import 'integrations_service.dart';
import 'librechat_service.dart';
import 'local_transcriber.dart';
import 'location_bridge.dart';
import 'mcp_apps_service.dart';
import 'mcp_service.dart';
import 'memories_service.dart';
import 'models_service.dart';
import 'notes_service.dart';
import 'notifications_service.dart';
import 'ports/handoff.dart';
import 'ports/open_url.dart';
import 'ports/ui_requests.dart';
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
import 'workspace_service.dart';

/// What the protocol's services need from their host besides the
/// container.
///
/// The window-backed ports are the ones the container's overrides were
/// built with: the services attach them to the windows once they exist.
final class ProtocolHostPorts {
  const ProtocolHostPorts({
    required this.uiRequests,
    required this.handoff,
    required this.openUrl,
    required this.calls,
    required this.apple,
    required this.location,
    this.paths,
    this.dashboardCookies,
    this.localTranscriber,
    this.chatScopeOverrides,
  });

  final DaemonUiRequestPort uiRequests;
  final DaemonHandoffPort handoff;
  final DaemonOpenUrlPort openUrl;
  final CallPorts calls;
  final AppleModelsBridge apple;
  final WindowLocationBridge location;

  /// Where a note's recordings wait for their upload; none without it.
  final PathsPort? paths;
  final DaemonHermesDashboardCookies? dashboardCookies;

  /// Transcription on this device; none without it.
  final LocalTranscriber? localTranscriber;

  /// What the host adds to every chat's scope, such as its schedulers.
  final List<Override> Function()? chatScopeOverrides;
}

/// The protocol's services over one container: built, wired to each other
/// and to the host's ports, and stopped in the order they depend on.
///
/// No transport and no process here. A host opens sessions over any
/// [StreamChannel] ([openSession]) and serves the byte routes from the
/// services it needs.
final class ProtocolServices {
  ProtocolServices._({
    required this.events,
    required this.system,
    required ProtocolHostPorts ports,
    required this.servers,
    required this.auth,
    required this.settings,
    required this.queuedCompletions,
    required this.hermes,
    required this.hermesRooms,
    required this.hermesAdmin,
    required this.chats,
    required this.files,
    required this.uiRequests,
    required this.chatPrompts,
    required this.turns,
    required this.hermesCards,
    required this.handoff,
    required this.drafts,
    required this.mcpApps,
    required this.accounts,
    required this.models,
    required this.composer,
    required this.prompts,
    required this.direct,
    required this.mcp,
    required this.webSearch,
    required this.notes,
    required this.channels,
    required this.workspace,
    required TerminalsService terminals,
    required ComputerRpcService computer,
    required this.voice,
    required this.dictation,
    required this.recordings,
    required this.coreSettings,
    required this.profile,
    required this.memories,
    required this.notifications,
    required this.webhooks,
    required this.integrations,
    required this.libreChat,
    required this.calendar,
    required this.automations,
    required this.releaseNotes,
    required this.data,
    required this.chatSettings,
    required this.valves,
    required this.access,
    required this.folderSettings,
    required this.speech,
    required this.calls,
    required this.apple,
  }) : _ports = ports,
       _terminals = terminals,
       _computer = computer;

  /// Builds every service over [container] and wires them together.
  ///
  /// [system] answers the handshake; it may have served sessions before
  /// now, and from now on carries what the account can use.
  factory ProtocolServices.compose(
    ProviderContainer container, {
    required EventBus events,
    required SystemService system,
    required ProtocolHostPorts ports,
  }) {
    final servers = ServersService(container, events: events);
    final auth = AuthService(container, events: events);
    final settings = SettingsService(container);
    final temporary = TemporaryChats();
    final queuedCompletions = QueuedCompletionsService(container, events);
    final hermes = HermesService(container, events: events);
    // Bot Mode and Group Chats; a bot's Bot Chat opens as its session.
    final hermesRooms = HermesRoomsService(
      container,
      events,
      connection: hermes.connection,
    );
    hermes.botChats = hermesRooms;
    final hermesAdmin = HermesAdminService(
      container,
      events: events,
      hermes: hermes,
      dashboardCookies: ports.dashboardCookies,
    );
    final chats = ChatsService(
      container,
      events: events,
      temporary: temporary,
      hermes: hermes,
      queued: queuedCompletions,
    );
    final files = FilesService(container);
    final uiRequests = UiRequestsService(events);
    // The core's own prompts, raised from any chat's turn, reach the windows
    // through the same broker.
    ports.uiRequests.attach(uiRequests);
    final chatPrompts = ChatPromptsService(events);
    final turns = TurnsService(
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
    ports.uiRequests.hermesChatOf = turns.hermesChatOf;
    // The list's unread dots and a chat's abilities read the turns.
    chats.turns = turns;
    // Changing the address in use asks first while one of them answers.
    servers.replies = turns;
    // A Hermes chat's agent cards: its work, its context, its questions.
    final hermesCards = HermesCardsService(
      container,
      events,
      hold: (chatId) => turns.holdScope(chatId),
      release: (chatId) => turns.releaseScope(chatId),
      uiRequests: uiRequests,
    );
    turns.hermesCards = hermesCards;
    // A server's `chat:handoff` for a chat the user is in: one answering
    // here, or one a window shows.
    final handoff = HandoffService(
      events,
      claims: (chatId) => turns.hasScope(chatId) || events.watches(chatId),
    );
    ports.handoff.attach(handoff);
    final drafts = DraftsService(container, temporary: temporary);
    final mcpApps = McpAppsService(container, events, uiRequests: uiRequests);
    final accounts = AccountsService(container, events: events, turns: turns);
    final models = ModelsService(container, events: events);
    final composer = ComposerService(container);
    final prompts = PromptsService(container);
    final direct = DirectService(container);
    final mcp = McpService(container);
    final webSearch = WebSearchService(container);
    final notes = NotesService(container, events: events, paths: ports.paths);
    final channels = ChannelsService(container, events: events);
    final workspace = WorkspaceService(container, events: events);
    final terminals = TerminalsService(
      container,
      events: events,
      modelFor: models.modelFor,
    );
    final computer = ComputerRpcService(container, modelFor: models.modelFor);
    final voice = VoiceService(
      container,
      events: events,
      local: ports.localTranscriber,
    );
    final dictation = DictationService(container, voice: voice);
    final recordings = RecordingsService(drafts: drafts, dictation: dictation);
    final coreSettings = CoreSettingsService(container, events: events);
    final profile = ProfileService(container, accounts: accounts);
    final memories = MemoriesService(container);
    final notifications = NotificationsService(
      container,
      events: events,
      announced: turns.announced,
    );
    final webhooks = WebhooksService(container);
    final integrations = IntegrationsService(container);
    final libreChat = LibreChatService(
      container,
      events: events,
      accounts: accounts,
    );
    final calendar = CalendarService(container, events: events);
    final automations = AutomationsService(container, events: events);
    final releaseNotes = ReleaseNotesRpcService(container);
    final data = DataService(container, events: events);
    final chatSettings = ChatSettingsService(
      container,
      scopeOf: (chatId) => turns.scopeOf(chatId),
    );
    chats.chatSettings = chatSettings;
    final valves = ValvesService(container);
    final access = AccessService(container, workspace: workspace);
    final folderSettings = FolderSettingsService(container, events: events);
    final speech = SpeechService(
      container,
      events: events,
      voice: voice,
      answerFor: chats.answerFor,
    );
    final calls = CallsService(
      container,
      events: events,
      turns: turns,
      ports: ports.calls,
      speech: speech,
    );
    // Apple's on-device model: the chat runs here, the model in the window.
    ports.apple.bind(events);
    // `{{USER_LOCATION}}`: the window asks the device's location services.
    ports.location.bind(events);
    final apple = AppleModelsService(container, bridge: ports.apple);
    voice.speechOfChat = (chatId) async =>
        SpeechService.speechForModel(container, await chats.modelOf(chatId));
    final services = ProtocolServices._(
      events: events,
      system: system,
      ports: ports,
      servers: servers,
      auth: auth,
      settings: settings,
      queuedCompletions: queuedCompletions,
      hermes: hermes,
      hermesRooms: hermesRooms,
      hermesAdmin: hermesAdmin,
      chats: chats,
      files: files,
      uiRequests: uiRequests,
      chatPrompts: chatPrompts,
      turns: turns,
      hermesCards: hermesCards,
      handoff: handoff,
      drafts: drafts,
      mcpApps: mcpApps,
      accounts: accounts,
      models: models,
      composer: composer,
      prompts: prompts,
      direct: direct,
      mcp: mcp,
      webSearch: webSearch,
      notes: notes,
      channels: channels,
      workspace: workspace,
      terminals: terminals,
      computer: computer,
      voice: voice,
      dictation: dictation,
      recordings: recordings,
      coreSettings: coreSettings,
      profile: profile,
      memories: memories,
      notifications: notifications,
      webhooks: webhooks,
      integrations: integrations,
      libreChat: libreChat,
      calendar: calendar,
      automations: automations,
      releaseNotes: releaseNotes,
      data: data,
      chatSettings: chatSettings,
      valves: valves,
      access: access,
      folderSettings: folderSettings,
      speech: speech,
      calls: calls,
      apple: apple,
    );
    // What the active account can use: answered by `system.capabilities`
    // and the handshake, announced on change.
    services._capabilities = CapabilitiesService(
      container,
      events: events,
      onChange: (capabilities) => system.capabilities = capabilities,
    );
    // An MCP sign-in opens the provider's page through a window.
    ports.openUrl.attach(events);
    return services;
  }

  final EventBus events;
  final SystemService system;
  final ProtocolHostPorts _ports;

  final ServersService servers;
  final AuthService auth;
  final SettingsService settings;
  final QueuedCompletionsService queuedCompletions;
  final HermesService hermes;
  final HermesRoomsService hermesRooms;
  final HermesAdminService hermesAdmin;
  final ChatsService chats;
  final FilesService files;
  final UiRequestsService uiRequests;
  final ChatPromptsService chatPrompts;
  final TurnsService turns;
  final HermesCardsService hermesCards;
  final HandoffService handoff;
  final DraftsService drafts;
  final McpAppsService mcpApps;
  final AccountsService accounts;
  final ModelsService models;
  final ComposerService composer;
  final PromptsService prompts;
  final DirectService direct;
  final McpService mcp;
  final WebSearchService webSearch;
  final NotesService notes;
  final ChannelsService channels;
  final WorkspaceService workspace;
  final VoiceService voice;
  final DictationService dictation;
  final RecordingsService recordings;
  final CoreSettingsService coreSettings;
  final ProfileService profile;
  final MemoriesService memories;
  final NotificationsService notifications;
  final WebhooksService webhooks;
  final IntegrationsService integrations;
  final LibreChatService libreChat;
  final CalendarService calendar;
  final AutomationsService automations;
  final ReleaseNotesRpcService releaseNotes;
  final DataService data;
  final ChatSettingsService chatSettings;
  final ValvesService valves;
  final AccessService access;
  final FolderSettingsService folderSettings;
  final SpeechService speech;
  final CallsService calls;
  final AppleModelsService apple;
  late final CapabilitiesService _capabilities;

  final TerminalsService _terminals;
  final ComputerRpcService _computer;
  bool _transportsClosed = false;

  /// Null once [closeTransports] has closed them.
  TerminalsService? get terminals => _transportsClosed ? null : _terminals;
  ComputerRpcService? get computer => _transportsClosed ? null : _computer;

  /// What sessions see of the services.
  late final CoreServices core = CoreServices(
    accounts: accounts,
    servers: servers,
    auth: auth,
    settings: settings,
    chats: chats,
    turns: turns,
    models: models,
    uiRequests: uiRequests,
    chatPrompts: chatPrompts,
    mcpApps: mcpApps,
    hermesCards: hermesCards,
    composer: composer,
    prompts: prompts,
    direct: direct,
    mcp: mcp,
    webSearch: webSearch,
    notes: notes,
    channels: channels,
    workspace: workspace,
    terminals: _terminals,
    computer: _computer,
    hermes: hermes,
    hermesAdmin: hermesAdmin,
    voice: voice,
    dictation: dictation,
    recordings: recordings,
    coreSettings: coreSettings,
    profile: profile,
    memories: memories,
    notifications: notifications,
    webhooks: webhooks,
    integrations: integrations,
    libreChat: libreChat,
    releaseNotes: releaseNotes,
    data: data,
    drafts: drafts,
    chatSettings: chatSettings,
    valves: valves,
    access: access,
    folderSettings: folderSettings,
    speech: speech,
    calls: calls,
    apple: apple,
    location: _ports.location,
    handoff: handoff,
    calendar: calendar,
    automations: automations,
    hermesRooms: hermesRooms,
  );

  /// A window's session over [channel]. The caller runs
  /// [RpcSession.listen], which closes the session when the channel ends.
  RpcSession openSession(
    StreamChannel<String> channel, {
    required String sessionId,
    void Function(bool online)? reportNetwork,
  }) => RpcSession(
    sessionId: sessionId,
    channel: channel,
    system: system,
    events: events,
    services: () => core,
    reportNetwork: reportNetwork,
  );

  /// Closes what holds sockets, streams or audio: calls, read-aloud,
  /// terminals, the computer view and data exports. First, before the
  /// host's own transport goes.
  Future<void> closeTransports() async {
    await calls.dispose();
    await speech.dispose();
    await _terminals.dispose();
    await _computer.dispose();
    await data.dispose();
    _transportsClosed = true;
  }

  /// Stops the services that hold chats and watches, while the core they
  /// read is still there: stopping an answer that is still running, and
  /// closing a chat that lingers after its answer, both read its container.
  /// The host disposes the core after this.
  Future<void> dispose() async {
    accounts.dispose();
    servers.dispose();
    auth.dispose();
    notifications.dispose();
    await turns.dispose();
    queuedCompletions.dispose();
    mcpApps.dispose();
    hermesCards.dispose();
    hermesRooms.dispose();
    hermesAdmin.dispose();
    _ports.uiRequests.hermesChatOf = null;
    chats.dispose();
    _ports.handoff.detach();
    calendar.dispose();
    automations.dispose();
    _capabilities.dispose();
    // Waits for the recordings' writers: nothing writes once the database
    // closes.
    await notes.close();
  }
}
