import 'package:freezed_annotation/freezed_annotation.dart';

part 'hermes_admin.freezed.dart';
part 'hermes_admin.g.dart';

// ---------------------------------------------------------------------------
// Scheduled agents: delivery, notices
// ---------------------------------------------------------------------------

/// One place a scheduled agent's runs can go.
@freezed
abstract class HermesDeliveryTargetDto with _$HermesDeliveryTargetDto {
  const factory HermesDeliveryTargetDto({
    /// The token Hermes stores (`local`, `telegram`, `bot-chat:<profile>`,
    /// `room:<id>@<profile>`).
    required String target,

    /// `local` (saved in Hermes), `platform` (a messaging app's home
    /// channel), `botChat`, `room` (a group chat) or `other` (shown as
    /// stored).
    @Default('other') String kind,

    /// Its name without the kind: a platform's, bot's or room's; the
    /// token itself for `other`; empty for `local`.
    @Default('') String name,

    /// False for a messaging app without a home channel: Hermes has
    /// nowhere to send.
    @Default(true) bool available,
  }) = _HermesDeliveryTargetDto;

  factory HermesDeliveryTargetDto.fromJson(Map<String, dynamic> json) =>
      _$HermesDeliveryTargetDtoFromJson(json);
}

/// Reply to `hermes.jobs.delivery`: where the connection's jobs can
/// deliver, in display order (saved in Hermes, messaging apps, bot chats,
/// group chats).
@freezed
abstract class HermesDeliveryOptions with _$HermesDeliveryOptions {
  const factory HermesDeliveryOptions({
    /// False on an API server, which lists no targets: its runs are saved
    /// in Hermes.
    @Default(false) bool available,
    @Default(<HermesDeliveryTargetDto>[]) List<HermesDeliveryTargetDto> options,
  }) = _HermesDeliveryOptions;

  factory HermesDeliveryOptions.fromJson(Map<String, dynamic> json) =>
      _$HermesDeliveryOptionsFromJson(json);
}

/// Something about a job the window says once (`HermesJobs.notices`).
@freezed
abstract class HermesJobNotice with _$HermesJobNotice {
  const factory HermesJobNotice({
    required String jobId,

    /// `stopped` (the run a Stop was sent to ended stopped),
    /// `finishedBeforeStop`, `nothingToStop`, `stopUnsupported` (the
    /// server predates Stop), `stopFailed`, or `runFailed` (a Run Now
    /// Hermes refused or that failed on its way).
    required String kind,
  }) = _HermesJobNotice;

  factory HermesJobNotice.fromJson(Map<String, dynamic> json) =>
      _$HermesJobNoticeFromJson(json);
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

/// A saved Hermes connection. Its secrets never leave the daemon: only
/// whether they are set.
@freezed
abstract class HermesConnectionDto with _$HermesConnectionDto {
  const factory HermesConnectionDto({
    required String id,
    required String name,
    @Default('') String baseUrl,

    /// `responses` (the API server) or `desktop` (the Desktop Gateway).
    @Default('responses') String mode,

    /// `legacyToken`, `nativePkce` or `dashboardCookie`.
    @Default('legacyToken') String desktopAuthKind,
    @Default('default') String desktopProfile,
    @Default(false) bool allowSelfSignedCertificates,

    /// The one Hermes is used through now.
    @Default(false) bool active,

    /// Its credentials travel unencrypted (plain HTTP to a server off this
    /// Mac).
    @Default(false) bool plainHttp,
    @Default(false) bool hasApiKey,
    @Default(false) bool hasLegacyToken,

    /// Signed in natively (a Desktop Gateway with `nativePkce`).
    @Default(false) bool desktopSignedIn,
  }) = _HermesConnectionDto;

