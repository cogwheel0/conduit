import 'package:freezed_annotation/freezed_annotation.dart';

part 'notes.freezed.dart';
part 'notes.g.dart';

/// Where a note falls in the notes list's time groups, by when it last
/// changed: the core's own calendar days, as the phone groups them.
enum NoteSection { today, yesterday, previous7Days, previous30Days, older }

/// A note, as the list shows it.
@freezed
abstract class NoteSummary with _$NoteSummary {
  const factory NoteSummary({
    required String id,
    required String title,
    required int updatedAtMs,
    @Default(false) bool pinned,

    /// The start of the note's text, for the list; markdown.
    @Default('') String preview,

    /// Kept beside the original because both were edited at once: this
    /// computer's version, while another device's won the original.
    @Default(false) bool conflictCopy,

    /// Its time group in the notes list (pinned notes have one too).
    @Default(NoteSection.older) NoteSection section,

    /// The account may change it: its own note, or one shared with write
    /// access. Any other note opens read-only and offers no Delete.
    @Default(true) bool canEdit,

    /// Not editable only because the server has not said yet whether the
    /// account may edit this shared note (offline): reconnecting tells.
    @Default(false) bool accessUnverified,

    /// Share Access… is offered: a note on the server the account may
    /// edit, on a server that lets it share notes.
    @Default(false) bool canShare,

    /// Who shared it, when it is someone else's note.
    String? owner,
  }) = _NoteSummary;

  factory NoteSummary.fromJson(Map<String, dynamic> json) =>
      _$NoteSummaryFromJson(json);
}

/// Reply to `notes.list`: pinned first, then most recently changed.
@freezed
abstract class NoteList with _$NoteList {
  const factory NoteList({@Default(<NoteSummary>[]) List<NoteSummary> notes}) =
      _NoteList;

  factory NoteList.fromJson(Map<String, dynamic> json) =>
      _$NoteListFromJson(json);
}

/// Params for `notes.list`: text to search for, or none for every note.
@freezed
abstract class NoteQuery with _$NoteQuery {
  const factory NoteQuery({@Default('') String query}) = _NoteQuery;

  factory NoteQuery.fromJson(Map<String, dynamic> json) =>
      _$NoteQueryFromJson(json);
}

/// A note to edit: its summary and its body as Quill ops.
///
/// Stored as markdown (the format the web client and mobile share); the
/// daemon converts in both directions so the editor only ever sees a
/// Quill document.
@freezed
abstract class NoteDetail with _$NoteDetail {
  const factory NoteDetail({
    required NoteSummary summary,

    /// The body of page [pageId], as Quill ops.
    @Default(<Map<String, dynamic>>[]) List<Map<String, dynamic>> ops,

    /// Files attached to the note: recordings, documents.
    @Default(<NoteFile>[]) List<NoteFile> files,

    /// An Open WebUI 0.12.5 note's pages, parents before their subpages;
    /// empty for a note with one page.
    @Default(<NotePageDto>[]) List<NotePageDto> pages,

    /// The page [ops] are: the main page (`main`) unless asked for another.
    @Default('main') String pageId,

    /// Page [pageId]'s stored markdown (Copy copies it, as the phone's
    /// Copy does).
    @Default('') String markdown,

    /// Set by `notes.save` when the note had been deleted elsewhere: the
    /// text was kept as this new note, and this is the deleted one's id.
    String? recoveredFrom,
  }) = _NoteDetail;

  factory NoteDetail.fromJson(Map<String, dynamic> json) =>
      _$NoteDetailFromJson(json);
}

/// A page of a note with several (Open WebUI 0.12.5 and later). Adding,
/// renaming and moving pages is done on the web.
@freezed
abstract class NotePageDto with _$NotePageDto {
  const factory NotePageDto({
    required String id,
    required String title,

    /// The titles down to it (`Plans / Spring`), as VoiceOver reads it.
    @Default('') String path,

    /// How deep it is nested: 0 for a top-level page.
    @Default(0) int depth,
  }) = _NotePageDto;

  factory NotePageDto.fromJson(Map<String, dynamic> json) =>
      _$NotePageDtoFromJson(json);
}

