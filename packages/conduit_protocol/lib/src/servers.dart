import 'package:freezed_annotation/freezed_annotation.dart';

import 'auth.dart';
import 'capabilities.dart';

part 'servers.freezed.dart';
part 'servers.g.dart';

/// A configured server, as the renderer is allowed to see it.
///
/// Deliberately *not* the core's `ServerConfig`, which also holds an API key,
/// a PEM private key and its passphrase. Those never cross this boundary:
/// the daemon attaches credentials to outbound requests itself, which is the
/// same reason `/files/{serverId}/{fileId}` is proxied rather than handed to
/// the renderer as a signed URL. What the UI needs is whether a credential
/// exists, so it can render "configured" next to a field and offer to
/// replace it -- never the value.
@freezed
abstract class ServerSummary with _$ServerSummary {
  const factory ServerSummary({
    required String id,
    required String name,
    required String url,

    /// Exactly one server is active at a time; it is the one every other
    /// namespace implicitly addresses.
    @Default(false) bool isActive,

    /// UTC milliseconds, or null if this server has never connected.
    int? lastConnectedMs,
    @Default(false) bool allowSelfSignedCertificates,

    /// Whether a client certificate *and* key are both present. The UI shows
    /// this as a state, and the labels below as the filenames the user
    /// picked; neither reveals key material.
    @Default(false) bool hasMutualTlsCredentials,
    String? mtlsCertificateLabel,
    String? mtlsPrivateKeyLabel,

    /// Custom header *names* only. A header value is frequently a bearer
    /// token for a reverse proxy, so the values stay daemon-side; the setup
    /// form edits them by sending replacements, not by reading them back.
    @Default(<String>[]) List<String> customHeaderNames,

    /// Whether switching to this server would restore a session rather than
    /// ask for credentials. True for the active server when it is signed in,
    /// and for any server holding a vaulted token.
    ///
    /// A hint for the UI's "signed in" marker, not a guarantee: the server
    /// may have revoked the token since, which is only discovered by using
    /// it.
    @Default(false) bool hasStoredSession,
  }) = _ServerSummary;

  factory ServerSummary.fromJson(Map<String, dynamic> json) =>
      _$ServerSummaryFromJson(json);
}

/// Params for `servers.update`, and the server half of `accounts.add`.
///
/// Every secret field is nullable and "null means leave alone", so the setup
/// form can save a rename without having to round-trip a private key it was
/// never given. [clearMutualTls] is how a caller actually removes one, since
/// null cannot mean both "unchanged" and "delete".
///
/// There is deliberately no API key here. The core strips `apiKey` from every
/// persisted `ServerConfig` -- an API key is a credential, kept in secure
/// storage, not server metadata -- so a field for it would be one the daemon
/// silently discards. `auth.loginWithApiKey` is the way in.
@freezed
abstract class ServerDraft with _$ServerDraft {
  const factory ServerDraft({
    /// The account whose server this edits, on `servers.update`. Ignored by
    /// `accounts.add`, which always makes a new account.
    String? id,
    required String name,
    required String url,
    @Default(false) bool allowSelfSignedCertificates,
    String? mtlsCertificateChainPem,
    String? mtlsCertificateLabel,
    String? mtlsPrivateKeyPem,
    String? mtlsPrivateKeyLabel,
    String? mtlsPrivateKeyPassword,
    @Default(false) bool clearMutualTls,

    /// Replaces the whole header map when present, leaves it alone when null.
    Map<String, String>? customHeaders,
  }) = _ServerDraft;

  factory ServerDraft.fromJson(Map<String, dynamic> json) =>
      _$ServerDraftFromJson(json);
}

/// How the daemon's last attempt to reach the active server went.
@JsonEnum(fieldRename: FieldRename.none)
enum ServerReachability {
  /// Nothing has been attempted yet this launch.
  unknown,
  reachable,

