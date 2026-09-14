/// Transient states of the self-hosted DeepSeek harness probe.
enum DeepSeekProbeStatus {
  /// No probe has run yet, or the config is not usable.
  idle,

  /// A probe request is in flight.
  probing,

  /// The server answered with a parseable boot manifest.
  connected,

  /// The server could not be reached (connection / network failure).
  unreachable,

  /// The server answered, but the answer was not a valid DSH boot page.
  error,
}

/// The outcome of one probe of a `dsh web` server root.
final class DeepSeekProbeResult {
  const DeepSeekProbeResult({
    required this.status,
    this.revision,
    this.pluginCount,
    this.error,
  });

  /// Whether the probe succeeded: [DeepSeekProbeStatus.connected], or a
  /// failure kind ([DeepSeekProbeStatus.unreachable] /
  /// [DeepSeekProbeStatus.error]). A probe result is never `idle`/`probing` —
  /// those belong to the live probe state.
  final DeepSeekProbeStatus status;

  /// The manifest `rev` consistency anchor (present when connected).
  final String? revision;

  /// Number of client entries in the manifest (present when connected).
  final int? pluginCount;

  /// Short human-readable failure description (absent when connected).
  final String? error;

  /// Whether the probe confirmed a usable server.
  bool get ok => status == DeepSeekProbeStatus.connected;

  @override
  bool operator ==(Object other) =>
      other is DeepSeekProbeResult &&
      other.status == status &&
      other.revision == revision &&
      other.pluginCount == pluginCount &&
      other.error == error;

  @override
  int get hashCode => Object.hash(status, revision, pluginCount, error);
}

/// The live probe state: the in-flight status plus the last settled result.
final class DeepSeekProbeState {
  const DeepSeekProbeState({
    this.status = DeepSeekProbeStatus.idle,
    this.lastResult,
  });

  /// Current probe status; transitions [DeepSeekProbeStatus.idle] →
  /// [DeepSeekProbeStatus.probing] → a settled result's status.
  final DeepSeekProbeStatus status;

  /// Last settled probe result (absent until a probe completes).
  final DeepSeekProbeResult? lastResult;

  bool get isIdle => status == DeepSeekProbeStatus.idle;

  DeepSeekProbeState copyWith({
    DeepSeekProbeStatus? status,
    DeepSeekProbeResult? lastResult,
  }) {
    return DeepSeekProbeState(
      status: status ?? this.status,
      lastResult: lastResult ?? this.lastResult,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeepSeekProbeState &&
      other.status == status &&
      other.lastResult == lastResult;

  @override
  int get hashCode => Object.hash(status, lastResult);
}