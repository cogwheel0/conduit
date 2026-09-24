import 'package:meta/meta.dart';

/// Represents the current health status of the socket connection.
@immutable
class SocketHealth {
  const SocketHealth({
    required this.latencyMs,
    required this.isConnected,
    required this.transport,
    required this.reconnectCount,
    this.lastHeartbeat,
  });

  /// Round-trip latency in milliseconds from last heartbeat (-1 if unknown).
  final int latencyMs;

  /// Whether the socket is currently connected.
  final bool isConnected;

  /// Current transport type: 'websocket', 'polling', or 'unknown'.
  final String transport;

  /// Number of reconnections since service creation.
  final int reconnectCount;

  /// Timestamp of the last successful heartbeat response.
  final DateTime? lastHeartbeat;

  /// Whether the connection is using WebSocket transport.
  bool get isWebSocket => transport == 'websocket';

  /// Whether the connection is using HTTP polling transport.
  bool get isPolling => transport == 'polling';

  /// Whether latency information is available.
  bool get hasLatencyInfo => latencyMs >= 0;

  /// Connection quality based on latency.
  /// Thresholds account for the ~100ms measurement floor in heartbeat timing.
  /// Returns 'excellent' (<150ms), 'good' (<300ms), 'fair' (<1000ms),
  /// 'poor' (>=1000ms), or 'unknown' if no latency data.
  String get quality {
    if (latencyMs < 0) return 'unknown';
    if (latencyMs < 150) return 'excellent';
    if (latencyMs < 300) return 'good';
    if (latencyMs < 1000) return 'fair';
    return 'poor';
  }

  SocketHealth copyWith({
    int? latencyMs,
    bool? isConnected,
    String? transport,
    int? reconnectCount,
    DateTime? lastHeartbeat,
  }) {
    return SocketHealth(
      latencyMs: latencyMs ?? this.latencyMs,
      isConnected: isConnected ?? this.isConnected,
      transport: transport ?? this.transport,
      reconnectCount: reconnectCount ?? this.reconnectCount,
      lastHeartbeat: lastHeartbeat ?? this.lastHeartbeat,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latencyMs': latencyMs,
      'isConnected': isConnected,
      'transport': transport,
      'reconnectCount': reconnectCount,
      'lastHeartbeat': lastHeartbeat?.toIso8601String(),
    };
  }

  factory SocketHealth.fromJson(Map<String, dynamic> json) {
    return SocketHealth(
      latencyMs: json['latencyMs'] as int? ?? -1,
      isConnected: json['isConnected'] as bool? ?? false,
      transport: json['transport'] as String? ?? 'unknown',
      reconnectCount: json['reconnectCount'] as int? ?? 0,
      lastHeartbeat: json['lastHeartbeat'] != null
          ? DateTime.tryParse(json['lastHeartbeat'] as String)
          : null,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SocketHealth &&
        other.latencyMs == latencyMs &&
        other.isConnected == isConnected &&
        other.transport == transport &&
        other.reconnectCount == reconnectCount &&
        other.lastHeartbeat == lastHeartbeat;
  }

  @override
  int get hashCode {
    return Object.hash(
      latencyMs,
      isConnected,
      transport,
      reconnectCount,
      lastHeartbeat,
    );
  }

  @override
  String toString() {
    return 'SocketHealth('
        'latencyMs: $latencyMs, '
        'isConnected: $isConnected, '
        'transport: $transport, '
        'reconnectCount: $reconnectCount, '
        'lastHeartbeat: $lastHeartbeat)';
  }
}
