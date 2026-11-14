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

    /// The names of the headers sent with every request to the server
    /// (Cloudflare Access and the like), in the order saved. Their values
    /// stay in the daemon.
    @Default(<String>[]) List<String> accessHeaderNames,

    /// An API server's memory key is set (else the daemon makes one).
    @Default(false) bool hasMemoryKey,

    /// The daemon holds a dashboard sign-in for the server (a Desktop
    /// Gateway with `dashboardCookie`).
    @Default(false) bool dashboardSignedIn,
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

    /// The headers every request carries, in order; null keeps the saved
    /// ones. A refused list is `invalidParams` with `reason: accessHeader`,
    /// `issue` (`tooMany`, `invalidName`, `duplicate`, `reserved`,
    /// `tooLong`, `invalidValue`) and `header`.
    List<HermesAccessHeaderEdit>? accessHeaders,

    /// An API server's memory key (`X-Hermes-Session-Key`): null keeps the
    /// saved one, empty clears it (the daemon makes one).
    String? memoryKey,
  }) = _HermesConnectionEdit;

  factory HermesConnectionEdit.fromJson(Map<String, dynamic> json) =>
      _$HermesConnectionEditFromJson(json);
}

/// One access header in a connection's form. A saved header's value is
/// never sent to the window, so a row left as it was says which saved
/// header it keeps.
@freezed
abstract class HermesAccessHeaderEdit with _$HermesAccessHeaderEdit {
  const factory HermesAccessHeaderEdit({
    required String name,

    /// The value typed; null keeps the saved value of [savedName] (or of
    /// [name] when that is null). Saved values never follow a connection
    /// to another server.
    String? value,

    /// The saved header this row was, when it was renamed.
    String? savedName,
  }) = _HermesAccessHeaderEdit;

  factory HermesAccessHeaderEdit.fromJson(Map<String, dynamic> json) =>
      _$HermesAccessHeaderEditFromJson(json);
}

/// Reply to `hermes.connections.profiles`: the profiles a Desktop
/// Gateway offers the form's connection, as the phone's profile menu
/// lists them.
@freezed
abstract class HermesProfiles with _$HermesProfiles {
  const factory HermesProfiles({
    @Default(<String>[]) List<String> profiles,

    /// The profile the form should show: the one it had while listed,
    /// else `default`, else the first. Null when nothing was listed.
    String? selected,

    /// Why none were listed (the form keeps its profile and says so):
    /// `noUrl`, `testFirst` (credentials would go unencrypted unasked),
    /// `empty`, `signInFirst`.
    String? issue,
  }) = _HermesProfiles;

  factory HermesProfiles.fromJson(Map<String, dynamic> json) =>
      _$HermesProfilesFromJson(json);
}

/// Params naming only the Hermes connection a change is for
/// (`hermes.skills.reload`).
@freezed
abstract class HermesConnectionRef with _$HermesConnectionRef {
  const factory HermesConnectionRef({
    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): a change naming none, or another
    /// connection than the one in use, is refused.
    String? connection,
  }) = _HermesConnectionRef;

  factory HermesConnectionRef.fromJson(Map<String, dynamic> json) =>
      _$HermesConnectionRefFromJson(json);
}

/// Params for `hermes.dashboard.start`: the saved connection whose
/// dashboard sign-in opens, put in use first.
@freezed
abstract class HermesDashboardStart with _$HermesDashboardStart {
  const factory HermesDashboardStart({
    required String id,

    /// The Hermes connection in use once [id] was put in use
    /// (`HermesChanged.connection`): refused once another is in use, or
    /// when it names none.
    String? connection,
  }) = _HermesDashboardStart;

  factory HermesDashboardStart.fromJson(Map<String, dynamic> json) =>
      _$HermesDashboardStartFromJson(json);
}

/// Params for `hermes.toolsets.set`: a toolset on or off for new sessions.
@freezed
abstract class HermesToolsetToggle with _$HermesToolsetToggle {
  const factory HermesToolsetToggle({
    required String name,
    required bool enabled,

    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): a change naming none, or another
    /// connection than the one in use, is refused.
    String? connection,
  }) = _HermesToolsetToggle;

  factory HermesToolsetToggle.fromJson(Map<String, dynamic> json) =>
      _$HermesToolsetToggleFromJson(json);
}

/// Reply to `hermes.dashboard.start`: where a Desktop Gateway's dashboard
/// sign-in opens, for the window's browser window.
@freezed
abstract class HermesDashboardPlan with _$HermesDashboardPlan {
  const factory HermesDashboardPlan({
    /// The dashboard's own sign-in page.
    required String loginUrl,

    /// The dashboard's origin (`scheme://host[:port]`): the flow is done
    /// back there, and leaving it after the identity provider is refused.
    required String origin,

    /// False when this Mac's browser window cannot carry the connection's
    /// access headers to the dashboard (as on an iPhone): the window says
    /// so instead of opening.
    @Default(true) bool supported,
  }) = _HermesDashboardPlan;

  factory HermesDashboardPlan.fromJson(Map<String, dynamic> json) =>
      _$HermesDashboardPlanFromJson(json);
}

