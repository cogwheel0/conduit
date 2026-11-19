import 'package:freezed_annotation/freezed_annotation.dart';

import 'chats.dart';

part 'messages.freezed.dart';
part 'messages.g.dart';

/// Params for `messages.delete`.
///
/// Open WebUI deletes a message with its direct children (the answers to a
/// question) and gives their children to its parent; the core does the same
/// to the transcript.
@freezed
abstract class DeleteMessages with _$DeleteMessages {
  const factory DeleteMessages({
    required String chatId,
    required List<String> messageIds,

    /// Only counts what would go, for the confirmation, and deletes nothing.
    @Default(false) bool dryRun,
  }) = _DeleteMessages;

  factory DeleteMessages.fromJson(Map<String, dynamic> json) =>
      _$DeleteMessagesFromJson(json);
}

/// Reply to `messages.delete`.
@freezed
abstract class MessagesDeleted with _$MessagesDeleted {
  const factory MessagesDeleted({
    /// How many messages the delete removes (or removed).
    required int count,

    /// The chat afterwards; null for a dry run. Always on the wire.
    @JsonKey(includeIfNull: true) ChatDetail? chat,
  }) = _MessagesDeleted;

  factory MessagesDeleted.fromJson(Map<String, dynamic> json) =>
      _$MessagesDeletedFromJson(json);
}

/// Params for `turns.merge`: Merge Responses (mixture of agents) on a
/// Compare Models answer.
@freezed
abstract class MergeTurn with _$MergeTurn {
  const factory MergeTurn({
    required String chatId,

    /// The transcript message the answers belong to.
    required String messageId,

    /// The answer the merge is saved on: the one the window shows.
    required String targetId,

    /// The answers merged, two or more, in column order.
    @Default(<String>[]) List<String> sourceIds,

    /// Stops the merge running in this chat; what arrived is kept.
    @Default(false) bool stop,
  }) = _MergeTurn;

  factory MergeTurn.fromJson(Map<String, dynamic> json) =>
      _$MergeTurnFromJson(json);
}

/// Reply to `turns.merge`: the merge has started (or, for a stop, was asked
/// to end). Its text arrives as `messages.merge`.
@freezed
abstract class MergeStarted with _$MergeStarted {
  const factory MergeStarted({required String targetId}) = _MergeStarted;

  factory MergeStarted.fromJson(Map<String, dynamic> json) =>
      _$MergeStartedFromJson(json);
}

/// Payload of `messages.merge`, scoped to the chat: the merged response so
/// far. The whole text each time, coalesced like `turn.delta`.
@freezed
abstract class MergeProgress with _$MergeProgress {
  const factory MergeProgress({
    required String chatId,
    required String messageId,
    required String targetId,
    @Default('') String text,

    /// False once it has ended, whichever way.
    @Default(true) bool running,

    /// Why it ended without a merge: `unavailable` (the server has no
    /// merge), `notMergeable`, `ownerChanged`, `failed`. Absent on success
    /// and while running.
    String? error,
  }) = _MergeProgress;

  factory MergeProgress.fromJson(Map<String, dynamic> json) =>
      _$MergeProgressFromJson(json);
}
