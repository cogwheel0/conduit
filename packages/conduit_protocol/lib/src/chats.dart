import 'package:freezed_annotation/freezed_annotation.dart';

part 'chats.freezed.dart';
part 'chats.g.dart';

/// A conversation as the sidebar shows it.
///
/// Deliberately without messages. The sidebar renders hundreds of these and
/// needs none of the transcript; sending it would make opening the app
/// proportional to total history rather than to what is on screen.
@freezed
abstract class ChatSummary with _$ChatSummary {
  const factory ChatSummary({
    required String id,
    required String title,
    required int updatedAtMs,
    @Default(false) bool pinned,
    @Default(false) bool archived,
    String? folderId,
    String? model,
    @Default(<String>[]) List<String> tags,

    /// Whether this chat has a public share link.
    @Default(false) bool shared,
  }) = _ChatSummary;

  factory ChatSummary.fromJson(Map<String, dynamic> json) =>
      _$ChatSummaryFromJson(json);
}

/// Reply to `chats.list`.
@freezed
abstract class ChatList with _$ChatList {
  const factory ChatList({
    @Default(<ChatSummary>[]) List<ChatSummary> chats,

    /// Whether `chats.loadMore` would return anything.
    @Default(false) bool hasMore,

    /// Archived chats are counted even when they are not loaded, so the
    /// sidebar can offer the section without paging them in first.
    @Default(0) int archivedCount,
  }) = _ChatList;

  factory ChatList.fromJson(Map<String, dynamic> json) =>
      _$ChatListFromJson(json);
}

/// One message, flattened for rendering.
///
/// The parsed segments the plan calls `turn.blocks` are a later addition;
/// this carries the raw markdown plus the fields the renderer needs to show
/// a message at all. The parsing still happens once, in the daemon -- it is
/// simply not yet split out of [content].
@freezed
abstract class ChatMessageDto with _$ChatMessageDto {
  const factory ChatMessageDto({
    required String id,
    required String role,
    required String content,
    required int timestampMs,
    String? model,

    /// True while the daemon is still appending to [content].
    @Default(false) bool streaming,

    /// Set when the turn failed; localized in the UI like every other code.
    String? errorCode,
  }) = _ChatMessageDto;

  factory ChatMessageDto.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageDtoFromJson(json);
}

/// Reply to `chats.get`: one conversation with its transcript.
@freezed
abstract class ChatDetail with _$ChatDetail {
  const factory ChatDetail({
    required ChatSummary summary,
    @Default(<ChatMessageDto>[]) List<ChatMessageDto> messages,
  }) = _ChatDetail;

  factory ChatDetail.fromJson(Map<String, dynamic> json) =>
      _$ChatDetailFromJson(json);
}

/// Params for methods addressing one chat.
@freezed
abstract class ChatRef with _$ChatRef {
  const factory ChatRef({required String id}) = _ChatRef;

  factory ChatRef.fromJson(Map<String, dynamic> json) =>
      _$ChatRefFromJson(json);
}

/// Params for `chats.search`.
@freezed
abstract class ChatSearchQuery with _$ChatSearchQuery {
  const factory ChatSearchQuery({
    required String query,
    @Default(50) int limit,
  }) = _ChatSearchQuery;

  factory ChatSearchQuery.fromJson(Map<String, dynamic> json) =>
      _$ChatSearchQueryFromJson(json);
}

/// One search hit: the chat, and where the match was.
@freezed
abstract class ChatSearchHit with _$ChatSearchHit {
  const factory ChatSearchHit({
    required String chatId,
    required String title,

    /// The matching text with the query in context, as the database's
    /// full-text index produced it -- not re-derived in the UI, which would
    /// have to reimplement the tokenizer to agree with it.
    String? snippet,
    required int updatedAtMs,
  }) = _ChatSearchHit;

  factory ChatSearchHit.fromJson(Map<String, dynamic> json) =>
      _$ChatSearchHitFromJson(json);
}

/// Reply to `chats.search`.
@freezed
abstract class ChatSearchResults with _$ChatSearchResults {
  const factory ChatSearchResults({
    @Default(<ChatSearchHit>[]) List<ChatSearchHit> hits,
  }) = _ChatSearchResults;

  factory ChatSearchResults.fromJson(Map<String, dynamic> json) =>
      _$ChatSearchResultsFromJson(json);
}
