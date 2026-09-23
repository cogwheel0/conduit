import 'package:freezed_annotation/freezed_annotation.dart';

part 'notes.freezed.dart';
part 'notes.g.dart';

/// A note, as the list shows it (M5).
@freezed
abstract class NoteSummary with _$NoteSummary {
  const factory NoteSummary({
    required String id,
    required String title,
    required int updatedAtMs,
    @Default(false) bool pinned,

    /// The start of the note's text, for the list; markdown.
    @Default('') String preview,
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
    @Default(<Map<String, dynamic>>[]) List<Map<String, dynamic>> ops,
  }) = _NoteDetail;

  factory NoteDetail.fromJson(Map<String, dynamic> json) =>
      _$NoteDetailFromJson(json);
}

/// Params for `notes.save`: a new note when [id] is null.
///
/// [ops] null leaves the body alone (a rename); otherwise it replaces it.
@freezed
abstract class NoteSave with _$NoteSave {
  const factory NoteSave({
    String? id,
    required String title,
    List<Map<String, dynamic>>? ops,
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
