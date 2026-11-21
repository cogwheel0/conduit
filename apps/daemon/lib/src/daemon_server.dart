import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:conduit_core/providers/app_providers.dart'
    show activeServerProvider;
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show preferredBackendProvider;
import 'package:conduit_core/services/api_service.dart'
    show FileContentTooLargeException;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'accounts_service.dart';
import 'auth_service.dart';
import 'bootstrap.dart';
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
import 'queued_completions_service.dart';
import 'core_runtime.dart';
import 'redact.dart';
import 'daemon_paths.dart';
import 'event_bus.dart';
import 'files_service.dart';
import 'media_service.dart';
import 'settled.dart';
import 'log.dart';
import 'rpc_session.dart';
import 'temporary_chats.dart';
import 'ui_requests_service.dart';
import 'models_service.dart';
import 'servers_service.dart';
import 'settings_service.dart';
import 'capabilities_service.dart';
import 'system_service.dart';
import 'turns_service.dart';
import 'valves_service.dart';
import 'web_search_service.dart';
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
import 'calls_service.dart';
import 'speech_service.dart';
import 'voice_service.dart';
import 'dictation_service.dart';
import 'recordings_service.dart';
import 'core_settings_service.dart';
import 'data_service.dart';
import 'access_service.dart';
import 'chat_settings_service.dart';
import 'folder_settings_service.dart';
import 'librechat_service.dart';
import 'integrations_service.dart';
import 'memories_service.dart';
import 'notifications_service.dart';
import 'webhooks_service.dart';
import 'profile_service.dart';
import 'release_notes_rpc_service.dart';

/// The loopback server the desktop app talks to.
///
/// Binds `127.0.0.1:0` so the OS picks a free port and nothing is reachable
/// off-machine. The port is reported to the app on stdout; there is no
/// fixed port to squat on or collide with.
class DaemonServer {
  DaemonServer({
    required this.config,
    required this.directories,
    required this.daemonVersion,
    required DaemonLog log,
  }) : _log = log {
    _system = SystemService(
      directories: directories,
      daemonVersion: daemonVersion,
      log: log,
      requestStop: requestStop,
      needsOnboarding: () async =>
          await (await _coreSoon())?.needsOnboarding() ?? false,
      flushOutbox: () async => await _core?.flushOutbox() ?? 0,
      configSnapshot: _configSnapshot,
      secrets: <String>[config.sessionToken, config.masterKey],
    );
  }

  final BootstrapConfig config;
  final DaemonDirectories directories;
  final String daemonVersion;
  final DaemonLog _log;

  late final SystemService _system;

  /// Set by [attachCore]. Sessions opened before it arrives answer
  /// `servers.*` and `auth.*` with `rpc.daemonUnavailable` rather than with a
  /// plausible-looking empty result.
  CoreRuntime? _core;

  /// Completed by [attachCore], or with null when the daemon stops first.
  /// Only waited on after [coreStarting].
  Completer<CoreRuntime?>? _coreComing;
  AccountsService? _accounts;
  ServersService? _servers;
  AuthService? _auth;
  SettingsService? _settings;
  ChatsService? _chats;
  HandoffService? _handoff;
  CalendarService? _calendar;
  AutomationsService? _automations;
  TurnsService? _turns;
  ModelsService? _models;
  FilesService? _files;

  /// `GET /media/{image|pdf}`: no core needed, so it answers from the start
  /// (the account's server, once there is one, is reached as it is).
  late final MediaService _media = MediaService(ownServer: _activeServerUrl);

  /// The active account's server address, for `/media`; null before the
  /// core or without a server (Direct, Hermes).
  Future<Uri?> _activeServerUrl() async {
    final core = _core;
    if (core == null) return null;
    final server = await readSettled(
      core.container,
      activeServerProvider.future,
    );
    return server == null ? null : Uri.tryParse(server.url);
  }

  UiRequestsService? _uiRequests;
  ChatPromptsService? _chatPrompts;
  QueuedCompletionsService? _queuedCompletions;
  McpAppsService? _mcpApps;
  HermesCardsService? _hermesCards;
  HermesRoomsService? _hermesRooms;
  ComposerService? _composer;
  DraftsService? _drafts;
  PromptsService? _prompts;
  DirectService? _direct;
  McpService? _mcp;
  WebSearchService? _webSearch;
  NotesService? _notes;
  ChannelsService? _channels;
  WorkspaceService? _workspace;
  TerminalsService? _terminals;
  ComputerRpcService? _computer;
  HermesService? _hermes;
  HermesAdminService? _hermesAdmin;
  VoiceService? _voice;
  DictationService? _dictation;
  RecordingsService? _recordings;
  CapabilitiesService? _capabilities;
  CoreSettingsService? _coreSettings;
  ProfileService? _profile;
  MemoriesService? _memories;
  NotificationsService? _notifications;
  WebhooksService? _webhooks;
  IntegrationsService? _integrations;
  LibreChatService? _libreChat;
  ChatSettingsService? _chatSettings;
  ValvesService? _valves;
  AccessService? _access;
  FolderSettingsService? _folderSettings;
  SpeechService? _readAloud;
  CallsService? _calls;
  AppleModelsService? _apple;
  ReleaseNotesRpcService? _releaseNotes;
  DataService? _data;