  factory HermesConnectionDto.fromJson(Map<String, dynamic> json) =>
      _$HermesConnectionDtoFromJson(json);
}

/// Reply to `hermes.connections.*`: Hermes's switch and its saved
/// connections, in the order they were added.
@freezed
abstract class HermesConnections with _$HermesConnections {
  const factory HermesConnections({
    /// Hermes is turned on (whether or not a connection is usable).
    @Default(false) bool enabled,
    String? activeId,
    @Default(<HermesConnectionDto>[]) List<HermesConnectionDto> connections,

    /// Another connection can be saved (there is a limit).
    @Default(true) bool canAdd,

    /// The connection a save wrote (`hermes.connections.save`).
    String? savedId,

    /// The connection in use now, as `HermesChanged.connection` names it:
    /// what the window sends with a request bound to it.
    String? connection,
  }) = _HermesConnections;

  factory HermesConnections.fromJson(Map<String, dynamic> json) =>
      _$HermesConnectionsFromJson(json);
}

/// Params for `hermes.connections.save` and `hermes.connections.test`: a
/// connection's form. A null secret keeps the one saved for the same
/// server; an empty one clears it. Secrets never follow a connection to
/// another server.
@freezed
abstract class HermesConnectionEdit with _$HermesConnectionEdit {
  const factory HermesConnectionEdit({
    /// The connection edited; null saves a new one (the first is made the
    /// active one, the others are saved beside it).
    String? id,

    /// Null keeps the saved name; empty names it after the server.
    String? name,
    required String baseUrl,
    @Default('responses') String mode,
    @Default('legacyToken') String desktopAuthKind,
    @Default('default') String desktopProfile,
    String? apiKey,
    String? legacyToken,
    @Default(false) bool allowSelfSignedCertificates,

    /// The user agreed to send this connection's credentials unencrypted
    /// (asked when the daemon refuses with `hermes.plainHttpConsent`).
    @Default(false) bool allowPlainHttp,
  }) = _HermesConnectionEdit;

  factory HermesConnectionEdit.fromJson(Map<String, dynamic> json) =>
      _$HermesConnectionEditFromJson(json);
}

/// Reply to `hermes.connections.test`.
@freezed
abstract class HermesConnectionTestResult with _$HermesConnectionTestResult {
  const factory HermesConnectionTestResult({
    @Default(false) bool ok,

    /// A code the window words: `unreachable`, `unauthorized`, `invalid`,
    /// `keyRequired`.
    String? reason,

    /// The name the server suggests for the connection (its model or
    /// profile), when it reached it and offers one.
    String? suggestedName,
  }) = _HermesConnectionTestResult;

  factory HermesConnectionTestResult.fromJson(Map<String, dynamic> json) =>
      _$HermesConnectionTestResultFromJson(json);
}

/// Params for `hermes.connections.setEnabled`.
@freezed
abstract class HermesToggle with _$HermesToggle {
  const factory HermesToggle({required bool enabled}) = _HermesToggle;

  factory HermesToggle.fromJson(Map<String, dynamic> json) =>
      _$HermesToggleFromJson(json);
}

// ---------------------------------------------------------------------------
// MCP servers (a Desktop Gateway's)
// ---------------------------------------------------------------------------

/// An MCP server Hermes connects its agent to.
@freezed
abstract class HermesMcpServerDto with _$HermesMcpServerDto {
  const factory HermesMcpServerDto({
    required String name,

    /// Where it is: an HTTP address, or the command Hermes runs.
    @Default('') String description,

    /// Its tools are offered to the agent.
    @Default(true) bool enabled,

    /// How it signs in, as Hermes says (`oauth`, `bearer`), when it does.
    String? auth,

    /// Its tools, when Hermes lists them (or a test found them).
    @Default(<String>[]) List<String> tools,

    /// Which tools Hermes registers, in words, when it filters them.
    String? toolFilter,
  }) = _HermesMcpServerDto;

