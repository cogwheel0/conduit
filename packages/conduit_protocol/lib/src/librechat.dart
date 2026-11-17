import 'package:freezed_annotation/freezed_annotation.dart';

import 'accounts.dart';

part 'librechat.freezed.dart';
part 'librechat.g.dart';

// ---------------------------------------------------------------------------
// Signing in
// ---------------------------------------------------------------------------

/// What checking an address for a LibreChat server found.
@JsonEnum(fieldRename: FieldRename.none)
enum LibreChatProbeOutcome {
  /// A LibreChat server answered: [LibreChatProbeResult.server] says how to
  /// sign in to it.
  found,

  /// Something answered, but not LibreChat.
  notLibreChat,

  /// An Open WebUI server answered: add it as an Open WebUI account instead.
  openWebUi,

  /// Nothing answered, or the server was too busy to say what it is.
  unreachable,

  /// The address is not one a server can be reached at.
  invalidAddress,
}

/// A single sign-on button the server's sign-in page offers.
@freezed
abstract class LibreChatSsoProviderDto with _$LibreChatSsoProviderDto {
  const factory LibreChatSsoProviderDto({
    /// `openid`, `github`, `google`, `facebook`, `discord`, `saml` or
    /// `apple`: the path segment of `/oauth/{kind}`.
    required String kind,

    /// The admin's own name for it (OpenID and SAML only); the window names
    /// the others itself.
    String? label,
  }) = _LibreChatSsoProviderDto;

  factory LibreChatSsoProviderDto.fromJson(Map<String, dynamic> json) =>
      _$LibreChatSsoProviderDtoFromJson(json);
}

/// A LibreChat server, as its public startup config describes signing in.
@freezed
abstract class LibreChatServerDto with _$LibreChatServerDto {
  const factory LibreChatServerDto({
    /// The address, normalized: what accounts on it are saved under.
    required String baseUrl,

    /// The server's own name (`appTitle`).
    required String title,

    /// Whether the form takes an email (or LDAP username) and password.
    @Default(true) bool passwordSignIn,

    /// LDAP checks the password; [ldapUsesUsername] asks for a username
    /// rather than an email.
    @Default(false) bool ldap,
    @Default(false) bool ldapUsesUsername,

    /// The single sign-on buttons, in the server's order.
    @Default(<LibreChatSsoProviderDto>[])
    List<LibreChatSsoProviderDto> ssoProviders,
  }) = _LibreChatServerDto;

  factory LibreChatServerDto.fromJson(Map<String, dynamic> json) =>
      _$LibreChatServerDtoFromJson(json);
}

/// Params for `librechat.probe`.
@freezed
abstract class LibreChatProbe with _$LibreChatProbe {
  const factory LibreChatProbe({required String url}) = _LibreChatProbe;

  factory LibreChatProbe.fromJson(Map<String, dynamic> json) =>
      _$LibreChatProbeFromJson(json);
}

/// Reply to `librechat.probe`.
@freezed
abstract class LibreChatProbeResult with _$LibreChatProbeResult {
  const factory LibreChatProbeResult({
    required LibreChatProbeOutcome outcome,

    /// Set when [outcome] is [LibreChatProbeOutcome.found].
    LibreChatServerDto? server,
  }) = _LibreChatProbeResult;

  factory LibreChatProbeResult.fromJson(Map<String, dynamic> json) =>
      _$LibreChatProbeResultFromJson(json);
}

/// Params for `librechat.signIn`: an email (or LDAP username) and password.
@freezed
abstract class LibreChatSignIn with _$LibreChatSignIn {
  const factory LibreChatSignIn({
    /// The server, as `librechat.probe` normalized it.
    required String url,
    required String email,
    required String password,

    /// Put the account in charge even while an answer is being written in
    /// the account it replaces, stopping it.
    @Default(false) bool force,
  }) = _LibreChatSignIn;

  factory LibreChatSignIn.fromJson(Map<String, dynamic> json) =>
      _$LibreChatSignInFromJson(json);
}

/// Params for `librechat.verify`: the second step of a sign-in.
@freezed
abstract class LibreChatVerify with _$LibreChatVerify {
  const factory LibreChatVerify({
    /// From the `twoFactorRequired` reply. The server's own token stays in
    /// the daemon.
    required String flowId,
    required String code,

    /// [code] is a backup code rather than the authenticator app's.
    @Default(false) bool backupCode,
    @Default(false) bool force,
  }) = _LibreChatVerify;

  factory LibreChatVerify.fromJson(Map<String, dynamic> json) =>
      _$LibreChatVerifyFromJson(json);
}

