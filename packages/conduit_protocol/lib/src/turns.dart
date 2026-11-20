import 'package:freezed_annotation/freezed_annotation.dart';

import 'blocks.dart';
import 'chats.dart';
import 'composer.dart';

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

    /// Knowledge bases to draw on, chosen with `#`.
    @Default(<KnowledgeSummary>[]) List<KnowledgeSummary> knowledge,
    @Default(false) bool webSearch,
    @Default(false) bool imageGeneration,
    @Default(false) bool codeInterpreter,

    /// Ids of files already uploaded through `/upload`.
    @Default(<String>[]) List<String> fileIds,

    /// Web pages, YouTube transcripts, notes and knowledge files (`#`, the
    /// + menu's Web Page): the core's context attachments.
    @Default(<ContextAttachmentDto>[]) List<ContextAttachmentDto> context,

    /// `@` users and channels and `$` skills in [text], which the daemon
    /// writes in Open WebUI's wire format.
    @Default(<ComposerMentionDto>[]) List<ComposerMentionDto> mentions,

    /// Open WebUI toggle filters chosen in the + menu.
    @Default(<String>[]) List<String> filterIds,

    /// "Compare Models": the two models to answer side by side. Empty for an
    /// ordinary turn; [model] is then ignored.
    @Default(<String>[]) List<String> compareModels,

    /// Start a conversation the server never stores.
    ///
    /// Only meaningful with no [chatId]. The daemon assigns a `local:` id,
    /// which Open WebUI declines to persist, and keeps the transcript in
    /// memory for as long as it runs. It never reaches the sidebar, the
    /// database or another device.
    @Default(false) bool temporary,

    /// A new chat made in this folder ("New Chat in Folder"), so the
    /// folder's system prompt and knowledge apply from its first answer.
    String? folderId,

    /// A new chat's own settings (`chatSettings.*` keeps them for the
    /// window until the chat exists): its system prompt and parameters.
    Map<String, dynamic>? chatParams,
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

    /// Retry Without Reasoning Effort: the reasoning effort the chat saved
    /// and the picker's pick for the model are set back to automatic first,
    /// so the retry sends none.
    @Default(false) bool withoutReasoningEffort,
  }) = _RegenerateTurn;

  factory RegenerateTurn.fromJson(Map<String, dynamic> json) =>
      _$RegenerateTurnFromJson(json);
}

/// Params for `turns.rate`: a thumb up or down on an answer.
@freezed
abstract class RateTurn with _$RateTurn {
  const factory RateTurn({
    required String chatId,

    /// The assistant message being rated.
    required String messageId,

    /// 1 for up, -1 for down. Open WebUI has no "unrate"; a rating is
    /// changed, not removed.
    required int rating,
  }) = _RateTurn;

  factory RateTurn.fromJson(Map<String, dynamic> json) =>
      _$RateTurnFromJson(json);
}

/// Params for `turns.edit`.
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

    /// A Compare Models turn: the other models' answers, written at the same
    /// time under their own ids (their `turn.delta` and `turn.blocks` name
    /// them). Empty for an ordinary turn.
    @Default(<String>[]) List<String> companionIds,
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

/// Payload of `turn.blocks`: the answer so far, parsed.
///
/// Sent beside every `turn.delta`, coalesced the same way, and whenever
/// something besides the text changes (a status, a code execution, the
/// sources), plus once more, complete, as the answer finishes. Each one is
/// the whole answer, not a change to the last: a window that missed one
/// loses nothing, and a full snapshot of a long answer costs a fraction of
/// a frame to decode.
@freezed
abstract class TurnBlocks with _$TurnBlocks {
  const factory TurnBlocks({
    required String chatId,
    required String messageId,

    /// The answer's blocks, in order (see [MessageBlockKind]).
    @Default(<MessageBlockDto>[]) List<MessageBlockDto> blocks,

    /// The chat's task checklist as the turn left it ([ChatDetail.tasks]);
    /// null when the turn has not touched it.
    List<ChatTaskDto>? tasks,
  }) = _TurnBlocks;

