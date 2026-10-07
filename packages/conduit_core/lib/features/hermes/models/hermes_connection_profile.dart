import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';

/// Where a saved Hermes connection's display name came from.
///
/// A [user] name is never replaced automatically. [server] names come from the
/// connected agent (its advertised model or Desktop profile title) and
/// [derived] names are local fallbacks; both may be refreshed by a later
/// suggestion while the user has not chosen a name of their own.
enum HermesConnectionNameSource { user, server, derived }

/// Name shown when a connection has neither a chosen nor a derivable name.
const String kHermesDefaultConnectionName = 'Hermes Agent';

const int kMaxHermesConnectionNameCharacters = 80;

/// Upper bound for saved connections. The document lives in preferences and is
/// read synchronously by the router, so it must stay small.
const int kMaxHermesConnections = 32;

final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// One saved, named Hermes connection.
///
/// Holds only non-secret settings. API, session-memory, and Desktop
/// credentials live in `SecureCredentialStorage`, keyed by [id].
final class HermesConnectionProfile {
  const HermesConnectionProfile({
    required this.id,
    required this.name,
    required this.documentTrustPrincipalId,
    this.nameSource = HermesConnectionNameSource.derived,
    this.baseUrl = '',
    this.mode = HermesBackendMode.responsesApi,
    this.desktopAuthKind = HermesDesktopAuthKind.legacyToken,
    this.desktopProfile = 'default',
    this.allowSelfSignedCertificates = false,
    this.lastUsedAt,
  });

  final String id;
  final String name;
  final HermesConnectionNameSource nameSource;
  final String baseUrl;
  final HermesBackendMode mode;
  final HermesDesktopAuthKind desktopAuthKind;
  final String desktopProfile;
  final bool allowSelfSignedCertificates;

  /// Random epoch binding local document trust and mixed-chat session reuse to
  /// this connection. Rotated whenever the endpoint or credential identity
  /// changes; never derived from credentials.
  final String documentTrustPrincipalId;

  final DateTime? lastUsedAt;

  static String newId() => const Uuid().v4();

  static bool isValidId(String value) => _uuidV4Pattern.hasMatch(value);

  static bool isValidPrincipalId(String value) =>
      _uuidV4Pattern.hasMatch(value);

  /// Local fallback name: the server host, or [kHermesDefaultConnectionName].
  static String deriveName(String baseUrl) {
    final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    return host.isEmpty ? kHermesDefaultConnectionName : _boundName(host);
  }

  /// Trims and bounds a user- or server-supplied name. Returns null when
  /// nothing printable remains.
  static String? sanitizeName(String? value) {
    if (value == null) return null;
    final collapsed = value
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return collapsed.isEmpty ? null : _boundName(collapsed);
  }