  /// What sessions see of the services above: none until [attachCore].
  CoreServices _coreServices = const CoreServices();

  /// The broker the core asks its questions through. Exposed so tests can
  /// ask one and watch it cross the RPC boundary.
  UiRequestsService? get uiRequests => _uiRequests;

  final EventBus events = EventBus();
  final Map<String, RpcSession> _sessions = <String, RpcSession>{};
  final Random _random = Random.secure();

  HttpServer? _server;
  final Completer<void> _stopped = Completer<void>();
  Future<void>? _stopping;

  /// Resolves when the daemon has finished shutting down.
  Future<void> get onStopped => _stopped.future;

  int get port => _server?.port ?? 0;

  /// Live sessions. Exposed for the heartbeat watchdog and for tests.
  Iterable<RpcSession> get sessions => _sessions.values;

  Future<int> start() async {
    final handler = const shelf.Pipeline()
        .addMiddleware(_authGate())
        .addHandler(_route);
    _server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
    _log.info('listening on 127.0.0.1:${_server!.port}');
    return _server!.port;
  }

  /// Hands the running core to this server.
  ///
  /// Separate from [start] because the socket has to be listening before the
  /// core finishes booting: the desktop app needs the port on stdout to
  /// connect its window, and the core's startup includes reading a database
  /// off disk.
  /// Sessions that connect in between are real sessions -- they can
  /// handshake and ping -- they simply cannot reach state that does not
  /// exist yet.
  void attachCore(CoreRuntime core) {
    _core = core;
    final coming = _coreComing;
    if (coming != null && !coming.isCompleted) coming.complete(core);
    _servers = ServersService(core.container, events: events);
    _auth = AuthService(core.container, events: events);
    _settings = SettingsService(core.container);
    final temporary = TemporaryChats();
    _queuedCompletions = QueuedCompletionsService(core.container, events);
    _hermes = HermesService(core.container, events: events);
    // Bot Mode and Group Chats; a bot's Bot Chat opens as its session.
    _hermesRooms = HermesRoomsService(
      core.container,
      events,
      connection: _hermes!.connection,
    );
    _hermes!.botChats = _hermesRooms;
    _hermesAdmin = HermesAdminService(
      core.container,
      events: events,
      hermes: _hermes,
      dashboardCookies: core.dashboardCookies,
    );
    _chats = ChatsService(
      core.container,
      events: events,
      temporary: temporary,
      hermes: _hermes,
      queued: _queuedCompletions,
    );
    _files = FilesService(core.container);
    _uiRequests = UiRequestsService(events);
    // The core's own prompts, raised from any chat's turn, reach the windows
    // through the same broker.
    core.uiRequests.attach(_uiRequests!);
    _chatPrompts = ChatPromptsService(events);
    _turns = TurnsService(
      core.container,
      events,
      temporary: temporary,
      uiRequests: _uiRequests,
      hermes: _hermes,
      files: _files,
      chatPrompts: _chatPrompts,
      queued: _queuedCompletions,
    );
    // A Hermes model switch is asked as the question of the chat holding
    // its session.
    core.uiRequests.hermesChatOf = _turns!.hermesChatOf;
    // The list's unread dots and a chat's abilities read the turns.
    _chats!.turns = _turns;
    // Changing the address in use asks first while one of them answers.
    _servers!.replies = _turns;
    // A Hermes chat's agent cards: its work, its context, its questions.
    _hermesCards = HermesCardsService(
      core.container,
      events,
      hold: (chatId) => _turns!.holdScope(chatId),
      release: (chatId) => _turns?.releaseScope(chatId),
      uiRequests: _uiRequests,
    );
    _turns!.hermesCards = _hermesCards;
    // A server's `chat:handoff` for a chat the user is in: one answering
    // here, or one a window shows.
    _handoff = HandoffService(
      events,
      claims: (chatId) =>
          (_turns?.hasScope(chatId) ?? false) || events.watches(chatId),
    );
    core.handoff.attach(_handoff!);
    _drafts = DraftsService(core.container, temporary: temporary);
    _mcpApps = McpAppsService(core.container, events, uiRequests: _uiRequests);
    _accounts = AccountsService(core.container, events: events, turns: _turns);
    _models = ModelsService(core.container, events: events);
    _composer = ComposerService(core.container);
    _prompts = PromptsService(core.container);
    _direct = DirectService(core.container);
    _mcp = McpService(core.container);
    _webSearch = WebSearchService(core.container);
    _notes = NotesService(
      core.container,
      events: events,
      paths: core.directories,
    );
    _channels = ChannelsService(core.container, events: events);
    _workspace = WorkspaceService(core.container, events: events);
    final models = _models!;
    _terminals = TerminalsService(
      core.container,
      log: _log,
      events: events,
      modelFor: models.modelFor,
    );
    _computer = ComputerRpcService(
      core.container,
      log: _log,
      modelFor: models.modelFor,
    );
    _voice = VoiceService(
      core.container,
      events: events,
      whisperDirectory: Directory(
        p.join(core.directories.paths.userData, 'whisper'),
      ),
    );
    _dictation = DictationService(core.container, voice: _voice!);
    _recordings = RecordingsService(drafts: _drafts!, dictation: _dictation!);
    _coreSettings = CoreSettingsService(core.container, events: events);
    _profile = ProfileService(core.container, accounts: _accounts);
    _memories = MemoriesService(core.container);
    _notifications = NotificationsService(
      core.container,
      events: events,
      announced: _turns!.announced,
    );
    _webhooks = WebhooksService(core.container);
    _integrations = IntegrationsService(core.container);
    _libreChat = LibreChatService(
      core.container,
      events: events,
      accounts: _accounts!,
    );
    _calendar = CalendarService(core.container, events: events);
    _automations = AutomationsService(core.container, events: events);
    _releaseNotes = ReleaseNotesRpcService(core.container);
    _data = DataService(core.container, events: events);
    _chatSettings = ChatSettingsService(
      core.container,
      scopeOf: (chatId) => _turns?.scopeOf(chatId),
    );
    _chats?.chatSettings = _chatSettings;
    _valves = ValvesService(core.container);
    _access = AccessService(core.container, workspace: _workspace);
    _folderSettings = FolderSettingsService(core.container, events: events);
    final chats = _chats;
    _readAloud = SpeechService(
      core.container,
      events: events,
      voice: _voice!,
      answerFor: chats?.answerFor,
    );
    _calls = CallsService(
      core.container,
      events: events,
      turns: _turns!,
      ports: core.calls,
      speech: _readAloud,
    );
    // Apple's on-device model: the chat runs here, the model in the window.
    core.apple.bind(events);
    // `{{USER_LOCATION}}`: the window asks the Mac's location services.
    core.location.bind(events);
    _apple = AppleModelsService(core.container, bridge: core.apple);
    if (chats != null) {
      _voice!.speechOfChat = (chatId) async => SpeechService.speechForModel(
        core.container,
        await chats.modelOf(chatId),
      );
    }
    // Every session reads this, including one that connected before now.
    _coreServices = CoreServices(
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
      terminals: _terminals,
      computer: _computer,
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
      data: _data,
      drafts: _drafts,
      chatSettings: _chatSettings,
      valves: _valves,
      access: _access,
      folderSettings: _folderSettings,
      speech: _readAloud,
      calls: _calls,
      apple: _apple,
      location: core.location,
      handoff: _handoff,
      calendar: _calendar,
      automations: _automations,
      hermesRooms: _hermesRooms,
    );
    // What the active account can use: answered by `system.capabilities`
    // and the handshake, announced on change.
    _capabilities = CapabilitiesService(
      core.container,
      events: events,
      onChange: (capabilities) => _system.capabilities = capabilities,
    );
    // An MCP sign-in opens the provider's page through a window.
    core.openUrl.attach(events);
    _log.info('core attached');
  }

