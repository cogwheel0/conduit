import 'package:meta/meta.dart';

/// What the signed-in user can do on a LibreChat server.
///
/// A feature is available only when three things allow it, as in the web
/// app: the server's `interface` config shows it, the user's role grants it
/// (`/api/roles/:role`), and, for tools, the agents endpoint is capable of
/// it (`/api/endpoints`, `agents.capabilities`).
@immutable
final class LibreChatCapabilities {
  const LibreChatCapabilities({
    this.prompts = false,
    this.createPrompts = false,
    this.memories = false,
    this.createMemories = false,
    this.updateMemories = false,
    this.optOutMemories = false,
    this.webSearch = false,
    this.codeInterpreter = false,
    this.fileSearch = false,
    this.mcpServers = false,
    this.agents = false,
    this.sharedLinks = false,
    this.temporaryChat = false,
    this.serverSearch = false,
    this.modelSelect = true,
    this.modelSpecsEnforced = false,
  });

  /// Nothing beyond chatting, for before the server has been asked.
  static const LibreChatCapabilities minimal = LibreChatCapabilities();

  final bool prompts;
  final bool createPrompts;
  final bool memories;
  final bool createMemories;

  /// Editing and deleting memories, which LibreChat checks apart from
  /// adding them.
  final bool updateMemories;

  /// Turning memories on and off.
  final bool optOutMemories;
  final bool webSearch;
  final bool codeInterpreter;
  final bool fileSearch;
  final bool mcpServers;
  final bool agents;

  /// Making and updating share links their recipients can open: anyone
  /// signed in to the server, or anyone at all where it allows anonymous
  /// viewing (`ALLOW_SHARED_LINKS_PUBLIC`).
  final bool sharedLinks;
  final bool temporaryChat;

  /// The server can search conversations itself (Meilisearch).
  final bool serverSearch;

  /// The model picker may offer endpoints and models, not only specs.
  final bool modelSelect;

  /// Only the admin's model specs may be chosen, and every turn names one.
  final bool modelSpecsEnforced;

  /// Reads [startupConfig] (signed in), the role's [permissions] and the
  /// [endpoints] config. [serverSearch] is `/api/search/enable`.
  factory LibreChatCapabilities.from({
    required Map<String, dynamic> startupConfig,
    required Map<String, dynamic> permissions,
    required Map<String, dynamic> endpoints,
    bool serverSearch = false,
  }) {
    final interface = startupConfig['interface'] is Map
        ? Map<String, dynamic>.from(startupConfig['interface'] as Map)
        : const <String, dynamic>{};

    /// An interface switch is on unless the admin turned it off; LibreChat's
    /// defaults have every feature here on.
    bool shown(String key, {String? sub}) {
      final value = interface[key];
      if (value is bool) return value;
      if (value is Map && sub != null) return value[sub] != false;
      return true;
    }

    /// Only an explicit false denies. LibreChat's role schema defaults these
    /// permissions to true, and its built-in user role leaves several of
    /// them empty (`{}`) to take that default.
    bool granted(String feature, [String permission = 'USE']) {
      final entry = permissions[feature];
      return entry is! Map || entry[permission] != false;
    }

    final agentsEndpoint = endpoints['agents'];
    final capabilities = <String>{
      if (agentsEndpoint is Map && agentsEndpoint['capabilities'] is List)
        for (final capability in agentsEndpoint['capabilities'] as List)
          if (capability is String) capability,
    };
    final modelSpecs = startupConfig['modelSpecs'];
    final specList = modelSpecs is Map ? modelSpecs['list'] : null;

    return LibreChatCapabilities(
      prompts: shown('prompts', sub: 'use') && granted('PROMPTS'),
      // The server checks USE beside each of these, as for its routes.
      createPrompts:
          shown('prompts', sub: 'create') &&
          granted('PROMPTS') &&
          granted('PROMPTS', 'CREATE'),
      memories:
          shown('memories') &&
          granted('MEMORIES') &&
          granted('MEMORIES', 'READ'),
      createMemories:
          shown('memories') &&
          granted('MEMORIES') &&
          granted('MEMORIES', 'CREATE'),
      updateMemories:
          shown('memories') &&
          granted('MEMORIES') &&
          granted('MEMORIES', 'UPDATE'),
      optOutMemories:
          shown('memories') &&
          granted('MEMORIES') &&
          granted('MEMORIES', 'OPT_OUT'),
      webSearch:
          shown('webSearch') &&
          granted('WEB_SEARCH') &&
          capabilities.contains('web_search'),
      codeInterpreter:
          shown('runCode') &&
          granted('RUN_CODE') &&
          capabilities.contains('execute_code'),
      fileSearch:
          shown('fileSearch') &&
          granted('FILE_SEARCH') &&
          capabilities.contains('file_search'),
      mcpServers: shown('mcpServers', sub: 'use') && granted('MCP_SERVERS'),
      agents:
          agentsEndpoint is Map &&
          shown('agents', sub: 'use') &&
          granted('AGENTS'),
      // LibreChat makes a role's links public only when it is granted that
      // outright; a role that may make links but not public ones gets links
      // only their owner can open, so none is offered.
      sharedLinks:
          startupConfig['sharedLinksEnabled'] != false &&
          granted('SHARED_LINKS', 'CREATE') &&
          permissions['SHARED_LINKS'] is Map &&
          (permissions['SHARED_LINKS'] as Map)['SHARE_PUBLIC'] == true,
      temporaryChat: shown('temporaryChat') && granted('TEMPORARY_CHAT'),
      serverSearch: serverSearch,
      modelSelect: interface['modelSelect'] != false,
      modelSpecsEnforced:
          modelSpecs is Map &&
          modelSpecs['enforce'] == true &&
          specList is List &&
          specList.isNotEmpty,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LibreChatCapabilities &&
      other.prompts == prompts &&
      other.createPrompts == createPrompts &&
      other.memories == memories &&
      other.createMemories == createMemories &&
      other.updateMemories == updateMemories &&
      other.optOutMemories == optOutMemories &&
      other.webSearch == webSearch &&
      other.codeInterpreter == codeInterpreter &&
      other.fileSearch == fileSearch &&
      other.mcpServers == mcpServers &&
      other.agents == agents &&
      other.sharedLinks == sharedLinks &&
      other.temporaryChat == temporaryChat &&
      other.serverSearch == serverSearch &&
      other.modelSelect == modelSelect &&
      other.modelSpecsEnforced == modelSpecsEnforced;

  @override
  int get hashCode => Object.hash(
    prompts,
    createPrompts,
    memories,
    createMemories,
    updateMemories,
    optOutMemories,
    webSearch,
    codeInterpreter,
    fileSearch,
    mcpServers,
    agents,
    sharedLinks,
    temporaryChat,
    serverSearch,
    modelSelect,
    modelSpecsEnforced,
  );
}