  static String _boundName(String value) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= kMaxHermesConnectionNameCharacters) return value;
    return String.fromCharCodes(runes.take(kMaxHermesConnectionNameCharacters))
        .trim();
  }

  HermesConnectionProfile copyWith({
    String? name,
    HermesConnectionNameSource? nameSource,
    String? baseUrl,
    HermesBackendMode? mode,
    HermesDesktopAuthKind? desktopAuthKind,
    String? desktopProfile,
    bool? allowSelfSignedCertificates,
    String? documentTrustPrincipalId,
    DateTime? lastUsedAt,
  }) => HermesConnectionProfile(
    id: id,
    name: name ?? this.name,
    nameSource: nameSource ?? this.nameSource,
    baseUrl: baseUrl ?? this.baseUrl,
    mode: mode ?? this.mode,
    desktopAuthKind: desktopAuthKind ?? this.desktopAuthKind,
    desktopProfile: desktopProfile ?? this.desktopProfile,
    allowSelfSignedCertificates:
        allowSelfSignedCertificates ?? this.allowSelfSignedCertificates,
    documentTrustPrincipalId:
        documentTrustPrincipalId ?? this.documentTrustPrincipalId,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'name_source': nameSource.name,
    'base_url': baseUrl,
    'mode': mode.name,
    'desktop_auth_kind': desktopAuthKind.name,
    'desktop_profile': desktopProfile,
    'allow_self_signed_certificates': allowSelfSignedCertificates,
    'document_trust_principal_id': documentTrustPrincipalId,
    if (lastUsedAt != null)
      'last_used_at': lastUsedAt!.toUtc().toIso8601String(),
  };

  /// Parses one stored profile, or null when its identity is unusable. Unknown
  /// or malformed optional fields fall back to the same defaults a fresh
  /// connection uses, matching how the former scalar preferences were read.
  static HermesConnectionProfile? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! String || !isValidId(id)) return null;
    final rawBaseUrl = value['base_url'];
    final baseUrl = rawBaseUrl is String && rawBaseUrl.length <= 2048
        ? rawBaseUrl.trim()
        : '';
    final rawProfile = value['desktop_profile'];
    final desktopProfile =
        rawProfile is String && HermesConfig.isValidDesktopProfile(rawProfile)
        ? rawProfile
        : 'default';
    final rawPrincipal = value['document_trust_principal_id'];
    return HermesConnectionProfile(
      id: id,
      name:
          sanitizeName(
            value['name'] is String ? value['name'] as String : null,
          ) ??
          deriveName(baseUrl),
      nameSource: HermesConnectionNameSource.values.firstWhere(
        (source) => source.name == value['name_source'],
        orElse: () => HermesConnectionNameSource.derived,
      ),
      baseUrl: baseUrl,
      mode: HermesBackendMode.values.firstWhere(
        (mode) => mode.name == value['mode'],
        orElse: () => HermesBackendMode.responsesApi,
      ),
      desktopAuthKind: HermesDesktopAuthKind.values.firstWhere(
        (kind) => kind.name == value['desktop_auth_kind'],
        orElse: () => HermesDesktopAuthKind.legacyToken,
      ),
      desktopProfile: desktopProfile,
      allowSelfSignedCertificates:
          value['allow_self_signed_certificates'] == true,
      // A damaged principal cannot vouch for earlier bindings. A fresh epoch
      // fails closed: old trust simply stops matching.
      documentTrustPrincipalId:
          rawPrincipal is String && isValidPrincipalId(rawPrincipal)
          ? rawPrincipal
          : const Uuid().v4(),
      lastUsedAt: DateTime.tryParse(value['last_used_at']?.toString() ?? '')
          ?.toUtc(),
    );
  }
}

/// The persisted `hermes_connections_v1` document.
final class HermesConnectionsDocument {
  HermesConnectionsDocument({
    required List<HermesConnectionProfile> connections,
    this.legacySecretsOwner,
  }) : connections = List<HermesConnectionProfile>.unmodifiable(connections);

  static const int version = 1;

  final List<HermesConnectionProfile> connections;

  /// Profile that still has to receive the single-connection secrets stored
  /// before saved connections existed. Cleared once every legacy secret has
  /// been copied, verified, and deleted.
  final String? legacySecretsOwner;

  String encode() => jsonEncode(<String, Object?>{
    'version': version,
    'connections': [for (final connection in connections) connection.toJson()],
    if (legacySecretsOwner != null) 'legacy_secrets_owner': legacySecretsOwner,
  });

  /// Decodes a stored document. Returns null when the value is absent or not a
  /// document at all, so callers can tell "never written" from "empty".
  static HermesConnectionsDocument? decode(String? source) {
    if (source == null || source.length > 256 * 1024) return null;
    Object? value;
    try {
      value = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (value is! Map || value['connections'] is! List) return null;
    final seen = <String>{};
    final connections = <HermesConnectionProfile>[];
    for (final row in value['connections'] as List) {
      final profile = HermesConnectionProfile.fromJson(row);
      if (profile == null || !seen.add(profile.id)) continue;
      connections.add(profile);
      if (connections.length >= kMaxHermesConnections) break;
    }
    // Kept even when its profile is gone: the controller then discards the
    // orphaned legacy secrets instead of leaving them in the keychain.
    final owner = value['legacy_secrets_owner'];
    return HermesConnectionsDocument(
      connections: connections,
      legacySecretsOwner:
          owner is String && HermesConnectionProfile.isValidId(owner)
          ? owner
          : null,
    );
  }
}
