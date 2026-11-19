import 'package:freezed_annotation/freezed_annotation.dart';

part 'capabilities.freezed.dart';
part 'capabilities.g.dart';

/// What the currently connected core can actually do.
///
/// The UI gates navigation and affordances on these flags rather than probing
/// the server itself: capability detection is server- and build-dependent
/// (an Open WebUI version, a Hermes deployment, a macOS-only helper), and
/// duplicating that logic in the renderer is exactly the drift the workspace
/// rules exist to stop.
///
/// A flat struct is safe here because [kConduitProtocolVersion] demands strict
/// equality — the daemon and the UI are always the same build, so there is no
/// "older peer sees an unknown flag" case to design around.
@freezed
abstract class Capabilities with _$Capabilities {
  const factory Capabilities({
    // Sidebar sections. Each gates a whole navigation entry, by the rule
    // the phone's tab bar follows (`isSidebarTabVisible` in the core).
    /// Some workspace section can be managed: the Workspace section. Which
    /// ones are the `workspace*` flags below.
    @Default(false) bool workspace,
    @Default(false) bool notes,
    @Default(false) bool channels,

    /// Hermes's sessions: Hermes is on (or the only backend).
    @Default(false) bool hermes,
    @Default(false) bool terminal,
    @Default(false) bool calendar,

    /// Scheduled tasks.
    @Default(false) bool automations,

    /// Scheduled tasks are offered as a destination: [automations], and
    /// Settings' Advanced is on (as the phone shows them).
    @Default(false) bool scheduledTasks,

    /// Hermes is the only backend: its sessions take the chats' place, and
    /// Open WebUI's own sections are hidden.
    @Default(false) bool hermesOnly,

    // The workspace sections the account may manage.
    @Default(false) bool workspaceModels,
    @Default(false) bool workspaceKnowledge,
    @Default(false) bool workspacePrompts,
    @Default(false) bool workspaceTools,
    @Default(false) bool workspaceSkills,

    // Open WebUI account features, for any model.
    /// Folders can be listed and made.
    @Default(false) bool folders,

    /// Webhook destinations for notifications.
    @Default(false) bool webhooks,
    @Default(false) bool memories,
    @Default(false) bool codeInterpreter,
    @Default(false) bool imageGeneration,
    @Default(false) bool webSearch,

    // Connection kinds.
    @Default(false) bool directConnections,
    @Default(false) bool mcp,

    // Speech. `serverStt` follows the active server's audio config;
    // `onDeviceStt` says whether this computer can transcribe on its own.
    @Default(false) bool serverStt,
    @Default(false) bool onDeviceStt,
    @Default(false) bool serverTts,
    @Default(false) bool deviceTts,

    // macOS Apple helper. `applePcc` stays false unless Apple grants
    // the entitlement, so the UI must treat it as independent of
    // `appleOnDeviceModels`.
    @Default(false) bool appleOnDeviceModels,
    @Default(false) bool applePcc,

    // Parity-plus. Desktop-only at first; the mobile app can flip
    // these on later against the same core methods.
    @Default(false) bool branchNavigation,
    @Default(false) bool messageRating,
    @Default(false) bool tags,
    @Default(false) bool bulkSelection,

    /// A LibreChat account owns the chats, and what its role may use there.
    /// Null otherwise.
    LibreChatFeatures? libreChat,
  }) = _Capabilities;

  factory Capabilities.fromJson(Map<String, dynamic> json) =>
      _$CapabilitiesFromJson(json);

  /// Everything off. The state a fresh daemon reports before a server is
  /// selected, and the safe default if a capability probe fails.
  static const Capabilities none = Capabilities();
}

/// What the signed-in LibreChat user may use: the server's interface
/// switches, the role's permissions and the agents endpoint's capabilities
/// (the core's `LibreChatCapabilities`).
@freezed
abstract class LibreChatFeatures with _$LibreChatFeatures {
  const factory LibreChatFeatures({
    @Default(false) bool prompts,
    @Default(false) bool memories,
    @Default(false) bool createMemories,
    @Default(false) bool updateMemories,
    @Default(false) bool optOutMemories,
    @Default(false) bool webSearch,
    @Default(false) bool codeInterpreter,
    @Default(false) bool fileSearch,
    @Default(false) bool mcpServers,
    @Default(false) bool agents,
    @Default(false) bool sharedLinks,
    @Default(false) bool temporaryChat,
  }) = _LibreChatFeatures;

  factory LibreChatFeatures.fromJson(Map<String, dynamic> json) =>
      _$LibreChatFeaturesFromJson(json);
}
