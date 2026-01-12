// ignore_for_file: invalid_annotation_target

import 'package:freezed_annotation/freezed_annotation.dart';

part 'note.freezed.dart';
part 'note.g.dart';

/// Helper to extract user_id from JSON, falling back to user.id if not present.
/// OpenWebUI's NoteItemResponse (list endpoint) doesn't include user_id directly
/// but does include the user object with an id field.
Object? _readUserId(Map<dynamic, dynamic> json, String key) {
  // First try the direct user_id field
  if (json['user_id'] != null) {
    return json['user_id'];
  }
  // Fall back to extracting from user object
  final user = json['user'];
  if (user is Map && user['id'] != null) {
    return user['id'];
  }
  return null;
}

/// Content structure for a note, supporting multiple formats.
@freezed
sealed class NoteContent with _$NoteContent {
  const factory NoteContent({
    /// Raw JSON content from rich text editor (if any)
    Object? json,

    /// HTML representation
    @Default('') String html,

    /// Markdown representation
    @Default('') String md,
  }) = _NoteContent;

  factory NoteContent.fromJson(Map<String, dynamic> json) =>
      _$NoteContentFromJson(json);
}

/// Data payload for a note, containing content and optional files/versions.
@freezed
sealed class NoteData with _$NoteData {
  const factory NoteData({
    /// The main content of the note
    @Default(NoteContent()) NoteContent content,

    /// Previous versions for undo/history
    @Default([]) List<NoteContent> versions,

    /// Attached files (if any)
    @_FileListConverter() List<Map<String, dynamic>>? files,
  }) = _NoteData;

  factory NoteData.fromJson(Map<String, dynamic> json) =>
      _$NoteDataFromJson(json);
}

/// Converter for files list which can be null or a list of maps.
class _FileListConverter
    implements JsonConverter<List<Map<String, dynamic>>?, Object?> {
  const _FileListConverter();

  @override
  List<Map<String, dynamic>>? fromJson(Object? json) {
    if (json == null) return null;
    if (json is List) {
      return json.whereType<Map<String, dynamic>>().toList();
    }
    return null;
  }

  @override
  Object? toJson(List<Map<String, dynamic>>? object) => object;
}

/// User information associated with a note.
@freezed
sealed class NoteUser with _$NoteUser {
  const factory NoteUser({
    required String id,
    String? name,
    String? email,
    @JsonKey(name: 'profile_image_url') String? profileImageUrl,
  }) = _NoteUser;

  factory NoteUser.fromJson(Map<String, dynamic> json) =>
      _$NoteUserFromJson(json);
}

/// A Note model matching the OpenWebUI notes API structure.
@freezed
sealed class Note with _$Note {
  const Note._();

  const factory Note({
    required String id,

    /// User ID - may be null in list responses (NoteItemResponse)
    /// Can be extracted from user.id if present
    @JsonKey(name: 'user_id', readValue: _readUserId) String? userId,

    required String title,

    /// Note content and associated data
    @_NoteDataConverter() @Default(NoteData()) NoteData data,

    /// Additional metadata
    @_MetadataConverter() Map<String, dynamic>? meta,

    /// Access control settings
    @JsonKey(name: 'access_control')
    @_MetadataConverter()
    Map<String, dynamic>? accessControl,

    /// Creation timestamp in nanoseconds
    @JsonKey(name: 'created_at') required int createdAt,

    /// Last update timestamp in nanoseconds
    @JsonKey(name: 'updated_at') required int updatedAt,

    /// User who created the note (optional, from extended response)
    NoteUser? user,
  }) = _Note;

  factory Note.fromJson(Map<String, dynamic> json) => _$NoteFromJson(json);

  /// Get created date as DateTime
  DateTime get createdDateTime =>
      DateTime.fromMicrosecondsSinceEpoch(createdAt ~/ 1000);

  /// Get updated date as DateTime
  DateTime get updatedDateTime =>
      DateTime.fromMicrosecondsSinceEpoch(updatedAt ~/ 1000);

  /// Get the markdown content of the note
  String get markdownContent => data.content.md;

  /// Get the HTML content of the note
  String get htmlContent => data.content.html;

  /// Check if the note has content
  bool get hasContent =>
      data.content.md.isNotEmpty || data.content.html.isNotEmpty;
}

/// Converter for NoteData that handles both object and null cases.
class _NoteDataConverter implements JsonConverter<NoteData, Object?> {
  const _NoteDataConverter();

  @override
  NoteData fromJson(Object? json) {
    if (json == null) return const NoteData();
    if (json is Map<String, dynamic>) {
      // Handle the nested content structure
      final contentJson = json['content'];
      NoteContent content = const NoteContent();
      if (contentJson is Map<String, dynamic>) {
        content = NoteContent.fromJson(contentJson);
      }

      // Handle versions
      final versionsJson = json['versions'];
      List<NoteContent> versions = [];
      if (versionsJson is List) {
        versions = versionsJson
            .whereType<Map<String, dynamic>>()
            .map((v) => NoteContent.fromJson(v))
            .toList();
      }

      // Handle files
      final filesJson = json['files'];
      List<Map<String, dynamic>>? files;
      if (filesJson is List) {
        files = filesJson.whereType<Map<String, dynamic>>().toList();
      }

      return NoteData(content: content, versions: versions, files: files);
    }
    return const NoteData();
  }

  @override
  Object? toJson(NoteData object) => object.toJson();
}

/// Converter for metadata maps.
class _MetadataConverter
    implements JsonConverter<Map<String, dynamic>?, Object?> {
  const _MetadataConverter();

  @override
  Map<String, dynamic>? fromJson(Object? json) {
    if (json == null) return null;
    if (json is Map<String, dynamic>) return json;
    if (json is Map) {
      return json.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  @override
  Object? toJson(Map<String, dynamic>? object) => object;
}

/// Form data for creating a new note.
@freezed
sealed class NoteForm with _$NoteForm {
  const factory NoteForm({
    required String title,
    NoteData? data,
    Map<String, dynamic>? meta,
    @JsonKey(name: 'access_control') Map<String, dynamic>? accessControl,
  }) = _NoteForm;

  factory NoteForm.fromJson(Map<String, dynamic> json) =>
      _$NoteFormFromJson(json);
}

/// Form data for updating a note.
@freezed
sealed class NoteUpdateForm with _$NoteUpdateForm {
  const factory NoteUpdateForm({
    String? title,
    NoteData? data,
    Map<String, dynamic>? meta,
    @JsonKey(name: 'access_control') Map<String, dynamic>? accessControl,
  }) = _NoteUpdateForm;

  factory NoteUpdateForm.fromJson(Map<String, dynamic> json) =>
      _$NoteUpdateFormFromJson(json);
}