  /// The request did not arrive: DNS, TLS, a refused connection, a proxy
  /// still challenging.
  unreachable,

  /// Something answered, but it is not an Open WebUI instance. Worth telling
  /// apart from unreachable, because the fix is a different URL rather than a
  /// different network.
  notOpenWebUi,
}

/// The live state of the active server, as opposed to its stored config.
///
/// One call serves two screens that otherwise duplicate each other: the
/// version gate needs [version] and [isVersionSupported], the connection-issue
/// page needs [reachability] and [errorCode], and both need to know whether
/// there is an active server at all.
@freezed
abstract class ServerStatus with _$ServerStatus {
  const factory ServerStatus({
    String? activeServerId,
    @Default(Capabilities.none) Capabilities capabilities,
    @Default(ServerReachability.unknown) ServerReachability reachability,

    /// As the server reports it, or null when it has not been asked yet or
    /// did not say.
    String? version,

    /// Fails open. An unparseable or absent version is treated as supported,
    /// because blocking a user over a version string nobody can read is worse
    /// than letting them through.
    @Default(true) bool isVersionSupported,

    /// The newest server version this build is known to work with, so the
    /// warning can name it rather than saying "too new".
    required String maxSupportedVersion,

    /// Set when [reachability] is not `reachable`; localized in the UI.
    String? errorCode,
  }) = _ServerStatus;

  factory ServerStatus.fromJson(Map<String, dynamic> json) =>
      _$ServerStatusFromJson(json);
}

/// Why an address of a saved server cannot be used, or why it was not
/// saved: the core's `ServerAddressProblem`, which each app words itself.
@JsonEnum(fieldRename: FieldRename.none)
enum ServerAddressProblemCode {
  addressEmpty,
  invalidAddress,
  unsupportedScheme,
  missingHost,
  portOutOfRange,
  invalidIpAddress,
  headerFieldMissing,
  headerNameTooLong,
  headerNameInvalidCharacters,

  /// The header is one the app sets itself; [ServerAddressCheckResult.headerName]
  /// names it.
  headerNameReserved,
  headerValueTooLong,
  headerValueInvalidCharacters,
  headerValueUnsafe,

  /// Two headers of one name; [ServerAddressCheckResult.headerName] names it.
  headerAlreadyAdded,
  tooManyHeaders,
  mutualTlsIncomplete,
  certificatePemRequired,
  privateKeyPemRequired,
  pemFileUnreadable,
  mutualTlsRefused,
  mutualTlsConnectionClosed,
  unreachable,
  notOpenWebUi,
  serverUnavailable,
  serverError,
  certificateRejected,
  serverMissing,
  differentServer,
  needsSignIn,
  proxySessionRevoked,

  /// Signed in through the proxy, the address still did not answer as an
  /// Open WebUI server. The desktop's own: the phone's connection page says
  /// it in its own words.
  proxyVerificationFailed,
}

/// One address a saved Open WebUI server is reached at, in the order they
/// are tried. As [ServerSummary], no secret: header names, not values;
/// whether a client certificate and its key are saved, not the key.
@freezed
abstract class ServerAddressDto with _$ServerAddressDto {
  const factory ServerAddressDto({
    required String id,
    required String url,

    /// What the user called it ("Home network"), or null.
    String? label,

    /// The address the active account reaches the server through now.
    @Default(false) bool inUse,
    @Default(false) bool allowSelfSignedCertificates,

    /// The custom headers sent to it, by name; their values stay with the
    /// daemon. The proxy cookie an account keeps here is not one of them.
    @Default(<String>[]) List<String> customHeaderNames,
    @Default(false) bool hasMutualTlsCredentials,
    String? mtlsCertificateLabel,
    String? mtlsPrivateKeyLabel,
    @Default(false) bool hasPrivateKeyPassword,
  }) = _ServerAddressDto;

  factory ServerAddressDto.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressDtoFromJson(json);
}