/// One cookie the dashboard sign-in window holds for the dashboard's host.
@freezed
abstract class HermesCookieDto with _$HermesCookieDto {
  const factory HermesCookieDto({
    required String name,
    required String value,

    /// As WebKit reports it: the host for a host-only cookie, a leading
    /// dot for a domain cookie.
    required String domain,
    @Default('/') String path,
    @Default(false) bool secure,
    @Default(false) bool httpOnly,

    /// Milliseconds since the epoch; null for a session cookie.
    int? expiresMs,
  }) = _HermesCookieDto;

  factory HermesCookieDto.fromJson(Map<String, dynamic> json) =>
      _$HermesCookieDtoFromJson(json);
}

/// Params for `hermes.dashboard.complete`: the cookies a page the sign-in
/// window loaded on the dashboard had.
@freezed
abstract class HermesDashboardCookies with _$HermesDashboardCookies {
  const factory HermesDashboardCookies({
    /// The connection signing in.
    required String id,
    @Default(<HermesCookieDto>[]) List<HermesCookieDto> cookies,

    /// The Hermes connection in use the sign-in was started under
    /// (`HermesChanged.connection`): refused once another is in use, or
    /// when it names none.
    String? connection,

    /// The sign-in window's own id: nothing is kept once
    /// `hermes.dashboard.cancel` named it (the window closed).
    String? attempt,
  }) = _HermesDashboardCookies;

  factory HermesDashboardCookies.fromJson(Map<String, dynamic> json) =>
      _$HermesDashboardCookiesFromJson(json);
}

/// `hermes.dashboard.cancel` params: the sign-in window [attempt] closed.
@freezed
abstract class HermesDashboardCancel with _$HermesDashboardCancel {
  const factory HermesDashboardCancel({required String attempt}) =
      _HermesDashboardCancel;

  factory HermesDashboardCancel.fromJson(Map<String, dynamic> json) =>
      _$HermesDashboardCancelFromJson(json);
}

/// Reply to `hermes.dashboard.complete`.
@freezed
abstract class HermesDashboardResult with _$HermesDashboardResult {
  const factory HermesDashboardResult({
    /// The dashboard accepted the cookies as a signed-in session; they are
    /// kept. False: not signed in yet (the window keeps waiting).
    @Default(false) bool signedIn,

    /// The connections, once signed in.
    HermesConnections? connections,
  }) = _HermesDashboardResult;

  factory HermesDashboardResult.fromJson(Map<String, dynamic> json) =>
      _$HermesDashboardResultFromJson(json);
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

/// A value a catalog server asks for when it is added: kept by Hermes under
/// [name] (an environment variable), never by the daemon.
@freezed
abstract class HermesMcpCatalogCredentialDto
    with _$HermesMcpCatalogCredentialDto {
  const factory HermesMcpCatalogCredentialDto({
    required String name,

    /// What to ask for, as Hermes words it; null to ask by [name].
    String? prompt,

    /// The server cannot start without it.
    @Default(true) bool required,
  }) = _HermesMcpCatalogCredentialDto;

  factory HermesMcpCatalogCredentialDto.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpCatalogCredentialDtoFromJson(json);
}

@freezed
abstract class HermesMcpCatalogEntryDto with _$HermesMcpCatalogEntryDto {
  const factory HermesMcpCatalogEntryDto({
    required String name,
    @Default('') String description,

    /// How Hermes signs in to it (`api_key`, `oauth`, `none`); null when
    /// the catalog does not say.
    String? authType,

    /// What adding it asks for, in order; empty when nothing.
    @Default(<HermesMcpCatalogCredentialDto>[])
    List<HermesMcpCatalogCredentialDto> credentials,

    /// It can be added from here with all it needs. One that needs values
    /// this connection cannot send is listed, dimmed.
    @Default(true) bool canAdd,

    /// Read from Hermes' dashboard, whose install takes [credentials].
    @Default(false) bool fromDashboard,

    /// Signs in with OAuth once added.
    @Default(false) bool oauth,
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

/// Params for `hermes.mcp.addFromCatalog`: the entry of the last
/// `hermes.mcp.catalog` read, and the values it asks for (variable name to
/// what was typed). Sent once to Hermes; never kept or logged.
@freezed
abstract class HermesMcpCatalogAdd with _$HermesMcpCatalogAdd {
  const factory HermesMcpCatalogAdd({
    required String name,
    @Default(<String, String>{}) Map<String, String> credentials,

    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): a change naming none, or another
    /// connection than the one in use, is refused.
    String? connection,
  }) = _HermesMcpCatalogAdd;

  factory HermesMcpCatalogAdd.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpCatalogAddFromJson(json);
}

/// Reply to `hermes.mcp.addFromCatalog`.
@freezed
abstract class HermesMcpCatalogAdded with _$HermesMcpCatalogAdded {
  const factory HermesMcpCatalogAdded({
    /// The servers now, listed even when a step after the install failed.
    required HermesMcpServers servers,

    /// Hermes is still installing it in the background: it is listed, and
    /// can be signed in to, once done.
    @Default(false) bool stillInstalling,

    /// It signs in with OAuth: the window goes on to
    /// `hermes.mcp.authenticate` (which opens the browser and can take
    /// minutes). False while [stillInstalling].
    @Default(false) bool signIn,
  }) = _HermesMcpCatalogAdded;

  factory HermesMcpCatalogAdded.fromJson(Map<String, dynamic> json) =>
      _$HermesMcpCatalogAddedFromJson(json);
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
