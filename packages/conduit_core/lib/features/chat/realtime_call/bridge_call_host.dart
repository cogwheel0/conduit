import 'package:meta/meta.dart';

import 'package:conduit_core/voice/voice_session.dart';

/// Where a turn the voice handed to the chat's model stands.
enum DelegatedTurnState {
  /// The model is still answering.
  working,

  /// The turn waits for the user in the chat: a tool to approve, or a
  /// question to answer.
  approval,

  /// The chat could not take the turn now (another answer is running, or it
  /// needs the user first). Nothing was sent.
  deferred,
  completed,
  failed,
  cancelled,
}

/// A turn the voice handed to the chat's model, running in the chat.
abstract interface class DelegatedTurn {
  /// The answer's message, or null when the turn was [deferred].
  String? get assistantMessageId;

  DelegatedTurnState get state;

  /// Each change of [state] until the turn settles.
  Stream<DelegatedTurnState> get changes;

  /// The answer to read out, once [state] is completed.
  String get answer;

  /// Stops the turn and returns once it is stopped.
  Future<void> cancel();
}

/// Something said in a call to save into the chat: the user's words and the
/// reply the voice gave them itself.
@immutable
final class RealtimeVoiceExchange {
  const RealtimeVoiceExchange({
    required this.userText,
    required this.userVoice,
    required this.voiceModel,
    required this.replyText,
    required this.replyVoice,
  });

  final String userText;

  /// The user message's `meta.voice`.
  final Map<String, Object?> userVoice;

  /// The voice model, which the reply is stored under.
  final String voiceModel;

  final String replyText;

  /// The reply's `meta.voice`.
  final Map<String, Object?> replyVoice;
}

/// What a bridge call needs from the chat it talks in.
abstract interface class BridgeCallHost {
  /// The chat so far, oldest first, as `role`/`content` pairs of user and
  /// assistant messages, labeled the way the voice should read them.
  List<Map<String, String>> chatSnapshot();

  /// Saves what was said into the chat.
  Future<void> recordExchange(RealtimeVoiceExchange exchange);

  /// Merges spoken transcripts into a delegated answer's `meta.voice`.
  Future<void> mergeSpeech(
    String assistantMessageId,
    Map<String, Object?> voice,
  );

  /// Sends the user's words to the chat's model as a turn of its own.
  /// [spokenContext] is the recent spoken conversation, for a backend that
  /// reads it with the turn.
  Future<DelegatedTurn> delegate(
    String text, {
    required Map<String, Object?> userVoice,
    String? spokenContext,
  });

  /// A problem worth telling the user that does not end the call.
  void notice(ChatVoiceModeNotice notice);
}