  factory TurnBlocks.fromJson(Map<String, dynamic> json) =>
      _$TurnBlocksFromJson(json);
}

/// Payload of `turn.finished`: an answer ended, in whichever chat.
///
/// Unscoped, so every window hears it whether or not it shows the chat:
/// what an "answer ready" notification needs. The scoped `turn.completed`
/// and `turn.failed` carry the details.
@freezed
abstract class TurnFinished with _$TurnFinished {
  const factory TurnFinished({
    required String chatId,
    required String messageId,

    /// Whether it ended with an answer. A stopped answer counts: the user
    /// asked for it to end.
    required bool ok,

    /// Why it failed (a `ConduitErrorCodes` value); absent when [ok].
    String? code,

    /// The answer did not go out: its request waits in the outbox (sent
    /// while offline) and the chat's stored copy shows it queued. Nothing
    /// is ready yet, so no "answer ready"; when it goes out, its own
    /// `turn.*` events follow. [ok] stays true: nothing failed.
    @Default(false) bool queued,

    /// The server holds the question until a reply still running in the
    /// chat ends (Open WebUI 0.13.4), and answers it then under new ids:
    /// [messageId] is gone, and the chat's stored copy shows the question
    /// waiting ([ChatMessageDto.held]) until `chats.changed` brings the
    /// answer. Nothing is ready yet, so no "answer ready"; [ok] stays true.
    @Default(false) bool held,
  }) = _TurnFinished;

  factory TurnFinished.fromJson(Map<String, dynamic> json) =>
      _$TurnFinishedFromJson(json);
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

/// Reply to `turns.rate`.
@freezed
abstract class RatedResult with _$RatedResult {
  const factory RatedResult({required bool rated}) = _RatedResult;

  factory RatedResult.fromJson(Map<String, dynamic> json) =>
      _$RatedResultFromJson(json);
}

/// Reply to `turns.stop`.
@freezed
abstract class StoppedResult with _$StoppedResult {
  const factory StoppedResult({required bool stopped}) = _StoppedResult;

  factory StoppedResult.fromJson(Map<String, dynamic> json) =>
      _$StoppedResultFromJson(json);
}

/// Params for `turns.steer`: a message typed while Hermes is working.
@freezed
abstract class SteerTurn with _$SteerTurn {
  const factory SteerTurn({
    required String chatId,
    required String text,
    @Default(<ComposerMentionDto>[]) List<ComposerMentionDto> mentions,

    /// True steers the running turn; false sends the text as the next
    /// message, after it (the core's `HermesBusyTurnAction`).
    @Default(true) bool steer,
  }) = _SteerTurn;

  factory SteerTurn.fromJson(Map<String, dynamic> json) =>
      _$SteerTurnFromJson(json);
}

/// Reply to `turns.steer`.
@freezed
abstract class SteerResult with _$SteerResult {
  const factory SteerResult({
    /// Hermes took the message.
    required bool accepted,

    /// Hermes did not say whether the turn saw the steer: the composer keeps
    /// the text and says so, without sending it again.
    @Default(false) bool uncertain,
  }) = _SteerResult;

  factory SteerResult.fromJson(Map<String, dynamic> json) =>
      _$SteerResultFromJson(json);
}

/// Params for `turns.retryQueued` and `turns.removeQueued`: the queued
/// answer [messageId] in [chatId] ([ChatMessageDto.queued]).
@freezed
abstract class QueuedTurnRef with _$QueuedTurnRef {
  const factory QueuedTurnRef({
    required String chatId,
    required String messageId,

    /// `turns.retryQueued` only: send it again without the reasoning
    /// effort the provider refused.
    @Default(false) bool withoutReasoningEffort,
  }) = _QueuedTurnRef;

  factory QueuedTurnRef.fromJson(Map<String, dynamic> json) =>
      _$QueuedTurnRefFromJson(json);
}