/// Params for `notes.get`: the note, and the page to read (by default the
/// main page).
@freezed
abstract class NoteOpen with _$NoteOpen {
  const factory NoteOpen({required String id, String? pageId}) = _NoteOpen;

  factory NoteOpen.fromJson(Map<String, dynamic> json) =>
      _$NoteOpenFromJson(json);
}

/// The state of a recording made in a note, while it waits to be attached.
enum NoteRecordingState {
  /// Saved on this Mac; it uploads when the server can be reached.
  waiting,

  /// Uploading, or being attached to the note.
  uploading,

  /// The upload failed; it is kept for another try.
  failed,
}

/// A recording made in a note and not attached yet. It is kept on this Mac
/// until the server has it, through a lost connection or a relaunch.
@freezed
abstract class NoteRecordingDto with _$NoteRecordingDto {
  const factory NoteRecordingDto({
    required String id,
    required String name,
    @Default(NoteRecordingState.waiting) NoteRecordingState state,
    @Default(0) int size,
    @Default(0) int createdAtMs,

    /// The page it was made on, which it is attached to.
    String? pageId,
  }) = _NoteRecordingDto;

  factory NoteRecordingDto.fromJson(Map<String, dynamic> json) =>
      _$NoteRecordingDtoFromJson(json);
}

/// Reply to `notes.recordings` and the calls that change them: a note's
/// recordings not attached yet, oldest first.
@freezed
abstract class NoteRecordings with _$NoteRecordings {
  const factory NoteRecordings({
    required String noteId,
    @Default(<NoteRecordingDto>[]) List<NoteRecordingDto> recordings,
  }) = _NoteRecordings;

  factory NoteRecordings.fromJson(Map<String, dynamic> json) =>
      _$NoteRecordingsFromJson(json);
}

/// Params for `notes.addRecording`: an audio file the window recorded, which
/// the daemon moves into the account's storage before anything else, then
/// uploads and attaches to page [pageId] (by default the main page).
@freezed
abstract class NoteRecordingAdd with _$NoteRecordingAdd {
  const factory NoteRecordingAdd({
    required String noteId,
    required String path,
    String? pageId,
  }) = _NoteRecordingAdd;

  factory NoteRecordingAdd.fromJson(Map<String, dynamic> json) =>
      _$NoteRecordingAddFromJson(json);
}

/// Params naming one of a note's waiting recordings.
@freezed
abstract class NoteRecordingRef with _$NoteRecordingRef {
  const factory NoteRecordingRef({
    required String noteId,
    required String id,
  }) = _NoteRecordingRef;

  factory NoteRecordingRef.fromJson(Map<String, dynamic> json) =>
      _$NoteRecordingRefFromJson(json);
}

/// A file attached to a note, stored as an Open WebUI file.
@freezed
abstract class NoteFile with _$NoteFile {
  const factory NoteFile({
    required String id,
    required String name,
    int? size,

    /// The MIME type, when known: what decides whether it plays inline.
    String? contentType,
  }) = _NoteFile;

  factory NoteFile.fromJson(Map<String, dynamic> json) =>
      _$NoteFileFromJson(json);
}

/// Params for `notes.attach`: a file already uploaded through `/upload`,
/// linked from page [pageId] (by default the main page) on a server with
/// pages.
@freezed
abstract class NoteAttach with _$NoteAttach {
  const factory NoteAttach({
    required String noteId,
    required NoteFile file,
    String? pageId,
  }) = _NoteAttach;

  factory NoteAttach.fromJson(Map<String, dynamic> json) =>
      _$NoteAttachFromJson(json);
}

/// Params for `notes.detach`: the file comes out of the file list and out
/// of page [pageId]'s links (by default the main page's).
@freezed
abstract class NoteDetach with _$NoteDetach {
  const factory NoteDetach({
    required String noteId,
    required String fileId,
    String? pageId,
  }) = _NoteDetach;

  factory NoteDetach.fromJson(Map<String, dynamic> json) =>
      _$NoteDetachFromJson(json);
}

