class SocketTransportAvailability {
  const SocketTransportAvailability({
    required this.allowPolling,
    required this.allowWebsocketOnly,
  });

  final bool allowPolling;
  final bool allowWebsocketOnly;

  Map<String, dynamic> toJson() {
    return {
      'allowPolling': allowPolling,
      'allowWebsocketOnly': allowWebsocketOnly,
    };
  }

  factory SocketTransportAvailability.fromJson(Map<String, dynamic> json) {
    return SocketTransportAvailability(
      allowPolling: json['allowPolling'] == true,
      allowWebsocketOnly: json['allowWebsocketOnly'] == true,
    );
  }

  // Value equality: derived fresh from backend config on each recompute, so
  // without this a logically-identical result is a new instance that needlessly
  // rebuilds every watcher (e.g. SocketServiceManager, which would then drop to
  // a loading/null state and churn the socket). See socketTransportOptionsProvider.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SocketTransportAvailability &&
          other.allowPolling == allowPolling &&
          other.allowWebsocketOnly == allowWebsocketOnly;

  @override
  int get hashCode => Object.hash(allowPolling, allowWebsocketOnly);
}
