/// Sentinel for [HermesConfig.copyWith] to distinguish "omitted" from an
/// explicit `null` (which clears a secret).
const Object _unset = Object();

/// Immutable configuration for the optional direct Hermes Agent backend.
///
/// Non-secret fields ([enabled], [baseUrl]) persist in shared preferences;
/// [apiKey] and [sessionKey] are secrets held in `SecureCredentialStorage` and
/// merged in by the config notifier.
class HermesConfig {
  const HermesConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.apiKey,
    this.sessionKey,
  });

  /// Whether the Hermes agent is toggled on and should surface in the picker.
  final bool enabled;

  /// Base URL of the Hermes API server, e.g. `http://192.168.1.10:8642/v1`.
  final String baseUrl;

  /// Bearer token (`API_SERVER_KEY`) for the Hermes server.
  final String? apiKey;

  /// Long-term memory scope key (`X-Hermes-Session-Key`), per user.
  final String? sessionKey;

  /// Whether there is enough config to actually talk to a Hermes server.
  bool get isUsable =>
      enabled &&
      baseUrl.trim().isNotEmpty &&
      (apiKey?.trim().isNotEmpty ?? false);

  HermesConfig copyWith({
    bool? enabled,
    String? baseUrl,
    // Sentinel-typed so secrets can be explicitly cleared: passing `null`
    // clears, while omitting keeps the current value.
    Object? apiKey = _unset,
    Object? sessionKey = _unset,
  }) {
    return HermesConfig(
      enabled: enabled ?? this.enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: identical(apiKey, _unset) ? this.apiKey : apiKey as String?,
      sessionKey: identical(sessionKey, _unset)
          ? this.sessionKey
          : sessionKey as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HermesConfig &&
      other.enabled == enabled &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.sessionKey == sessionKey;

  @override
  int get hashCode => Object.hash(enabled, baseUrl, apiKey, sessionKey);
}