/// Params for `notes.save`: a new note when [id] is null.
///
/// [ops] null leaves the body alone (a rename); otherwise it replaces the
/// body of page [pageId] (by default the main page).
///
/// [baseOps] is that page as the editor last loaded or saved it. A file
/// the stored page gained since (a recording attached meanwhile) is kept,
/// and a file link the user took out stays out, as the phone merges them.
///
/// Refusals, as errors: `resource.conflict` with `reason: readOnly` when
/// the account may no longer edit the note (the text stays in the
/// editor); `resource.notFound` with `reason: page` when the page was
/// removed elsewhere. A note deleted elsewhere is not refused: the text
/// is kept as a new note ([NoteDetail.recoveredFrom]).
///
/// `accountId`: the account the editor opened the note under (an account's
/// id, as [AccountRef.accountId]). When another account is active, the save
/// -- a new note too -- is refused with `auth.sessionExpired`, `reason:
/// account`, and nothing is written: the text stays with the editor for
/// that account.
@freezed
abstract class NoteSave with _$NoteSave {
  const factory NoteSave({
    String? id,
    required String title,
    List<Map<String, dynamic>>? ops,
    String? pageId,
    List<Map<String, dynamic>>? baseOps,
    String? accountId,
  }) = _NoteSave;

  factory NoteSave.fromJson(Map<String, dynamic> json) =>
      _$NoteSaveFromJson(json);
}

/// Params naming one note.
@freezed
abstract class NoteRef with _$NoteRef {
  const factory NoteRef({required String id}) = _NoteRef;

  factory NoteRef.fromJson(Map<String, dynamic> json) =>
      _$NoteRefFromJson(json);
}

/// Params for `notes.setPinned`.
@freezed
abstract class NotePin with _$NotePin {
  const factory NotePin({required String id, required bool pinned}) = _NotePin;

  factory NotePin.fromJson(Map<String, dynamic> json) =>
      _$NotePinFromJson(json);
}

/// Params for `notes.generateTitle` and `notes.enhance`: the note as it is
/// in the editor, which may be ahead of what is saved, and the model to
/// ask -- by default the one selected for chats.
@freezed
abstract class NoteAi with _$NoteAi {
  const factory NoteAi({
    @Default(<Map<String, dynamic>>[]) List<Map<String, dynamic>> ops,
    String? model,
  }) = _NoteAi;

  factory NoteAi.fromJson(Map<String, dynamic> json) => _$NoteAiFromJson(json);
}

/// Reply to `notes.generateTitle`.
@freezed
abstract class NoteTitle with _$NoteTitle {
  const factory NoteTitle({required String title}) = _NoteTitle;

  factory NoteTitle.fromJson(Map<String, dynamic> json) =>
      _$NoteTitleFromJson(json);
}

/// Reply to `notes.enhance`: the rewritten body, as Quill ops.
@freezed
abstract class NoteBody with _$NoteBody {
  const factory NoteBody({
    @Default(<Map<String, dynamic>>[]) List<Map<String, dynamic>> ops,
  }) = _NoteBody;

  factory NoteBody.fromJson(Map<String, dynamic> json) =>
      _$NoteBodyFromJson(json);
}

/// Payload of `notes.changed`. [noteId] says which, when it was one.
@freezed
abstract class NotesChanged with _$NotesChanged {
  const factory NotesChanged({String? noteId}) = _NotesChanged;

  factory NotesChanged.fromJson(Map<String, dynamic> json) =>
      _$NotesChangedFromJson(json);
}

/// Reply to `notes.get`. Wrapped, as `chats.get` is: a note deleted
/// elsewhere is null, not an error.
@freezed
abstract class NoteResult with _$NoteResult {
  const factory NoteResult({
    /// Null when there is no such note. Always on the wire, as `null`.
    @JsonKey(includeIfNull: true) NoteDetail? note,
  }) = _NoteResult;

  factory NoteResult.fromJson(Map<String, dynamic> json) =>
      _$NoteResultFromJson(json);
}

/// Reply to `notes.delete`.
@freezed
abstract class DeletedResult with _$DeletedResult {
  const factory DeletedResult({required bool deleted}) = _DeletedResult;

  factory DeletedResult.fromJson(Map<String, dynamic> json) =>
      _$DeletedResultFromJson(json);
}