/// Params for `librechat.ssoStart`.
@freezed
abstract class LibreChatSsoStart with _$LibreChatSsoStart {
  const factory LibreChatSsoStart({
    required String url,

    /// A [LibreChatSsoProviderDto.kind].
    required String provider,
  }) = _LibreChatSsoStart;

  factory LibreChatSsoStart.fromJson(Map<String, dynamic> json) =>
      _$LibreChatSsoStartFromJson(json);
}

/// Reply to `librechat.ssoStart`: where the sign-in window starts, and how
/// it tells the server's pages from the provider's.
///
/// LibreChat signs in through `/oauth/{provider}`, the provider, and back
/// to `/oauth/{provider}/callback`, which sets the session's cookies and
/// sends the browser on to its web app. The window stops at that last hop
/// (the web app would renew the session and rotate its cookie) and hands the
/// cookies of [cookieUrl] to `librechat.completeSso`.
@freezed
abstract class LibreChatSsoPlan with _$LibreChatSsoPlan {
  const factory LibreChatSsoPlan({
    required String startUrl,
    required String cookieUrl,

    /// The server's origins (`scheme://host[:port]`): the address typed and
    /// the one it names as its own.
    @Default(<String>[]) List<String> serverOrigins,

    /// The server's path below its origin (`/chat`), or empty.
    @Default('') String basePath,

    /// This start's id. `librechat.completeSso` names it: only the single
    /// sign-on started last completes, so cookies an older sign-in window
    /// left put no account in charge.
    String? startId,
  }) = _LibreChatSsoPlan;

  factory LibreChatSsoPlan.fromJson(Map<String, dynamic> json) =>
      _$LibreChatSsoPlanFromJson(json);
}

/// Params for `librechat.completeSso`.
@freezed
abstract class LibreChatSsoCompletion with _$LibreChatSsoCompletion {
  const factory LibreChatSsoCompletion({
    required String url,

    /// The cookies the sign-in left for [LibreChatSsoPlan.cookieUrl], by
    /// name. Only `refreshToken` and `token_provider` are kept.
    @Default(<String, String>{}) Map<String, String> cookies,
    @Default(false) bool force,

    /// [LibreChatSsoPlan.startId] of the start these cookies came from. A
    /// completion naming another start, or none, is refused with
    /// [LibreChatSignInOutcome.expired].
    String? startId,
  }) = _LibreChatSsoCompletion;

  factory LibreChatSsoCompletion.fromJson(Map<String, dynamic> json) =>
      _$LibreChatSsoCompletionFromJson(json);
}

/// How a sign-in step went.
@JsonEnum(fieldRename: FieldRename.none)
enum LibreChatSignInOutcome {
  /// Signed in, saved, and in charge of the chats.
  signedIn,

  /// The account uses two-step verification: `librechat.verify` with
  /// [LibreChatSignInResult.flowId] and a code.
  twoFactorRequired,

  /// The server refused the email or password (its words in
  /// [LibreChatSignInResult.serverMessage]).
  rejected,

  /// The code was not accepted; try another.
  invalidCode,

  /// The two-step sign-in ran out of time or was never started: start over.
  expired,

  /// The server could not be reached.
  unreachable,

  /// Signed in and saved, but an answer is still being written in the
  /// account it would replace: ask, then `accounts.switch` with `force`.
  blockedByActiveReply,

  /// The single sign-on left no session.
  ssoUnfinished,

  /// Something else failed, such as saving the session.
  failed,
}

/// Reply to the sign-in steps.
@freezed
abstract class LibreChatSignInResult with _$LibreChatSignInResult {
  const factory LibreChatSignInResult({
    required LibreChatSignInOutcome outcome,

    /// For [LibreChatSignInOutcome.twoFactorRequired].
    String? flowId,

    /// The account signed in to, once saved.
    String? accountId,

    /// What the server said, in its own words, when it refused. Shown as it
    /// is, as the phone shows it.
    String? serverMessage,

    /// The accounts after the step.
    AccountList? accounts,
  }) = _LibreChatSignInResult;

  factory LibreChatSignInResult.fromJson(Map<String, dynamic> json) =>
      _$LibreChatSignInResultFromJson(json);
}

// ---------------------------------------------------------------------------
// Composer
// ---------------------------------------------------------------------------

/// Params for `librechat.composer`.
@freezed
abstract class LibreChatComposerTarget with _$LibreChatComposerTarget {
  const factory LibreChatComposerTarget({
    /// The model the composer sends with; the account's selection when
    /// absent.
    String? modelId,
  }) = _LibreChatComposerTarget;