/// Reply to `servers.addresses.list`: a saved server's addresses.
@freezed
abstract class ServerAddresses with _$ServerAddresses {
  const factory ServerAddresses({
    required String serverId,

    /// The server's name, as its page is titled.
    required String name,
    @Default(<ServerAddressDto>[]) List<ServerAddressDto> addresses,

    /// Whether an address can be removed: one is always left.
    @Default(false) bool removable,
  }) = _ServerAddresses;

  factory ServerAddresses.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressesFromJson(json);
}

/// Params naming a saved Open WebUI server (not an account).
@freezed
abstract class ServerRef with _$ServerRef {
  const factory ServerRef({required String serverId}) = _ServerRef;

  factory ServerRef.fromJson(Map<String, dynamic> json) =>
      _$ServerRefFromJson(json);
}

/// A custom header in an address's form. A null [value] keeps the value
/// saved under that name, which the window was never given.
@freezed
abstract class ServerAddressHeader with _$ServerAddressHeader {
  const factory ServerAddressHeader({required String name, String? value}) =
      _ServerAddressHeader;

  factory ServerAddressHeader.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressHeaderFromJson(json);
}

/// What an address's editor holds. Editing a saved address, a null
/// certificate, key or key password keeps the saved one, and
/// [clearMutualTls] removes them.
@freezed
abstract class ServerAddressForm with _$ServerAddressForm {
  const factory ServerAddressForm({
    @Default('') String url,
    @Default('') String label,
    @Default(false) bool allowSelfSignedCertificates,
    @Default(<ServerAddressHeader>[]) List<ServerAddressHeader> headers,
    String? mtlsCertificateChainPem,
    String? mtlsCertificateLabel,
    String? mtlsPrivateKeyPem,
    String? mtlsPrivateKeyLabel,
    String? mtlsPrivateKeyPassword,
    @Default(false) bool clearMutualTls,
  }) = _ServerAddressForm;

  factory ServerAddressForm.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressFormFromJson(json);
}

/// Params for `servers.addresses.check`.
@freezed
abstract class ServerAddressCheckRequest with _$ServerAddressCheckRequest {
  const factory ServerAddressCheckRequest({
    required String serverId,

    /// The address being edited; null adds one.
    String? endpointId,
    required ServerAddressForm form,
  }) = _ServerAddressCheckRequest;

  factory ServerAddressCheckRequest.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressCheckRequestFromJson(json);
}

/// What checking an address found.
@JsonEnum(fieldRename: FieldRename.none)
enum ServerAddressCheckOutcome {
  /// It answered as an Open WebUI server: `servers.addresses.save` next.
  answered,

  /// A sign-in proxy in front of it wants its own sign-in first, in a
  /// window at [ServerAddressCheckResult.url]; then
  /// `servers.addresses.save` with what that window captured.
  behindProxy,

  /// It cannot be used: [ServerAddressCheckResult.problem] or
  /// [ServerAddressCheckResult.errorText] says why.
  unusable,
}

/// Reply to `servers.addresses.check`.
@freezed
abstract class ServerAddressCheckResult with _$ServerAddressCheckResult {
  const factory ServerAddressCheckResult({
    required ServerAddressCheckOutcome outcome,

    /// What `servers.addresses.save` takes, once answered or behind a proxy.
    /// The daemon keeps the checked address under it for a while.
    String? checkId,

    /// The address as it will be saved (a scheme added, a redirect to https
    /// followed).
    String? url,
    ServerAddressProblemCode? problem,

    /// The error's own words, its secrets taken out, when no [problem]
    /// says it better.
    String? errorText,

    /// The header a header problem is about.
    String? headerName,
  }) = _ServerAddressCheckResult;

  factory ServerAddressCheckResult.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressCheckResultFromJson(json);
}

