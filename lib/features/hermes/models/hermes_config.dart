import 'dart:collection';

import '../../../core/network/credential_transport_policy.dart';

/// Sentinel for [HermesConfig.copyWith] to distinguish "omitted" from an
/// explicit `null` (which clears a secret).
const Object _unset = Object();

enum HermesBackendMode { responsesApi, desktopGateway }

enum HermesDesktopAuthKind { legacyToken, nativePkce, dashboardCookie }

enum HermesDesktopTurnState {
  idle,
  running,
  synchronizing,
  reconnecting,
  unsupportedGateway,
}

final class HermesSessionBinding {
  const HermesSessionBinding({required this.storedId, required this.runtimeId});

  final String storedId;
  final String runtimeId;
}

final class HermesDesktopTokenSet {
  const HermesDesktopTokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  bool get needsRefresh =>
      !expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 60)));

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.toUtc().toIso8601String(),
  };

  static HermesDesktopTokenSet? fromJson(Object? value) {
    if (value is! Map) return null;
    final accessToken = value['access_token'];
    final refreshToken = value['refresh_token'];
    final expiresAt = DateTime.tryParse(value['expires_at']?.toString() ?? '');
    if (accessToken is! String ||
        accessToken.isEmpty ||
        refreshToken is! String ||
        refreshToken.isEmpty ||
        expiresAt == null) {
      return null;
    }
    return HermesDesktopTokenSet(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    );
  }
}

/// Origin-bound Desktop Gateway credentials. The complete document is stored
/// only in secure storage.
final class HermesDesktopCredentials {
  HermesDesktopCredentials({
    this.legacyToken,
    this.nativeTokens,
    Map<String, String> accessHeaders = const {},
  }) : accessHeaders = UnmodifiableMapView(Map.of(accessHeaders));

  final String? legacyToken;
  final HermesDesktopTokenSet? nativeTokens;
  final Map<String, String> accessHeaders;

  bool get isEmpty =>
      (legacyToken == null || legacyToken!.isEmpty) &&
      nativeTokens == null &&
      accessHeaders.isEmpty;

  Map<String, dynamic> toJson() => {
    'version': 1,
    if (legacyToken != null) 'legacy_token': legacyToken,
    if (nativeTokens != null) 'native_tokens': nativeTokens!.toJson(),
    'access_headers': accessHeaders,
  };

  static HermesDesktopCredentials fromJson(Object? value) {
    if (value is! Map) return HermesDesktopCredentials();
    final headers = <String, String>{};
    final rawHeaders = value['access_headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        if (entry.key is String && entry.value is String) {
          headers[entry.key as String] = entry.value as String;
        }
      }
    }
    return HermesDesktopCredentials(
      legacyToken: value['legacy_token'] is String
          ? value['legacy_token'] as String
          : null,
      nativeTokens: HermesDesktopTokenSet.fromJson(value['native_tokens']),
      accessHeaders: headers,
    );
  }
}