  factory LibreChatComposerTarget.fromJson(Map<String, dynamic> json) =>
      _$LibreChatComposerTargetFromJson(json);
}

/// One of the user's MCP servers the composer offers.
@freezed
abstract class LibreChatMcpServerDto with _$LibreChatMcpServerDto {
  const factory LibreChatMcpServerDto({
    required String name,

    /// What a turn sends in `turns.send`'s `toolIds` to use it.
    required String toolId,
    @Default(0) int toolCount,

    /// It needs signing in to, which only LibreChat's web app can do:
    /// "Connect in LibreChat" opens [LibreChatComposer.webUrl].
    @Default(false) bool needsConnection,
  }) = _LibreChatMcpServerDto;

  factory LibreChatMcpServerDto.fromJson(Map<String, dynamic> json) =>
      _$LibreChatMcpServerDtoFromJson(json);
}

/// Reply to `librechat.composer`: the tools a LibreChat turn may ask for.
///
/// Each is chosen by putting its tool id in `turns.send`'s `toolIds`, as
/// Open WebUI's tools are. A saved agent or a model spec brings its own
/// tools, so none is offered for one.
@freezed
abstract class LibreChatComposer with _$LibreChatComposer {
  const factory LibreChatComposer({
    /// The model is a LibreChat one.
    @Default(false) bool libreChat,

    /// The tool ids of the switches, null where the server or role does
    /// not allow it.
    String? webSearchToolId,
    String? codeInterpreterToolId,
    String? fileSearchToolId,
    @Default(<LibreChatMcpServerDto>[]) List<LibreChatMcpServerDto> mcpServers,

    /// The prompt library is offered for `/`.
    @Default(false) bool prompts,

    /// The server's web app, where an MCP server is connected.
    String? webUrl,
  }) = _LibreChatComposer;

  factory LibreChatComposer.fromJson(Map<String, dynamic> json) =>
      _$LibreChatComposerFromJson(json);
}

// ---------------------------------------------------------------------------
// Memories
// ---------------------------------------------------------------------------

/// One saved memory.
@freezed
abstract class LibreChatMemoryDto with _$LibreChatMemoryDto {
  const factory LibreChatMemoryDto({
    required String key,
    required String value,
    @Default(0) int tokenCount,

    /// UTC milliseconds.
    int? updatedMs,
  }) = _LibreChatMemoryDto;

  factory LibreChatMemoryDto.fromJson(Map<String, dynamic> json) =>
      _$LibreChatMemoryDtoFromJson(json);
}

/// Reply to the `librechat.memories.*` methods.
@freezed
abstract class LibreChatMemories with _$LibreChatMemories {
  const factory LibreChatMemories({
    /// The user's own switch: whether the assistant uses and updates them.
    @Default(true) bool enabled,
    @Default(<LibreChatMemoryDto>[]) List<LibreChatMemoryDto> memories,
    @Default(0) int totalTokens,
    int? tokenLimit,

    /// 0 to 100, when the server says.
    int? usagePercent,

    /// What the role allows.
    @Default(false) bool canCreate,
    @Default(false) bool canUpdate,
    @Default(false) bool canOptOut,
  }) = _LibreChatMemories;

  factory LibreChatMemories.fromJson(Map<String, dynamic> json) =>
      _$LibreChatMemoriesFromJson(json);
}

/// Params for `librechat.memories.save`.
@freezed
abstract class LibreChatMemoryEdit with _$LibreChatMemoryEdit {
  const factory LibreChatMemoryEdit({
    /// The memory being edited, which may be renamed to [key]; null adds a
    /// new one.
    String? originalKey,

    /// Lowercase letters and underscores, as LibreChat requires.
    required String key,
    required String value,
  }) = _LibreChatMemoryEdit;

  factory LibreChatMemoryEdit.fromJson(Map<String, dynamic> json) =>
      _$LibreChatMemoryEditFromJson(json);
}

/// Params for `librechat.memories.delete`.
@freezed
abstract class LibreChatMemoryRef with _$LibreChatMemoryRef {
  const factory LibreChatMemoryRef({required String key}) =
      _LibreChatMemoryRef;

  factory LibreChatMemoryRef.fromJson(Map<String, dynamic> json) =>
      _$LibreChatMemoryRefFromJson(json);
}

/// Params for `librechat.memories.setEnabled`.
@freezed
abstract class LibreChatMemoryToggle with _$LibreChatMemoryToggle {
  const factory LibreChatMemoryToggle({required bool enabled}) =
      _LibreChatMemoryToggle;

  factory LibreChatMemoryToggle.fromJson(Map<String, dynamic> json) =>
      _$LibreChatMemoryToggleFromJson(json);
}