/// What saving an address asks the user first.
@JsonEnum(fieldRename: FieldRename.none)
enum ServerAddressConfirmation {
  /// An account's session goes to a host it has not reached before, to
  /// prove the address is this server ([ServerAddressSaveResult.host]).
  sendSession,

  /// A reply arrives through the address in use, and changing or removing
  /// it stops the reply.
  replyInProgress,
}

/// Params for `servers.addresses.save`.
@freezed
abstract class ServerAddressSaveRequest with _$ServerAddressSaveRequest {
  const factory ServerAddressSaveRequest({
    required String checkId,

    /// The user agreed to send a session to the new host.
    @Default(false) bool sendSessionConfirmed,

    /// The user agreed to stop the reply arriving through the address in
    /// use.
    @Default(false) bool stopReplies,

    /// What the proxy's sign-in window captured, for an address that was
    /// behind a proxy.
    ExternalAuthCompletion? proxy,
  }) = _ServerAddressSaveRequest;

  factory ServerAddressSaveRequest.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressSaveRequestFromJson(json);
}

/// What an address change came to.
@JsonEnum(fieldRename: FieldRename.none)
enum ServerAddressChangeOutcome {
  done,

  /// Nothing changed: [ServerAddressSaveResult.problem] says why, or with
  /// none, the user chose not to go on.
  notSaved,

  /// Ask [ServerAddressSaveResult.confirmation] first, then call again
  /// with the user's answer.
  needsConfirmation,
}

/// Reply to `servers.addresses.save`.
@freezed
abstract class ServerAddressSaveResult with _$ServerAddressSaveResult {
  const factory ServerAddressSaveResult({
    required ServerAddressChangeOutcome outcome,
    ServerAddressConfirmation? confirmation,

    /// The host [ServerAddressConfirmation.sendSession] names.
    String? host,
    ServerAddressProblemCode? problem,
    String? errorText,

    /// The server's addresses after the change.
    ServerAddresses? addresses,
  }) = _ServerAddressSaveResult;

  factory ServerAddressSaveResult.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressSaveResultFromJson(json);
}

/// Params for `servers.addresses.remove`.
@freezed
abstract class ServerAddressRemoveRequest with _$ServerAddressRemoveRequest {
  const factory ServerAddressRemoveRequest({
    required String serverId,
    required String endpointId,

    /// The user agreed to stop the reply arriving through it.
    @Default(false) bool stopReplies,
  }) = _ServerAddressRemoveRequest;

  factory ServerAddressRemoveRequest.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressRemoveRequestFromJson(json);
}

/// Params for `servers.addresses.reorder`.
@freezed
abstract class ServerAddressReorderRequest with _$ServerAddressReorderRequest {
  const factory ServerAddressReorderRequest({
    required String serverId,

    /// Address ids in the order to try them. Any not named keep their place
    /// after these; an id no longer there is passed over.
    @Default(<String>[]) List<String> order,
  }) = _ServerAddressReorderRequest;

  factory ServerAddressReorderRequest.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressReorderRequestFromJson(json);
}

/// Reply to `servers.addresses.remove` and `servers.addresses.reorder`.
@freezed
abstract class ServerAddressEditResult with _$ServerAddressEditResult {
  const factory ServerAddressEditResult({
    required ServerAddressChangeOutcome outcome,
    ServerAddressConfirmation? confirmation,
    required ServerAddresses addresses,
  }) = _ServerAddressEditResult;

  factory ServerAddressEditResult.fromJson(Map<String, dynamic> json) =>
      _$ServerAddressEditResultFromJson(json);
}

/// Payload of `servers.changed`: a saved server's name or addresses
/// changed, or which of them is in use. Fetch `servers.addresses.list`.
@freezed
abstract class ServersChanged with _$ServersChanged {
  const factory ServersChanged({String? serverId}) = _ServersChanged;

  factory ServersChanged.fromJson(Map<String, dynamic> json) =>
      _$ServersChangedFromJson(json);
}
