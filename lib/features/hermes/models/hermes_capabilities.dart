/// Parsed `/v1/capabilities` feature flags.
///
/// Existing management features are optimistic for compatibility with older
/// servers. Image input is fail-closed: the client only enables it when the
/// server advertises a compatible endpoint.
class HermesCapabilities {
  const HermesCapabilities({
    this.runApproval = true,
    this.skills = true,
    this.toolsets = true,
    this.jobs = true,
    this.jobsAdmin = true,
    this.sessions = true,
    this.inputImages = false,
  });

  final bool runApproval;
  final bool skills;
  final bool toolsets;

  /// Whether scheduled jobs are exposed at all (the list surface).
  final bool jobs;

  /// Whether jobs can be mutated (create/edit/pause/run/delete). Servers can
  /// expose a read-only job list while disabling admin writes (`jobs_admin`).
  final bool jobsAdmin;

  final bool sessions;

  /// Whether Conduit can send image content through Responses streaming.
  ///
  /// Hermes does not currently publish a separate vision flag, so this is
  /// inferred from its advertised Responses streaming API. It intentionally
  /// remains false when discovery is unavailable or ambiguous.
  final bool inputImages;

  /// The compatibility default used while loading or when discovery fails.
  static const HermesCapabilities enabledByDefault = HermesCapabilities();

  factory HermesCapabilities.fromJson(Map<String, dynamic> json) {
    return HermesCapabilities(
      runApproval: _resolve(json, const [
        'run_approval_response',
        'approval_events',
        'run_approval',
        'runApproval',
      ]),
      skills: _resolve(json, const ['skills_api', 'skills']),
      toolsets: _resolve(json, const ['toolsets']),
      // Show the jobs surface unless explicitly disabled; admin writes are
      // governed separately by `jobs_admin`.
      jobs: _resolve(json, const ['jobs', 'cron']),
      jobsAdmin: _resolve(json, const ['jobs_admin']),
      sessions: _resolve(json, const [
        'session_resources',
        'sessions',
        'session_key_header',
      ]),
      inputImages: _resolveResponsesImageInput(json),
    );
  }

  /// Looks for any of [names] as an explicit boolean in `features`/top-level,
  /// or as a present key under `endpoints`/`features`. Defaults to true.
  static bool _resolve(Map<String, dynamic> json, List<String> names) {
    final features = json['features'];
    final endpoints = json['endpoints'];
    for (final name in names) {
      if (json[name] is bool) return json[name] as bool;
      if (features is Map && features[name] is bool) {
        return features[name] as bool;
      }
      if (features is Map && features.containsKey(name)) {
        return true;
      }
      if (endpoints is Map && endpoints.containsKey(name)) return true;
    }
    return true;
  }

  static bool _resolveResponsesImageInput(Map<String, dynamic> json) {
    final topLevelApi = json['responses_api'];
    final topLevelStreaming = json['responses_streaming'];
    final features = json['features'];
    final featureApi = features is Map ? features['responses_api'] : null;
    final featureStreaming = features is Map
        ? features['responses_streaming']
        : null;
    // Conflicting discovery data must fail closed. This also makes an explicit
    // false authoritative over a stale endpoint entry.
    if (topLevelApi == false ||
        topLevelStreaming == false ||
        featureApi == false ||
        featureStreaming == false) {
      return false;
    }
    if (topLevelStreaming == true || featureStreaming == true) return true;

    final endpoints = json['endpoints'];
    if (endpoints is! Map || !endpoints.containsKey('responses')) {
      return false;
    }

    final endpoint = endpoints['responses'];
    if (endpoint is String) {
      return _isResponsesPath(endpoint);
    }
    if (endpoint is! Map) return false;

    final method = endpoint['method'];
    if (method != null &&
        (method is! String || method.trim().toUpperCase() != 'POST')) {
      return false;
    }
    final path = endpoint['path'];
    return path is String && _isResponsesPath(path);
  }

  static bool _isResponsesPath(String path) {
    final normalized = path.trim().toLowerCase();
    return normalized == '/v1/responses' || normalized == '/responses';
  }
}
