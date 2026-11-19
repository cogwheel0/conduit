import 'package:freezed_annotation/freezed_annotation.dart';

import 'chats.dart';
import 'composer.dart';

part 'queue.freezed.dart';
part 'queue.g.dart';

/// Names a composer's draft: a stored chat's, or a new chat's (in a
/// folder, or none). Params for `drafts.get`.
@freezed
abstract class DraftRef with _$DraftRef {
  const factory DraftRef({
    /// Null for a chat not started yet.
    String? chatId,

    /// A new chat's folder ("New Chat in Folder"); ignored with a [chatId].
    String? folderId,
  }) = _DraftRef;

  factory DraftRef.fromJson(Map<String, dynamic> json) =>
      _$DraftRefFromJson(json);
}

/// Params for `drafts.save`: what the composer holds now. An empty [text]
/// clears the draft.
@freezed
abstract class DraftSave with _$DraftSave {
  const factory DraftSave({
    String? chatId,
    String? folderId,
    @Default('') String text,
  }) = _DraftSave;

  factory DraftSave.fromJson(Map<String, dynamic> json) =>
      _$DraftSaveFromJson(json);
}

/// A composer's draft, as the account's database keeps it (the core's
/// `ComposerDraftStore`). Reply to `drafts.get` and `drafts.save`.
@freezed
abstract class Draft with _$Draft {
  const factory Draft({
    @Default('') String text,

    /// False where nothing is kept: a temporary or read-only chat, or no
    /// account database. The composer then holds the text only while open.
    @Default(true) bool stored,
  }) = _Draft;

  factory Draft.fromJson(Map<String, dynamic> json) => _$DraftFromJson(json);
}

/// One message queued behind a running answer.
@freezed
abstract class QueuedDraftDto with _$QueuedDraftDto {
  const factory QueuedDraftDto({
    required String id,

    /// The text as it will be sent (mentions in Open WebUI's wire format).
    required String text,
    @Default(<ChatFileDto>[]) List<ChatFileDto> files,
    @Default(<ContextAttachmentDto>[]) List<ContextAttachmentDto> context,

    /// Being stopped for, or being sent: it cannot be edited or removed.
    @Default(false) bool frozen,
  }) = _QueuedDraftDto;

  factory QueuedDraftDto.fromJson(Map<String, dynamic> json) =>
      _$QueuedDraftDtoFromJson(json);
}

/// Where a queue is in handing its drafts over (the core's
/// `ChatDraftQueuePhase`).
enum QueuePhase { idle, stopping, admitting }

/// A chat's queue: the core's `ChatDraftQueue`. Reply to every `queue.*`
/// method and the payload of `queue.changed`.
///
/// Every draft waiting when the answer finishes goes out as one message
/// (the texts joined by a blank line, the files in order), as Open WebUI's
/// own queue does. Queued drafts live in the daemon's memory only.
@freezed
abstract class QueueState with _$QueueState {
  const factory QueueState({
    required String chatId,
    @Default(<QueuedDraftDto>[]) List<QueuedDraftDto> drafts,
    @Default(QueuePhase.idle) QueuePhase phase,

    /// The last batch was refused before it was sent; nothing goes out
    /// again until `queue.retry` (or an edit).
    @Default(false) bool admissionFailed,

    /// A message typed now would be queued rather than sent: an answer is
    /// running in an Open WebUI chat that takes queued turns.
    @Default(false) bool offer,
  }) = _QueueState;

  factory QueueState.fromJson(Map<String, dynamic> json) =>
      _$QueueStateFromJson(json);
}

/// Params for `queue.add`: what the composer holds, queued behind the
/// running answer.
@freezed
abstract class QueueAdd with _$QueueAdd {
  const factory QueueAdd({
    required String chatId,
    required String text,
    @Default(<ComposerMentionDto>[]) List<ComposerMentionDto> mentions,

    /// Ids of files already uploaded through `/upload`, or picked from the
    /// server's files.
    @Default(<String>[]) List<String> fileIds,
    @Default(<ContextAttachmentDto>[]) List<ContextAttachmentDto> context,
  }) = _QueueAdd;

  factory QueueAdd.fromJson(Map<String, dynamic> json) =>
      _$QueueAddFromJson(json);
}

/// Params naming one queued draft: `queue.remove` and `queue.sendNow`.
@freezed
abstract class QueueDraftRef with _$QueueDraftRef {
  const factory QueueDraftRef({
    required String chatId,
    required String draftId,
  }) = _QueueDraftRef;

  factory QueueDraftRef.fromJson(Map<String, dynamic> json) =>
      _$QueueDraftRefFromJson(json);
}

/// Params for `queue.edit`.
@freezed
abstract class QueueEdit with _$QueueEdit {
  const factory QueueEdit({
    required String chatId,
    required String draftId,
    required String text,
  }) = _QueueEdit;

  factory QueueEdit.fromJson(Map<String, dynamic> json) =>
      _$QueueEditFromJson(json);
}

/// Reply to `queue.sendNow`.
@freezed
abstract class QueueSendNowResult with _$QueueSendNowResult {
  const factory QueueSendNowResult({
    /// The core's `ChatDraftSendNowOutcome`: `admitted`, `unavailable`,
    /// `blockedByUpload`, `stopFailed`, `changed` or `admissionFailed`.
    required String outcome,
    required QueueState queue,
  }) = _QueueSendNowResult;

  factory QueueSendNowResult.fromJson(Map<String, dynamic> json) =>
      _$QueueSendNowResultFromJson(json);
}