/// Immutable configuration for the optional direct Hermes Agent backend.
///
/// Non-secret fields ([enabled], [baseUrl]) persist in shared preferences;
/// [apiKey] and [sessionKey] are secrets held in `SecureCredentialStorage` and
/// merged in by the config notifier.
class HermesConfig {
  const HermesConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.mode = HermesBackendMode.responsesApi,
    this.desktopAuthKind = HermesDesktopAuthKind.legacyToken,
    this.desktopProfile = 'default',
    this.apiKey,
    this.sessionKey,
    this.desktopCredentials,
  });

  /// Whether the Hermes agent is toggled on and should surface in the picker.
  final bool enabled;

  /// Base URL of the Hermes API server, e.g. `http://192.168.1.10:8642/v1`.
  final String baseUrl;

  /// Existing configurations intentionally default to Responses API.
  final HermesBackendMode mode;

  final HermesDesktopAuthKind desktopAuthKind;

  /// Profile selected for Desktop Gateway REST and RPC operations.
  final String desktopProfile;

  /// Bearer token (`API_SERVER_KEY`) for the Hermes server.
  final String? apiKey;

  /// Long-term memory scope key (`X-Hermes-Session-Key`), per user.
  final String? sessionKey;

  final HermesDesktopCredentials? desktopCredentials;

  Map<String, String> get accessHeaders =>
      desktopCredentials?.accessHeaders ?? const {};

  Iterable<String> get sensitiveValues => <String>[
    if (apiKey?.isNotEmpty == true) apiKey!,
    if (sessionKey?.isNotEmpty == true) sessionKey!,
    if (desktopCredentials?.legacyToken?.isNotEmpty == true)
      desktopCredentials!.legacyToken!,
    if (desktopCredentials?.nativeTokens?.accessToken.isNotEmpty == true)
      desktopCredentials!.nativeTokens!.accessToken,
    if (desktopCredentials?.nativeTokens?.refreshToken.isNotEmpty == true)
      desktopCredentials!.nativeTokens!.refreshToken,
    ...accessHeaders.values.where((value) => value.isNotEmpty),
  ];

  /// Canonical origin used to bind secrets to their intended server.
  static String? connectionOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !isAllowedCredentialTransport(uri)) {
      return null;
    }
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:$port';
  }

  /// Canonical request root used to detect endpoint changes.
  static String? connectionEndpoint(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.endsWith('/v1')) {
      normalized = normalized.substring(0, normalized.length - '/v1'.length);
    }

    final uri = Uri.tryParse(normalized);
    final origin = connectionOrigin(normalized);
    if (uri == null || origin == null) return null;
    return '$origin${uri.path}'
        '${uri.hasQuery ? '?${uri.query}' : ''}'
        '${uri.hasFragment ? '#${uri.fragment}' : ''}';
  }

  /// Whether there is enough config to actually talk to a Hermes server.
  bool get isUsable {
    if (!enabled || connectionOrigin(baseUrl) == null) return false;
    return (mode == HermesBackendMode.desktopGateway &&
            isValidDesktopProfile(desktopProfile)) ||
        (apiKey?.trim().isNotEmpty ?? false);
  }

  static bool isValidDesktopProfile(String value) =>
      RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(value);

  static const int maxAccessHeaders = 10;
  static const Set<String> reservedAccessHeaderNames = {
    'authorization',
    'cookie',
    'host',
    'origin',
    'content-length',
    'connection',
    'upgrade',
    'sec-websocket-key',
    'sec-websocket-version',
    'sec-websocket-protocol',
    'sec-websocket-extensions',
    'x-hermes-session-token',
  };

  static String? validateAccessHeaders(Map<String, String> headers) {
    if (headers.length > maxAccessHeaders) {
      return 'At most 10 headers are allowed.';
    }
    final seen = <String>{};
    for (final entry in headers.entries) {
      final name = entry.key.trim();
      if (name != entry.key) return 'A header name is invalid.';
      final lower = name.toLowerCase();
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name)) {
        return 'A header name is invalid.';
      }
      if (!seen.add(lower)) return 'Header names must be unique.';
      if (reservedAccessHeaderNames.contains(lower) ||
          lower.startsWith('sec-websocket-')) {
        return '$name is reserved.';
      }
      if (name.length > 64 || entry.value.length > 1024) {
        return 'A header is too long.';
      }
      for (final codeUnit in entry.value.codeUnits) {
        if (codeUnit != 0x09 && (codeUnit < 0x20 || codeUnit >= 0x7f)) {
          return 'A header value is invalid.';
        }
      }
    }
    return null;
  }

  HermesConfig copyWith({
    bool? enabled,
    String? baseUrl,
    HermesBackendMode? mode,
    HermesDesktopAuthKind? desktopAuthKind,
    String? desktopProfile,
    // Sentinel-typed so secrets can be explicitly cleared: passing `null`
    // clears, while omitting keeps the current value.
    Object? apiKey = _unset,
    Object? sessionKey = _unset,
    Object? desktopCredentials = _unset,
  }) {
    return HermesConfig(
      enabled: enabled ?? this.enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      mode: mode ?? this.mode,
      desktopAuthKind: desktopAuthKind ?? this.desktopAuthKind,
      desktopProfile: desktopProfile ?? this.desktopProfile,
      apiKey: identical(apiKey, _unset) ? this.apiKey : apiKey as String?,
      sessionKey: identical(sessionKey, _unset)
          ? this.sessionKey
          : sessionKey as String?,
      desktopCredentials: identical(desktopCredentials, _unset)
          ? this.desktopCredentials
          : desktopCredentials as HermesDesktopCredentials?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HermesConfig &&
      other.enabled == enabled &&
      other.baseUrl == baseUrl &&
      other.mode == mode &&
      other.desktopAuthKind == desktopAuthKind &&
      other.desktopProfile == desktopProfile &&
      other.apiKey == apiKey &&
      other.sessionKey == sessionKey &&
      other.desktopCredentials?.legacyToken ==
          desktopCredentials?.legacyToken &&
      other.desktopCredentials?.nativeTokens?.accessToken ==
          desktopCredentials?.nativeTokens?.accessToken &&
      other.desktopCredentials?.nativeTokens?.refreshToken ==
          desktopCredentials?.nativeTokens?.refreshToken &&
      other.desktopCredentials?.nativeTokens?.expiresAt ==
          desktopCredentials?.nativeTokens?.expiresAt &&
      _mapsEqual(
        other.desktopCredentials?.accessHeaders ?? const {},
        desktopCredentials?.accessHeaders ?? const {},
      );

  @override
  int get hashCode {
    final headers =
        (desktopCredentials?.accessHeaders.entries ?? const Iterable.empty())
            .toList()
          ..sort((left, right) => left.key.compareTo(right.key));
    return Object.hash(
      enabled,
      baseUrl,
      mode,
      desktopAuthKind,
      desktopProfile,
      apiKey,
      sessionKey,
      desktopCredentials?.legacyToken,
      desktopCredentials?.nativeTokens?.accessToken,
      desktopCredentials?.nativeTokens?.refreshToken,
      desktopCredentials?.nativeTokens?.expiresAt,
      Object.hashAll(
        headers.map((entry) => Object.hash(entry.key, entry.value)),
      ),
    );
  }
}

bool _mapsEqual(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}