  factory HermesMcpServerDto.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpServerDtoFromJson(json);
}

/// Reply to `hermes.mcp.*`.
@freezed
abstract class HermesMcpServers with _$HermesMcpServers {
  const factory HermesMcpServers({
    /// The connection manages MCP servers (a Desktop Gateway).
    @Default(false) bool available,
    @Default(<HermesMcpServerDto>[]) List<HermesMcpServerDto> servers,

    /// An API key can be set on a server (Hermes 0.23 and later).
    @Default(false) bool canSetApiKey,

    /// The change this answers was made, but the servers could not be read
    /// again after it: [servers] is not the list (keep the one shown and
    /// read it again).
    @Default(false) bool listFailed,
  }) = _HermesMcpServers;

  factory HermesMcpServers.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpServersFromJson(json);
}

@freezed
abstract class HermesMcpCatalogEntryDto with _$HermesMcpCatalogEntryDto {
  const factory HermesMcpCatalogEntryDto({
    required String name,
    @Default('') String description,
  }) = _HermesMcpCatalogEntryDto;

  factory HermesMcpCatalogEntryDto.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpCatalogEntryDtoFromJson(json);
}

/// Reply to `hermes.mcp.catalog`: the servers Hermes offers ready-made,
/// those already added left out.
@freezed
abstract class HermesMcpCatalog with _$HermesMcpCatalog {
  const factory HermesMcpCatalog({
    @Default(<HermesMcpCatalogEntryDto>[])
    List<HermesMcpCatalogEntryDto> entries,
  }) = _HermesMcpCatalog;

  factory HermesMcpCatalog.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpCatalogFromJson(json);
}

/// Params for `hermes.mcp.add`: a server of the user's own, at an HTTP
/// address or run as a command.
@freezed
abstract class HermesMcpAdd with _$HermesMcpAdd {
  const factory HermesMcpAdd({
    required String name,
    String? url,
    String? command,
    @Default(<String>[]) List<String> args,

    /// Sent as its bearer token; never kept by the daemon.
    String? apiKey,

    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): refused once another is in use. Null
    /// from an older window, not checked.
    String? connection,
  }) = _HermesMcpAdd;

  factory HermesMcpAdd.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpAddFromJson(json);
}

/// Params naming an MCP server (or a catalog entry) by name.
@freezed
abstract class HermesMcpRef with _$HermesMcpRef {
  const factory HermesMcpRef({
    required String name,

    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): refused once another is in use. Null
    /// from an older window, not checked.
    String? connection,
  }) = _HermesMcpRef;

  factory HermesMcpRef.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpRefFromJson(json);
}

/// Params for `hermes.mcp.setApiKey`.
@freezed
abstract class HermesMcpApiKey with _$HermesMcpApiKey {
  const factory HermesMcpApiKey({
    required String name,
    required String apiKey,

    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): refused once another is in use. Null
    /// from an older window, not checked.
    String? connection,
  }) = _HermesMcpApiKey;

  factory HermesMcpApiKey.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpApiKeyFromJson(json);
}

/// Params for `hermes.mcp.setEnabled`: offer a server's tools or not.
@freezed
abstract class HermesMcpToggle with _$HermesMcpToggle {
  const factory HermesMcpToggle({
    required String name,
    required bool enabled,

    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): refused once another is in use. Null
    /// from an older window, not checked.
    String? connection,
  }) = _HermesMcpToggle;

  factory HermesMcpToggle.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpToggleFromJson(json);
}

/// Reply to `hermes.mcp.test`.
@freezed
abstract class HermesMcpTestResultDto with _$HermesMcpTestResultDto {
  const factory HermesMcpTestResultDto({
    @Default(false) bool ok,
    @Default(0) int tools,
    @Default(0) int resources,
    @Default(0) int prompts,

    /// What went wrong, as Hermes says it.
    String? error,
    @Default(<String>[]) List<String> toolNames,
  }) = _HermesMcpTestResultDto;

  factory HermesMcpTestResultDto.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpTestResultDtoFromJson(json);
}
