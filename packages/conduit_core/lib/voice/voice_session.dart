/// The voice session's observable state.
///
/// Pure: a phase, the text either side has produced so far, and the
/// predicates that say what the user is allowed to do next. No audio, no
/// plugins, no Flutter — which is the point. The desktop renderer and the
/// daemon need to reason about a voice turn without being able to open a
/// microphone, and the phase rules are the part that must not be
/// reimplemented per host.
///
/// This is the state half of a `VoiceSessionMachine`.
/// The transitions still live in `ChatVoiceModeController`, interleaved with
/// the resources they drive; moving them is the remaining work.
library;

import 'package:meta/meta.dart';

enum ChatVoiceModePhase {
  idle,
  starting,
  listening,
  sending,
  speaking,
  paused,
  muted,
  ending,
  ended,
  error,
}

enum ChatVoiceModeStartResult { started, alreadyActive, cancelled, failed }

@immutable
class ChatVoiceModeSnapshot {
  const ChatVoiceModeSnapshot({
    this.phase = ChatVoiceModePhase.idle,
    this.transcript = '',
    this.assistantPreview = '',
    this.spokenResponse = '',
    this.spokenWordStart,
    this.spokenWordEnd,
    this.intensity = 0,
    this.elapsed = Duration.zero,
    this.startedAt,
    this.activeCallId,
    this.errorMessage,
    this.isCollapsed = false,
    this.isMuted = false,
    this.isSpeakerphoneEnabled = false,
  });

  final ChatVoiceModePhase phase;
  final String transcript;
  final String assistantPreview;
  final String spokenResponse;
  final int? spokenWordStart;
  final int? spokenWordEnd;
  final int intensity;
  final Duration elapsed;
  final DateTime? startedAt;
  final String? activeCallId;
  final String? errorMessage;
  final bool isCollapsed;
  final bool isMuted;
  final bool isSpeakerphoneEnabled;

  bool get isActive {
    return switch (phase) {
      ChatVoiceModePhase.idle ||
      ChatVoiceModePhase.ended ||
      ChatVoiceModePhase.error => false,
      _ => true,
    };
  }

  bool get canPause {
    return phase == ChatVoiceModePhase.listening ||
        phase == ChatVoiceModePhase.sending ||
        phase == ChatVoiceModePhase.speaking;
  }

  bool get canResume {
    return phase == ChatVoiceModePhase.paused ||
        phase == ChatVoiceModePhase.muted;
  }

  ChatVoiceModeSnapshot copyWith({
    ChatVoiceModePhase? phase,
    String? transcript,
    String? assistantPreview,
    String? spokenResponse,
    bool clearSpokenResponse = false,
    int? spokenWordStart,
    int? spokenWordEnd,
    bool clearSpokenProgress = false,
    int? intensity,
    Duration? elapsed,
    DateTime? startedAt,
    bool clearStartedAt = false,
    String? activeCallId,
    bool clearActiveCallId = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isCollapsed,
    bool? isMuted,
    bool? isSpeakerphoneEnabled,
  }) {
    return ChatVoiceModeSnapshot(
      phase: phase ?? this.phase,
      transcript: transcript ?? this.transcript,
      assistantPreview: assistantPreview ?? this.assistantPreview,
      spokenResponse: clearSpokenResponse
          ? ''
          : spokenResponse ?? this.spokenResponse,
      spokenWordStart: clearSpokenResponse || clearSpokenProgress
          ? null
          : spokenWordStart ?? this.spokenWordStart,
      spokenWordEnd: clearSpokenResponse || clearSpokenProgress
          ? null
          : spokenWordEnd ?? this.spokenWordEnd,
      intensity: intensity ?? this.intensity,
      elapsed: elapsed ?? this.elapsed,
      startedAt: clearStartedAt ? null : startedAt ?? this.startedAt,
      activeCallId: clearActiveCallId
          ? null
          : activeCallId ?? this.activeCallId,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      isCollapsed: isCollapsed ?? this.isCollapsed,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerphoneEnabled:
          isSpeakerphoneEnabled ?? this.isSpeakerphoneEnabled,
    );
  }
}
