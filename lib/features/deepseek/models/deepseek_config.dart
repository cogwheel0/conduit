/// Sentinel for [DeepSeekConfig.copyWith] to distinguish "omitted" from an
/// explicit `null` (which clears [DeepSeekConfig.trustedHost]).
const Object _unset = Object();

/// Immutable configuration for the optional self-hosted DeepSeek harness
/// (DSH) backend.
///
/// Every field is non-secret and persists in shared preferences: DSH
/// authenticates with a host allowlist (loopback or a `--trusted-host`
/// authority) rather than an API key, so no secure storage is involved.
final class DeepSeekConfig {
  const DeepSeekConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.trustedHost,
    this.allowSelfSignedCertificates = false,
  });

  /// Whether the DeepSeek harness is toggled on and should surface in the
  /// picker.
  final bool enabled;

  /// Base URL of the `dsh web` server, e.g. `http://127.0.0.1:3080`.
  final String baseUrl;

  /// Host or `host:port` authority this client should trust when the server
  /// runs off loopback. Empty means "loopback only".
  final String? trustedHost;

  /// Trusts an unverified TLS certificate for this server, matching the
  /// equivalent Open WebUI and direct-connection setting.
  final bool allowSelfSignedCertificates;

  /// Whether there is enough config to actually reach the server.
  bool get isUsable => enabled && connectionOrigin(baseUrl) != null;

  /// Normalized trusted-host authority, or null when unset.
  String? get normalizedTrustedHost {
    final value = trustedHost?.trim();
    if (value == null || value.isEmpty) return null;
    return value.toLowerCase();
  }

  /// Canonical origin used to bind this config to its intended server.
  static String? connectionOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:$port';
  }

  /// Canonical request root (origin plus any user-supplied path, without a
  /// trailing slash) used as the probe target.
  static String? connectionEndpoint(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final uri = Uri.tryParse(normalized);
    final origin = connectionOrigin(normalized);
    if (uri == null || origin == null) return null;
    return '$origin${uri.path}';
  }

  DeepSeekConfig copyWith({
    bool? enabled,
    String? baseUrl,
    // Sentinel-typed so the trusted host can be explicitly cleared: passing
    // `null` clears, while omitting keeps the current value.
    Object? trustedHost = _unset,
    bool? allowSelfSignedCertificates,
  }) {
    return DeepSeekConfig(
      enabled: enabled ?? this.enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      trustedHost: identical(trustedHost, _unset)
          ? this.trustedHost
          : trustedHost as String?,
      allowSelfSignedCertificates:
          allowSelfSignedCertificates ?? this.allowSelfSignedCertificates,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeepSeekConfig &&
      other.enabled == enabled &&
      other.baseUrl == baseUrl &&
      other.trustedHost == trustedHost &&
      other.allowSelfSignedCertificates == allowSelfSignedCertificates;

  @override
  int get hashCode => Object.hash(
        enabled,
        baseUrl,
        trustedHost,
        allowSelfSignedCertificates,
      );
}