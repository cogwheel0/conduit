import 'package:meta/meta.dart';

enum RealtimeCallPhase { connecting, live, ended }

/// What a realtime call shows: whether it is up, who is talking, what each
/// side last said, and whether the chat's model is working on something.
@immutable
final class RealtimeCallState {
  const RealtimeCallState({
    this.phase = RealtimeCallPhase.connecting,
    this.muted = false,
    this.userSpeaking = false,
    this.assistantSpeaking = false,
    this.working = false,
    this.approval = false,
    this.inputLevel = 0,
    this.outputLevel = 0,
    this.voiceModel,
    this.voice,
    this.userCaption = '',
    this.assistantCaption = '',
    this.error,
  });

  final RealtimeCallPhase phase;
  final bool muted;
  final bool userSpeaking;
  final bool assistantSpeaking;

  /// The chat's model is answering a request the voice handed it.
  final bool working;

  /// That answer waits for the user in the chat.
  final bool approval;

  final double inputLevel;
  final double outputLevel;
  final String? voiceModel;
  final String? voice;

  /// The user's latest transcribed words.
  final String userCaption;

  /// What the voice is saying, or last said.
  final String assistantCaption;

  /// Why the call ended, safe to show; null when it ended normally.
  final String? error;

  RealtimeCallState copyWith({
    RealtimeCallPhase? phase,
    bool? muted,
    bool? userSpeaking,
    bool? assistantSpeaking,
    bool? working,
    bool? approval,
    double? inputLevel,
    double? outputLevel,
    String? voiceModel,
    String? voice,
    String? userCaption,
    String? assistantCaption,
    String? error,
  }) => RealtimeCallState(
    phase: phase ?? this.phase,
    muted: muted ?? this.muted,
    userSpeaking: userSpeaking ?? this.userSpeaking,
    assistantSpeaking: assistantSpeaking ?? this.assistantSpeaking,
    working: working ?? this.working,
    approval: approval ?? this.approval,
    inputLevel: inputLevel ?? this.inputLevel,
    outputLevel: outputLevel ?? this.outputLevel,
    voiceModel: voiceModel ?? this.voiceModel,
    voice: voice ?? this.voice,
    userCaption: userCaption ?? this.userCaption,
    assistantCaption: assistantCaption ?? this.assistantCaption,
    error: error ?? this.error,
  );
}

/// A realtime call's engine, whichever protocol its voice speaks.
abstract interface class RealtimeCallEngine {
  RealtimeCallState get state;

  /// Every change of [state].
  Stream<RealtimeCallState> get states;

  /// Connects and returns once the call is live. Throws with a message safe
  /// to show when it cannot start.
  Future<void> connect();

  void setMuted(bool muted);

  /// Stops the voice mid-sentence.
  void interrupt();

  /// Ends the call, saving what was said. Safe to call more than once.
  Future<void> end();
}
