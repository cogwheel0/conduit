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

/// Why a call shows an error, so a host can say it in the user's language
/// instead of printing an exception.
enum ChatVoiceModeError {
  /// The microphone permission is denied.
  microphoneDenied,

  /// The voice input could not be set up.
  inputUnavailable,

  /// Starting the voice services took too long.
  timeout,

  /// The recognizer heard nothing for several tries.
  noSpeech,

  /// `errorMessage` is text meant for the user (the server's reply error, or
  /// why a call cannot start): show it as it is.
  message,

  /// Anything else; `errorMessage` is an exception's text and is only for
  /// logs.
  other,
}

enum ChatVoiceModeStartResult { started, alreadyActive, cancelled, failed }

/// Why core refused to start a call, beside its English
/// [ChatVoiceModeSnapshot.errorMessage]: a code a client words in its own
/// language (the phone shows the English as it is).
enum VoiceCallRefusal {
  /// No model is chosen.
  modelRequired,

  /// Hermes's settings are still being read.
  hermesLoading,

  /// Hermes has no usable server URL or API key.
  hermesUnavailable,

  /// The chosen Direct connection is gone or turned off.
  directUnavailable,

  /// The model needs a signed-in Open WebUI account.
  signInRequired,

  /// The model's backend has no voice calls (LibreChat).
  backendUnsupported,
}

/// Something worth telling the user mid-call that does not end it.
enum ChatVoiceModeNotice {
  /// The user's words could not be made out.
  transcriptionFailed,

  /// The voice's reply stopped before it finished.
  replyIncomplete,

  /// Part of what was said could not be saved into the chat.
  transcriptNotSaved,
}

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
    this.errorKind,
    this.refusal,
    this.isCollapsed = false,
    this.isMuted = false,
    this.isSpeakerphoneEnabled = false,
    this.notice,
    this.noticeCount = 0,
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

  /// Why [errorMessage] is set; null when there is none.
  final ChatVoiceModeError? errorKind;

  /// When core refused to start the call, why, as a code; [errorMessage]
  /// is its English. It goes with the error it came with: a new
  /// [errorMessage] replaces it, and clearing the error clears it.
  final VoiceCallRefusal? refusal;
  final bool isCollapsed;
  final bool isMuted;
  final bool isSpeakerphoneEnabled;

  /// The latest notice of the call; [noticeCount] grows with each, so the
  /// same notice twice is shown twice.
  final ChatVoiceModeNotice? notice;
  final int noticeCount;

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
    ChatVoiceModeError? errorKind,
    VoiceCallRefusal? refusal,
    bool clearErrorMessage = false,
    bool? isCollapsed,
    bool? isMuted,
    bool? isSpeakerphoneEnabled,
    ChatVoiceModeNotice? notice,
    int? noticeCount,
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
      errorKind: clearErrorMessage ? null : errorKind ?? this.errorKind,
      refusal: clearErrorMessage
          ? null
          : errorMessage != null
          ? refusal
          : refusal ?? this.refusal,
      isCollapsed: isCollapsed ?? this.isCollapsed,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerphoneEnabled:
          isSpeakerphoneEnabled ?? this.isSpeakerphoneEnabled,
      notice: notice ?? this.notice,
      noticeCount: noticeCount ?? this.noticeCount,
    );
  }
}
