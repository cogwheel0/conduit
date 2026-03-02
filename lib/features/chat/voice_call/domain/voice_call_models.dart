import 'package:flutter/foundation.dart';

/// High-level lifecycle phases for a voice call session.
enum CallPhase {
  idle,
  starting,
  connecting,
  listening,
  thinking,
  speaking,
  paused,
  muted,
  ending,
  ended,
  failed,
}

/// Reasons that can pause an active call.
enum CallPauseReason { user, mute, system }

/// Reasons that can end a call.
enum CallEndReason { user, nativeSurface, lifecycle, fatalError }

/// Categorizes failures for consistent UX and recovery behavior.
enum CallFailureCategory {
  permission,
  network,
  transport,
  speechInput,
  speechOutput,
  platform,
  unknown,
}

/// Structured failure payload for the call UI and telemetry.
@immutable
class CallFailure {
  const CallFailure({
    required this.category,
    required this.message,
    required this.recoverable,
    this.cause,
  });

  final CallFailureCategory category;
  final String message;
  final bool recoverable;
  final Object? cause;
}

/// Immutable call session state exposed to the UI.
@immutable
class VoiceCallSnapshot {
  const VoiceCallSnapshot({
    this.phase = CallPhase.idle,
    this.transcript = '',
    this.response = '',
    this.intensity = 0,
    this.isMuted = false,
    this.pauseReasons = const <CallPauseReason>{},
    this.callStartedAt,
    this.elapsed = Duration.zero,
    this.failure,
  });

  final CallPhase phase;
  final String transcript;
  final String response;
  final int intensity;
  final bool isMuted;
  final Set<CallPauseReason> pauseReasons;
  final DateTime? callStartedAt;
  final Duration elapsed;
  final CallFailure? failure;

  bool get isActive =>
      phase != CallPhase.idle &&
      phase != CallPhase.ended &&
      phase != CallPhase.failed;

  bool get canPause => phase == CallPhase.listening;
  bool get canResume =>
      phase == CallPhase.paused ||
      phase == CallPhase.muted ||
      pauseReasons.isNotEmpty;

  VoiceCallSnapshot copyWith({
    CallPhase? phase,
    String? transcript,
    String? response,
    int? intensity,
    bool? isMuted,
    Set<CallPauseReason>? pauseReasons,
    Object? callStartedAt = _sentinel,
    Duration? elapsed,
    Object? failure = _sentinel,
  }) {
    return VoiceCallSnapshot(
      phase: phase ?? this.phase,
      transcript: transcript ?? this.transcript,
      response: response ?? this.response,
      intensity: intensity ?? this.intensity,
      isMuted: isMuted ?? this.isMuted,
      pauseReasons: pauseReasons ?? this.pauseReasons,
      callStartedAt: callStartedAt == _sentinel
          ? this.callStartedAt
          : callStartedAt as DateTime?,
      elapsed: elapsed ?? this.elapsed,
      failure: failure == _sentinel ? this.failure : failure as CallFailure?,
    );
  }

  static const Object _sentinel = Object();
}
