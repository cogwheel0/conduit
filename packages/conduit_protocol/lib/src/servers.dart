import 'package:freezed_annotation/freezed_annotation.dart';

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
  }) = _ServerSummary;

  factory ServerSummary.fromJson(Map<String, dynamic> json) =>
      _$ServerSummaryFromJson(json);
}

/// Params for `servers.add` and `servers.update`.
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
    /// Null on `servers.add`; required on `servers.update`.
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

/// Params for the `servers.*` methods that address one server by id.
@freezed
abstract class ServerRef with _$ServerRef {
  const factory ServerRef({required String id}) = _ServerRef;

  factory ServerRef.fromJson(Map<String, dynamic> json) =>
      _$ServerRefFromJson(json);
}

/// Reply to `servers.list`.
@freezed
abstract class ServerList with _$ServerList {
  const factory ServerList({
    @Default(<ServerSummary>[]) List<ServerSummary> servers,

    /// Id of the active server, or null when none is selected -- which is
    /// what makes a launch an onboarding launch.
    String? activeServerId,
  }) = _ServerList;

  factory ServerList.fromJson(Map<String, dynamic> json) =>
      _$ServerListFromJson(json);
}
