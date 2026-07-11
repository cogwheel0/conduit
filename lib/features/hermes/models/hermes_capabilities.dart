/// Parsed `/v1/capabilities` feature flags.
///
/// Every flag defaults to **true** when the server doesn't clearly advertise it
/// (older servers, or a 404 on the endpoint): we only ever hide a feature when
/// the server explicitly says it's unsupported, never because parsing was
/// uncertain.
class HermesCapabilities {
  const HermesCapabilities({
    this.runApproval = true,
    this.skills = true,
    this.toolsets = true,
    this.jobs = true,
    this.jobsAdmin = true,
    this.sessions = true,
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

  /// The optimistic default used while loading or when discovery fails.
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
}
