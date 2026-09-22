import 'package:freezed_annotation/freezed_annotation.dart';

part 'turns.freezed.dart';
part 'turns.g.dart';

/// Params for `turns.send`.
@freezed
abstract class SendTurn with _$SendTurn {
  const factory SendTurn({
    /// Null starts a new conversation. The daemon assigns the id and reports
    /// it in [SendTurnAccepted], so the renderer never invents one -- a
    /// client-side id would have to be reconciled against the server's, which
    /// is what `route.remap` exists to clean up after.
    String? chatId,

    /// Null lets the daemon choose -- the account's selected model, or the
    /// first the server offers. The renderer should not have to fetch a model
    /// list before it can send its first message, and the daemon already
    /// knows which model this account last used.
    String? model,
    required String text,
    @Default(<String>[]) List<String> toolIds,
    @Default(false) bool webSearch,
    @Default(false) bool imageGeneration,
    @Default(false) bool codeInterpreter,

    /// Ids of files already uploaded through `/upload`.
    @Default(<String>[]) List<String> fileIds,
  }) = _SendTurn;

  factory SendTurn.fromJson(Map<String, dynamic> json) =>
      _$SendTurnFromJson(json);
}

/// Reply to `turns.send`.
///
/// The call returns as soon as the server has accepted the request; the
/// answer arrives as `turn.delta` events. Blocking until completion would
/// make a two-minute reply a two-minute RPC, and lose every token that
/// arrived before it.
@freezed
abstract class SendTurnAccepted with _$SendTurnAccepted {
  const factory SendTurnAccepted({
    required String chatId,

    /// The message the user just sent, as persisted.
    required String userMessageId,

    /// The placeholder the deltas will fill in.
    required String assistantMessageId,
  }) = _SendTurnAccepted;

  factory SendTurnAccepted.fromJson(Map<String, dynamic> json) =>
      _$SendTurnAcceptedFromJson(json);
}

/// Params for `turns.regenerate`.
///
/// Addresses the *assistant* message being replaced, not the user message
/// that prompted it. That is the one the user is looking at and the one the
/// button sits under, and it is unambiguous -- a user message may have
/// several answers already, and naming it would not say which to redo.
@freezed
abstract class RegenerateTurn with _$RegenerateTurn {
  const factory RegenerateTurn({
    required String chatId,
    required String messageId,

    /// Null keeps the model the conversation is already using. Passing one
    /// is how "try this again with a better model" works.
    String? model,
  }) = _RegenerateTurn;

  factory RegenerateTurn.fromJson(Map<String, dynamic> json) =>
      _$RegenerateTurnFromJson(json);
}

/// Params for `turns.edit` (WP-3.2).
///
/// Sends a replacement for one of the user's messages and answers it. On
/// the server this is a branch, not an overwrite: the new question becomes
/// a sibling of the old one, and the old question and everything after it
/// stay in the history. Editing a question to ask it better should never
/// cost the answer to the original.
@freezed
abstract class EditTurn with _$EditTurn {
  const factory EditTurn({
    required String chatId,

    /// The user message being replaced.
    required String messageId,
    required String text,
    String? model,
  }) = _EditTurn;

  factory EditTurn.fromJson(Map<String, dynamic> json) =>
      _$EditTurnFromJson(json);
}

/// Payload of `turn.started`.
@freezed
abstract class TurnStarted with _$TurnStarted {
  const factory TurnStarted({
    required String chatId,
    required String messageId,
    required String model,
  }) = _TurnStarted;

  factory TurnStarted.fromJson(Map<String, dynamic> json) =>
      _$TurnStartedFromJson(json);
}

/// Payload of `turn.delta`.
///
/// Coalesced by the daemon to at most 60 Hz. [text] is the *whole* content so
/// far rather than the increment: a renderer that missed a frame would
/// otherwise have to ask for a resync, and the string is cheap next to the
/// markdown parse that follows it.
@freezed
abstract class TurnDelta with _$TurnDelta {
  const factory TurnDelta({
    required String chatId,
    required String messageId,
    required String text,

    /// Reasoning content, when the model emits it separately.
    String? reasoning,
  }) = _TurnDelta;

  factory TurnDelta.fromJson(Map<String, dynamic> json) =>
      _$TurnDeltaFromJson(json);
}

/// Payload of `turn.completed`.
@freezed
abstract class TurnCompleted with _$TurnCompleted {
  const factory TurnCompleted({
    required String chatId,
    required String messageId,
    required String text,
    String? reasoning,

    /// Token counts, when the server reported them.
    Map<String, int>? usage,
  }) = _TurnCompleted;

  factory TurnCompleted.fromJson(Map<String, dynamic> json) =>
      _$TurnCompletedFromJson(json);
}

/// Payload of `turn.failed`.
@freezed
abstract class TurnFailed with _$TurnFailed {
  const factory TurnFailed({
    required String chatId,
    required String messageId,
    required String code,
    @Default(<String, String>{}) Map<String, String> args,

    /// Whatever had already streamed before the failure. Kept rather than
    /// discarded: a partial answer plus an error is more useful than an
    /// error alone, and it is what the user already watched arrive.
    @Default('') String partialText,
  }) = _TurnFailed;

  factory TurnFailed.fromJson(Map<String, dynamic> json) =>
      _$TurnFailedFromJson(json);
}

/// Params for `turns.stop`.
@freezed
abstract class StopTurn with _$StopTurn {
  const factory StopTurn({required String chatId}) = _StopTurn;

  factory StopTurn.fromJson(Map<String, dynamic> json) =>
      _$StopTurnFromJson(json);
}