  /// Says the core is on its way, so a handshake made before it attaches
  /// waits for it (up to 3 s) rather than answer `needsOnboarding` with
  /// "nobody knows yet".
  ///
  /// The app connects the moment it reads the ready line, which is before
  /// the core has read its storage, so without this the first handshake of
  /// nearly every launch would get that non-answer.
  void coreStarting() {
    if (_core != null) return;
    _coreComing ??= Completer<CoreRuntime?>();
  }

  /// The core, waiting for it a little while it is starting.
  Future<CoreRuntime?> _coreSoon() async {
    final core = _core;
    if (core != null) return core;
    final coming = _coreComing;
    if (coming == null) return null;
    return coming.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
  }

  /// Rejects anything that is not the desktop app, before routing.
  ///
  /// Two independent checks, because each covers a gap in the other:
  ///
  /// * **Origin** stops a page in a real browser from opening a socket. The
  ///   browser sets it and will not let script forge it.
  /// * **Token** stops any other local process, which can set any header it
  ///   likes but cannot read a secret passed to us on stdin.
  ///
  /// `shelf_web_socket`'s own `allowedOrigins` is not used: it only checks
  /// `Origin` when the header is present, so a non-browser client passes by
  /// omitting it. Here a missing `Origin` on `/rpc` is a rejection.
  shelf.Middleware _authGate() => (shelf.Handler inner) {
    return (shelf.Request request) async {
      final path = '/${request.url.path}';
      final isWebSocketRoute =
          path == ConduitHttpRoutes.rpc ||
          path.startsWith('/terminal/') ||
          path.startsWith('/calls/');

      if (isWebSocketRoute) {
        if (!isAllowedOrigin(request.headers['origin'])) {
          _log.warn('rejected $path: bad origin ${request.headers['origin']}');
          return shelf.Response.forbidden('invalid origin');
        }
        // Shelf joins repeated headers with ", "; the browser sends the
        // subprotocol list that way too.
        final offered = (request.headers['sec-websocket-protocol'] ?? '')
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty);
        final presented = extractSessionToken(offered);
        if (presented == null ||
            !constantTimeEquals(presented, config.sessionToken)) {
          _log.warn('rejected $path: bad or missing session token');
          return shelf.Response.forbidden('invalid session token');
        }
        return inner(request);
      }

      // A preflight, which is what the renderer's upload triggers: it
      // sends `Authorization` and `x-conduit-filename`, and any header
      // beyond the safelisted ones makes the browser ask permission first.
      //
      // Answered before the token check, and it has to be: a preflight
      // never carries the request's headers, so demanding the token here
      // would reject the question that asks whether the token is allowed.
      // That is not a hole -- a preflight reveals only what this endpoint
      // accepts, the `Origin` is still pinned to the app, and the real
      // request that follows is checked below like any other.
      if (request.method == 'OPTIONS') {
        if (!isAllowedOrigin(request.headers['origin'])) {
          return shelf.Response.forbidden('invalid origin');
        }
        return shelf.Response.ok(null, headers: _corsHeaders);
      }

      // Plain HTTP endpoints carry the token in an `Authorization` header,
      // which the desktop app sends with every request it makes here.
      final authorization = request.headers['authorization'] ?? '';
      const scheme = 'Bearer ';
      if (!authorization.startsWith(scheme) ||
          !constantTimeEquals(
            authorization.substring(scheme.length),
            config.sessionToken,
          )) {
        _log.warn('rejected $path: bad or missing bearer token');
        return shelf.Response.unauthorized('invalid session token');
      }
      return inner(request);
    };
  };

  /// What the renderer is allowed to send, and nothing wider.
  ///
  /// The origin is named rather than `*`: `app://conduit` is the only page
  /// that may reach this daemon at all, and a wildcard would additionally
  /// let any website's script read the responses if one ever found the
  /// port.
  static const Map<String, String> _corsHeaders = <String, String>{
    'access-control-allow-origin': kConduitAppOrigin,
    'access-control-allow-methods': 'POST, GET, OPTIONS',
    'access-control-allow-headers':
        'authorization, content-type, '
        'x-conduit-filename, x-conduit-terminal, x-conduit-directory',
    'access-control-max-age': '600',
  };

  Future<shelf.Response> _route(shelf.Request request) async {
    final path = '/${request.url.path}';
    if (path == ConduitHttpRoutes.rpc) return _rpcHandler(request);
    if (path == ConduitHttpRoutes.upload) return _upload(request);
    if (path == ConduitHttpRoutes.terminalUpload) {
      return _terminalUpload(request);
    }
    if (path.startsWith('/terminal/')) return _terminalTunnel(request, path);
    if (path.startsWith('/calls/')) return _callAudio(request, path);
    if (path.startsWith('/files/')) return _file(request);
    if (path.startsWith('${ConduitHttpRoutes.media}/')) {
      return _mediaFetch(request, path);
    }
    if (path == ConduitHttpRoutes.transcribe) return _transcribe(request);
    if (path.startsWith('/recordings/')) return _recording(request, path);
    if (path.startsWith('/tts/')) return _speech(request, path);
    if (path == '/health') {
      // Authenticated liveness probe for a supervisor; it does not
      // reveal anything a holder of the token cannot already ask for on /rpc.
      return shelf.Response.ok(
        jsonEncode(<String, Object>{
          'ok': true,
          'protocolVersion': kConduitProtocolVersion,
          'daemonVersion': daemonVersion,
          'sessions': _sessions.length,
        }),
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return shelf.Response.notFound('no such endpoint');
  }

  /// `WS /terminal/{handle}` -- a shell, through the daemon. The auth
  /// gate has checked the origin and the session token already; an unknown
  /// handle is refused before the upgrade.
  Future<shelf.Response> _terminalTunnel(
    shelf.Request request,
    String path,
  ) async {
    final terminals = _terminals;
    final handle = path.substring('/terminal/'.length);
    if (terminals == null || !terminals.knows(handle)) {
      return shelf.Response.notFound('no such terminal');
    }
    return webSocketHandler(
      (WebSocketChannel socket, String? _) =>
          unawaited(terminals.tunnel(handle, socket)),
      protocols: const <String>{negotiatedSubprotocol},
      pingInterval: const Duration(seconds: 25),
    )(request);
  }

  /// `WS /calls/{handle}` -- a realtime call's audio, with the window. The
  /// auth gate has checked the origin and the session token already; a
  /// handle that is not the call's now is refused before the upgrade.
  Future<shelf.Response> _callAudio(shelf.Request request, String path) async {
    final calls = _calls;
    final handle = path.substring('/calls/'.length);
    if (calls == null || !calls.knowsAudio(handle)) {
      return shelf.Response.notFound('no such call');
    }
    return webSocketHandler(
      (WebSocketChannel socket, String? _) =>
          unawaited(calls.tunnel(handle, socket)),
      protocols: const <String>{negotiatedSubprotocol},
      pingInterval: const Duration(seconds: 25),
    )(request);
  }

  /// `POST /terminal-upload` -- a file into a terminal's machine.
  /// The same body as `/upload`; the handle and directory come in headers.
  Future<shelf.Response> _terminalUpload(shelf.Request request) async {
    final terminals = _terminals;
    if (terminals == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'POST') {
      return shelf.Response(405, body: 'POST only');
    }
    final String name;
    final String directory;
    try {
      name = Uri.decodeComponent(request.headers['x-conduit-filename'] ?? '');
      directory = Uri.decodeComponent(
        request.headers['x-conduit-directory'] ?? '',
      );
    } on FormatException {
      return _problem(400, ConduitErrorCodes.invalidParams, 'bad headers');
    }
    final handle = request.headers['x-conduit-terminal'] ?? '';
    if (name.trim().isEmpty || directory.isEmpty || handle.isEmpty) {
      return _problem(
        400,
        ConduitErrorCodes.invalidParams,
        'needs x-conduit-filename, -terminal and -directory',
      );
    }
    try {
      final bytes = await _collect(request.read());
      await terminals.upload(
        handle: handle,
        directory: directory,
        name: name,
        bytes: bytes,
      );
      // An UploadedFile, as /upload answers; the id is where it went.
      return shelf.Response.ok(
        jsonEncode(
          UploadedFile(
            id: '$directory$name',
            name: name,
            size: bytes.length,
          ).toJson(),
        ),
        headers: <String, String>{
          'content-type': 'application/json',
          ..._corsHeaders,
        },
      );
    } on RpcError catch (error) {
      final status = switch (error.code) {
        ConduitErrorCodes.notFound => 404,
        ConduitErrorCodes.unauthenticated => 401,
        _ => 502,
      };
      return _problem(status, error.code, error.debugMessage);
    } on Object catch (error, stack) {
      _log.error('terminal upload failed', error, stack);
      return _problem(502, ConduitErrorCodes.serverError, 'upload failed');
    }
  }

  /// `POST /upload` -- an attachment on its way to the server.
  ///
  /// The body is the file's bytes and nothing else. No multipart parsing
  /// here: both ends of this request are ours, the daemon re-wraps the
  /// bytes for Open WebUI anyway, and a parser is a surface that would earn
  /// its keep only if some other client were posting to us.
  ///
  /// The name travels in a header because a body that is *only* bytes is
  /// what lets the whole thing stream. It is percent-encoded: a header is
  /// Latin-1 by definition, and an attachment called `résumé.pdf` would
  /// otherwise be rejected by the HTTP layer before this code ran.
  Future<shelf.Response> _upload(shelf.Request request) async {
    final files = _files;
    if (files == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'POST') {
      return shelf.Response(405, body: 'POST only');
    }

    final rawName = request.headers['x-conduit-filename'];
    if (rawName == null || rawName.trim().isEmpty) {
      return _problem(
        400,
        ConduitErrorCodes.invalidParams,
        'missing x-conduit-filename',
      );
    }
    final String name;
    try {
      name = Uri.decodeComponent(rawName);
    } on FormatException {
      return _problem(
        400,
        ConduitErrorCodes.invalidParams,
        'x-conduit-filename is not percent-encoded',
      );
    }

    // Which try this is, for the core's retry rules (1 for the first).
    final attempt =
        int.tryParse(request.headers['x-conduit-attempt'] ?? '') ?? 1;
    // The account the request began under: a body still arriving when
    // another signs in never goes to the next account's server.
    final session = files.session();
    try {
      final bytes = await _collect(request.read());
      final uploaded = await files.upload(
        name: name,
        bytes: bytes,
        session: session,
        contentType: request.headers['content-type'],
        // A channel's attachment: filed under the channel so its members
        // may read it.
        channelId: request.headers['x-conduit-channel'],
      );
      return shelf.Response.ok(
        jsonEncode(uploaded.toJson()),
        headers: <String, String>{
          'content-type': 'application/json',
          ..._corsHeaders,
        },
      );
    } on RpcError catch (error) {
      final status = switch (error.code) {
        ConduitErrorCodes.unauthenticated => 401,
        ConduitErrorCodes.invalidParams => 400,
        _ => 502,
      };
      return _problem(status, error.code, error.debugMessage);
    } on Object catch (error, stack) {
      _log.error('upload failed', error, stack);
      return _problem(
        502,
        ConduitErrorCodes.serverError,
        'upload failed',
        args: uploadRetryArgs(error, attempt),
      );
    }
  }

  /// `GET /files/{serverId}/{fileId}` -- an attachment's bytes, for an image
  /// in a message; `GET /files/{serverId}/models/{modelId}` -- a model's
  /// profile image.
  ///
  /// The desktop app sends the daemon's token with it, as with every request
  /// to this port, so the daemon refuses anyone else.
  Future<shelf.Response> _file(shelf.Request request) async {
    final files = _files;
    if (files == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'GET') {
      return shelf.Response(405, body: 'GET only');
    }
    final segments = request.url.pathSegments;
    final modelImage = segments.length == 4 && segments[2] == 'models';
    if (segments.length != 3 && !modelImage) {
      return _problem(404, ConduitErrorCodes.notFound, 'no such file');
    }
    try {
      // `/files/{server}/models/{model}`: a model's profile image.
      final file = modelImage
          ? await files.modelImage(segments[1], segments[3])
          : await files.download(segments[1], segments[2]);
      return shelf.Response.ok(
        file.bytes,
        headers: <String, String>{
          'content-type': file.contentType,
          // Taken as given: a file claiming to be bytes must never be read
          // as HTML because its first line looks like some.
          'x-content-type-options': 'nosniff',
          'content-disposition': 'inline',
          // Private: it is the user's file. An hour: the same image is drawn
          // every time the conversation is opened.
          'cache-control': 'private, max-age=3600',
          ..._corsHeaders,
        },
      );
    } on RpcError catch (error) {
      final status = switch (error.code) {
        ConduitErrorCodes.invalidParams => 400,
        ConduitErrorCodes.unauthenticated => 401,
        ConduitErrorCodes.notFound => 404,
        _ => 502,
      };
      return _problem(status, error.code, error.debugMessage);
    } on FileContentTooLargeException {
      return _problem(413, ConduitErrorCodes.invalidParams, 'file too large');
    } on Object catch (error, stack) {
      _log.error('file download failed', error, stack);
      return _problem(502, ConduitErrorCodes.serverError, 'download failed');
    }
  }

  /// `GET /media/{image|pdf}?url=` -- a picture or a PDF on another site,
  /// for the window (see [MediaService] for what is and is not sent).
  /// Answered with its bytes and type, or a problem whose code says why
  /// not (`media.tooLarge`, `media.wrongType`, `media.timedOut`, ...).
  Future<shelf.Response> _mediaFetch(shelf.Request request, String path) async {
    if (request.method != 'GET') {
      return shelf.Response(405, body: 'GET only');
    }
    final kind = switch (path.substring(ConduitHttpRoutes.media.length + 1)) {
      'image' => MediaKind.image,
      'pdf' => MediaKind.pdf,
      _ => null,
    };
    final url = request.url.queryParameters['url'];
    if (kind == null || url == null) {
      return _problem(404, ConduitErrorCodes.notFound, 'no such media');
    }
    try {
      final media = await _media.fetch(url, kind);
      return shelf.Response.ok(
        media.bytes,
        headers: <String, String>{
          'content-type': media.contentType,
          'x-content-type-options': 'nosniff',
          'content-disposition': 'inline',
          // The window keeps what it drew; nothing here outlives the reply.
          'cache-control': 'no-store',
          ..._corsHeaders,
        },
      );
    } on MediaFetchException catch (error) {
      // The failure only: the address is the chat's, not the log's.
      _log.info('media ${kind.name}: ${error.failure.name}');
      return _problem(
        error.failure.status,
        error.failure.code,
        error.failure.name,
      );
    }
  }

  /// `POST /transcribe` -- a recording, as text. The body is the
  /// recording and nothing else; its type is the content type. The query
  /// may name the engine (`engine=server|local`) and the chat's model
  /// (`model=`), whose backend transcribes on the server.
  Future<shelf.Response> _transcribe(shelf.Request request) async {
    final dictation = _dictation;
    if (dictation == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'POST') {
      return shelf.Response(405, body: 'POST only');
    }
    final query = request.url.queryParameters;
    // The account the request began under: audio still arriving when
    // another signs in never goes to the next account's backend.
    final session = dictation.session();
    try {
      final transcript = await dictation.transcribe(
        await _collect(request.read()),
        contentType: request.headers['content-type'],
        engine: _nonEmpty(query['engine']),
        modelId: _nonEmpty(query['model']),
        session: session,
      );
      return shelf.Response.ok(
        jsonEncode(transcript.toJson()),
        headers: <String, String>{
          'content-type': 'application/json',
          ..._corsHeaders,
        },
      );
    } on RpcError catch (error) {
      return _problem(_statusFor(error), error.code, error.debugMessage);
    } on Object catch (error, stack) {
      _log.error('transcription failed', error, stack);
      return _problem(502, ConduitErrorCodes.serverError, 'transcribe failed');
    }
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// `GET /recordings/{id}?chatId=&folderId=` -- a saved recording of a
  /// draft as 16 kHz mono WAV; `GET /recordings/{id}?noteId=` -- a note's
  /// recording still waiting to upload, as recorded. It needs the token,
  /// as `/files/` does.
  Future<shelf.Response> _recording(shelf.Request request, String path) async {
    final recordings = _recordings;
    if (recordings == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'GET') {
      return shelf.Response(405, body: 'GET only');
    }
    final query = request.url.queryParameters;
    final id = Uri.decodeComponent(path.substring('/recordings/'.length));
    // `?noteId=`: one of a note's recordings still waiting to upload.
    if (_nonEmpty(query['noteId']) case final noteId?) {
      final notes = _notes;
      if (notes == null) {
        return _problem(
          503,
          ConduitErrorCodes.daemonUnavailable,
          'core starting',
        );
      }
      try {
        final audio = await notes.waitingRecording(noteId, id);
        return shelf.Response.ok(
          audio.bytes,
          headers: <String, String>{
            'content-type': audio.contentType,
            'x-content-type-options': 'nosniff',
            'cache-control': 'no-store',
            ..._corsHeaders,
          },
        );
      } on RpcError catch (error) {
        return _problem(_statusFor(error), error.code, error.debugMessage);
      } on Object catch (error, stack) {
        _log.error('note recording read failed', error, stack);
        return _problem(500, ConduitErrorCodes.serverError, 'read failed');
      }
    }
    try {
      final wav = await recordings.wav(
        RecordingRef(
          id: id,
          chatId: _nonEmpty(query['chatId']),
          folderId: _nonEmpty(query['folderId']),
        ),
      );
      return shelf.Response.ok(
        wav,
        headers: <String, String>{
          'content-type': 'audio/wav',
          'x-content-type-options': 'nosniff',
          'cache-control': 'no-store',
          ..._corsHeaders,
        },
      );
    } on RpcError catch (error) {
      return _problem(_statusFor(error), error.code, error.debugMessage);
    } on Object catch (error, stack) {
      _log.error('recording read failed', error, stack);
      return _problem(500, ConduitErrorCodes.serverError, 'recording failed');
    }
  }

  /// `GET /tts/{jobId}` -- a `voice.speak` job's audio. It needs the token,
  /// as `/files/` does.
  Future<shelf.Response> _speech(shelf.Request request, String path) async {
    final voice = _voice;
    if (voice == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'GET') {
      return shelf.Response(405, body: 'GET only');
    }
    try {
      final audio = await voice.audio(path.substring('/tts/'.length));
      return shelf.Response.ok(
        audio.bytes,
        headers: <String, String>{
          'content-type': audio.contentType,
          'x-content-type-options': 'nosniff',
          'cache-control': 'private, max-age=3600',
          ..._corsHeaders,
        },
      );
    } on RpcError catch (error) {
      return _problem(_statusFor(error), error.code, error.debugMessage);
    } on Object catch (error, stack) {
      _log.error('speech failed', error, stack);
      return _problem(502, ConduitErrorCodes.serverError, 'speech failed');
    }
  }

  static int _statusFor(RpcError error) => switch (error.code) {
    ConduitErrorCodes.unauthenticated ||
    ConduitErrorCodes.sessionExpired => 401,
    ConduitErrorCodes.unauthorized => 403,
    ConduitErrorCodes.notFound => 404,
    ConduitErrorCodes.invalidParams => 400,
    _ => 502,
  };

  /// The same error shape RPC uses, so the renderer has one thing to read.
  shelf.Response _problem(
    int status,
    String code,
    String? message, {
    Map<String, String>? args,
  }) => shelf.Response(
    status,
    body: jsonEncode(<String, Object?>{
      'code': code,
      'args': ?args,
      'debugMessage': ?message,
    }),
    headers: <String, String>{
      'content-type': 'application/json',
      // On the error path too, or the renderer sees an opaque CORS
      // failure instead of the reason the upload was refused.
      ..._corsHeaders,
    },
  );

  static Future<Uint8List> _collect(Stream<List<int>> body) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  late final shelf.Handler _rpcHandler = webSocketHandler(
    (WebSocketChannel socket, String? subprotocol) {
      final sessionId = _newSessionId();
      final session = RpcSession(
        sessionId: sessionId,
        // `Peer` wants a channel of strings. The protocol is text-only, so
        // `StreamChannel.cast` is the whole adaptation; a binary frame would
        // throw here, which is the correct response to a client speaking
        // something other than JSON-RPC.
        channel: socket.cast<String>(),
        system: _system,
        events: events,
        log: _log,
        // Read on every call, so a window that connected before the core
        // attached gets the services once they exist.
        services: () => _coreServices,
        reportNetwork: (online) => _core?.reportNetwork(online: online),
      );
      _sessions[sessionId] = session;
      _log.debug('session $sessionId opened (subprotocol: $subprotocol)');

      unawaited(
        session
            .listen()
            .catchError((Object error, StackTrace stack) {
              _log.error('session $sessionId failed', error, stack);
            })
            .whenComplete(() {
              // listen() has closed the session (whatever ended it), which
              // let go of everything it held; only the list is left.
              _sessions.remove(sessionId);
              _log.debug('session $sessionId closed');
            }),
      );
    },
    // Only the version tag is echoed back. Never the token entry: response
    // headers land in proxy logs and devtools.
    protocols: const <String>{negotiatedSubprotocol},
    // Protocol-level keepalive, so a renderer that dies without closing the
    // socket is reaped instead of holding a session forever.
    pingInterval: const Duration(seconds: 5),
  );

  /// What the diagnostics export says about the core's configuration.
  ///
  /// Field by field from the wire DTOs, which already leave secrets out,
  /// and narrower still: addresses only as far as their origin, headers by
  /// name, and no account names or emails.
  Future<Map<String, Object?>> _configSnapshot() async {
    final core = _core;
    if (core == null) return <String, Object?>{'state': 'starting'};
    Future<Object?> section(Future<Object?> Function() read) async {
      try {
        return await read().timeout(const Duration(seconds: 3));
      } on Object catch (error) {
        return <String, Object?>{'error': error.runtimeType.toString()};
      }
    }

    return <String, Object?>{
      'state': 'attached',
      'preferredBackend': core.container.read(preferredBackendProvider).name,
      'accounts': await section(() async {
        final list = await _accounts!.list();
        return <String, Object?>{
          'activeAccountId': list.activeAccountId,
          'addingAccount': list.addingAccount,
          'accounts': <Map<String, Object?>>[
            for (final account in list.accounts)
              <String, Object?>{
                'id': account.id,
                'serverId': account.serverId,
                'origin': originOnly(account.connection.url),
                'isActive': account.isActive,
                'hasSession': account.hasSession,
                'allowSelfSignedCertificates':
                    account.connection.allowSelfSignedCertificates,
                'hasMutualTlsCredentials':
                    account.connection.hasMutualTlsCredentials,
                'customHeaderNames': account.connection.customHeaderNames,
              },
          ],
        };
      }),
      'auth': await section(() async {
        final auth = await _auth!.status();
        return <String, Object?>{
          'phase': auth.phase.name,
          'isAuthenticated': auth.isAuthenticated,
          'hasToken': auth.hasToken,
          'errorCode': auth.errorCode,
          'isReviewerMode': auth.isReviewerMode,
        };
      }),
      'direct': await section(() async {
        final direct = await _direct!.list();
        return <String, Object?>{
          'preferred': direct.preferred,
          'localHistory': direct.localHistory,
          'connections': <Map<String, Object?>>[
            for (final connection in direct.connections)
              <String, Object?>{
                'id': connection.id,
                'kind': connection.kind.name,
                'origin': originOnly(connection.baseUrl),
                'apiMode': connection.apiMode.name,
                'enabled': connection.enabled,
                'hasApiKey': connection.hasApiKey,
                'customHeaderNames': connection.customHeaderNames,
                'openWebUi': connection.openWebUi,
                'compatible': connection.compatible,
                'allowSelfSignedCertificates':
                    connection.allowSelfSignedCertificates,
              },
          ],
        };
      }),
      'hermes': await section(() async {
        final hermes = await _hermes!.settings();
        return <String, Object?>{
          'enabled': hermes.enabled,
          'origin': originOnly(hermes.baseUrl),
          'mode': hermes.mode,
          'desktopAuthKind': hermes.desktopAuthKind,
          'desktopSignedIn': hermes.desktopSignedIn,
          'hasApiKey': hermes.hasApiKey,
          'usable': hermes.usable,
        };
      }),
      'outboxPending': await section(core.pendingOutboxCount),
      'windows': _sessions.length,
    };
  }

  String _newSessionId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Stops the daemon for [reason]: the one path stdin EOF, SIGINT/SIGTERM
  /// and `system.shutdown` all take, so each stops it the same way.
  void requestStop(String reason) {
    _log.info('stop requested: $reason');
    unawaited(stop());
  }

  /// Closes every session and the listening socket, then the core.
  ///
  /// One stop however many ask: the app closing stdin right after
  /// `system.shutdown` must not tear the core down twice, or a second time
  /// while the first is half done.
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _log.info('stopping');
    final coming = _coreComing;
    if (coming != null && !coming.isCompleted) coming.complete(null);
    // Before any service goes: one that waits for a request it made (the
    // turns service, for its post-turn pulls) must not wait on the server.
    _core?.beginShutdown();
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    _sessions.clear();
    await _calls?.dispose();
    await _readAloud?.dispose();
    await _terminals?.dispose();
    await _computer?.dispose();
    await _data?.dispose();
    _terminals = null;
    _computer = null;
    await _server?.close(force: true);
    _server = null;
    _media.close();
    // The services that hold chats and watches go while the core they read
    // is still there: stopping an answer that is still running, and closing a
    // chat that lingers after its answer, both read its container.
    _accounts?.dispose();
    _accounts = null;
    _servers?.dispose();
    _auth?.dispose();
    _notifications?.dispose();
    await _turns?.dispose();
    _queuedCompletions?.dispose();
    _mcpApps?.dispose();
    _hermesCards?.dispose();
    _hermesRooms?.dispose();
    _hermesRooms = null;
    _hermesAdmin?.dispose();
    _hermesAdmin = null;
    _core?.uiRequests.hermesChatOf = null;
    _turns = null;
    _chats?.dispose();
    _chats = null;
    _core?.handoff.detach();
    _handoff = null;
    _calendar?.dispose();
    _calendar = null;
    _automations?.dispose();
    _automations = null;
    _capabilities?.dispose();
    _capabilities = null;
    // Waits for the recordings' writers: nothing writes once the database
    // below is closed.
    await _notes?.close();
    // After the sockets and those, so nothing can arrive mid-teardown and
    // read a half-disposed container; before completing, so a caller
    // awaiting `onStopped` knows the database is closed and the process can
    // exit.
    await _core?.dispose();
    _core = null;
    _servers = null;
    _auth = null;
    _settings = null;
    _models = null;
    if (!_stopped.isCompleted) _stopped.complete();
  }
}
