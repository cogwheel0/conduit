import 'package:freezed_annotation/freezed_annotation.dart';

part 'memories.freezed.dart';
part 'memories.g.dart';

/// One of the account's memories on its Open WebUI server.
@freezed
abstract class MemoryDto with _$MemoryDto {
  const factory MemoryDto({
    required String id,
    @Default('') String content,

    /// `user` (written by the user) or `context` (learned from chats), as
    /// the server says it; null when the server predates the distinction.
    String? type,

    /// A slash-separated path the server files it under, or null.
    String? path,

    /// When it last changed, in seconds since the epoch.
    @Default(0) int updatedAt,
  }) = _MemoryDto;

  factory MemoryDto.fromJson(Map<String, dynamic> json) =>
      _$MemoryDtoFromJson(json);
}

/// Reply to `memories.list` and every `memories.*` change: the memories,
/// newest first, and whether the account uses them in chats.
@freezed
abstract class MemoryList with _$MemoryList {
  const factory MemoryList({
    /// Memory applies: an Open WebUI account is signed in.
    @Default(false) bool available,

    /// The account's own "Memory" setting (Open WebUI's `ui.memory`).
    @Default(false) bool enabled,
    @Default(<MemoryDto>[]) List<MemoryDto> items,
  }) = _MemoryList;

  factory MemoryList.fromJson(Map<String, dynamic> json) =>
      _$MemoryListFromJson(json);
}

/// Params for `memories.add` (no [id]) and `memories.update` (with one).
/// [type] defaults to `user` for a new memory and is left alone on an
/// edit when null; an empty [path] clears it.
@freezed
abstract class MemoryEdit with _$MemoryEdit {
  const factory MemoryEdit({
    String? id,
    required String content,
    String? type,
    String? path,
  }) = _MemoryEdit;

  factory MemoryEdit.fromJson(Map<String, dynamic> json) =>
      _$MemoryEditFromJson(json);
}

/// Params for `memories.delete`.
@freezed
abstract class MemoryRef with _$MemoryRef {
  const factory MemoryRef({required String id}) = _MemoryRef;

  factory MemoryRef.fromJson(Map<String, dynamic> json) =>
      _$MemoryRefFromJson(json);
}

/// Params for `memories.setEnabled`.
@freezed
abstract class MemoryToggle with _$MemoryToggle {
  const factory MemoryToggle({required bool enabled}) = _MemoryToggle;

  factory MemoryToggle.fromJson(Map<String, dynamic> json) =>
      _$MemoryToggleFromJson(json);
}
