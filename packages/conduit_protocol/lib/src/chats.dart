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

/// A folder as the sidebar shows it.
///
/// No member list: a chat names its folder through
/// [ChatSummary.folderId], and carrying the relation both ways would give
/// the renderer two answers to disagree about.
@freezed
abstract class FolderSummary with _$FolderSummary {
  const factory FolderSummary({
    required String id,
    required String name,

    /// Folders nest. Null is the top level.
    String? parentId,

    /// Whether the account last left it open, which is where a new window
    /// should start.
    @Default(false) bool expanded,
  }) = _FolderSummary;

  factory FolderSummary.fromJson(Map<String, dynamic> json) =>
      _$FolderSummaryFromJson(json);
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

    /// Whether archived chats are currently included in [chats].
    ///
    /// They are paged separately and off by default: most people never
    /// open the section, and loading it for everyone would make the list
    /// proportional to everything ever archived.
    @Default(false) bool archivedVisible,

    @Default(<FolderSummary>[]) List<FolderSummary> folders,
  }) = _ChatList;

  factory ChatList.fromJson(Map<String, dynamic> json) =>
      _$ChatListFromJson(json);
}

/// One message, flattened for rendering.
///
/// The parsed segments (`turn.blocks`) come separately;
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

    /// Other answers to the same prompt, oldest first.
    ///
    /// A regenerate creates a sibling on the server instead of replacing
    /// the answer. Without these, the answer that was regenerated away
    /// could not be reached from this app at all.
    @Default(<ChatMessageVersionDto>[]) List<ChatMessageVersionDto> versions,

    /// What the answer drew on -- web results, files, a knowledge base --
    /// in the order its `[1]`, `[2]` markers count.
    @Default(<ChatSourceDto>[]) List<ChatSourceDto> sources,

    /// Tokens and timing, when the provider reported them.
    ChatUsageDto? usage,

    /// The user's thumb: 1 up, -1 down, null unrated.
    int? rating,

    /// What was attached to a question, or generated with an answer.
    @Default(<ChatFileDto>[]) List<ChatFileDto> files,
  }) = _ChatMessageDto;

  factory ChatMessageDto.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageDtoFromJson(json);
}

/// One source an answer cites.
///
/// Already reduced to what the renderer shows: Open WebUI's source records
/// are nested several ways depending on where they came from, and deciding
/// which field is the name happens once, in the core, for both apps.
@freezed
abstract class ChatSourceDto with _$ChatSourceDto {
  const factory ChatSourceDto({
    required String label,

    /// Only when there is a real http(s) address to open.
    String? url,
    String? snippet,
  }) = _ChatSourceDto;

  factory ChatSourceDto.fromJson(Map<String, dynamic> json) =>
      _$ChatSourceDtoFromJson(json);
}

/// A file on a message.
///
/// By id: the renderer loads it from the daemon's `/files/{server}/{id}`,
/// which proxies it with the server's credentials, so the window never
/// holds one. [dataUrl] is only for old conversations whose images were
/// stored inline; a remote URL is deliberately not carried, because an
/// image fetched from anywhere is a tracking pixel.
@freezed
abstract class ChatFileDto with _$ChatFileDto {
  const factory ChatFileDto({
    String? id,
    required String name,
    @Default(false) bool image,
    String? contentType,
    String? dataUrl,
  }) = _ChatFileDto;

  factory ChatFileDto.fromJson(Map<String, dynamic> json) =>
      _$ChatFileDtoFromJson(json);
}

/// How an answer was produced, in the figures people read.
///
/// Computed by the core's `UsageSummary` from whichever of the four shapes
/// the provider used, so a field is null when that provider did not say --
/// never zero.
@freezed
abstract class ChatUsageDto with _$ChatUsageDto {
  const factory ChatUsageDto({
    double? generationPerSecond,
    int? generationTokens,
    double? promptPerSecond,
    int? promptTokens,
    int? reasoningTokens,
    int? totalTokens,
    double? totalSeconds,
    double? queueSeconds,
    double? loadSeconds,
  }) = _ChatUsageDto;

  factory ChatUsageDto.fromJson(Map<String, dynamic> json) =>
      _$ChatUsageDtoFromJson(json);
}

/// One alternative answer to the prompt a message answers.
@freezed
abstract class ChatMessageVersionDto with _$ChatMessageVersionDto {
  const factory ChatMessageVersionDto({
    required String id,
    required String content,
    required int timestampMs,
    String? model,

    /// This version's own sources; a regenerated answer searches again.
    @Default(<ChatSourceDto>[]) List<ChatSourceDto> sources,
    ChatUsageDto? usage,
  }) = _ChatMessageVersionDto;

  factory ChatMessageVersionDto.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageVersionDtoFromJson(json);
}

/// Reply to `chats.get`: one conversation with its transcript.
@freezed
abstract class ChatDetail with _$ChatDetail {
  const factory ChatDetail({
    required ChatSummary summary,
    @Default(<ChatMessageDto>[]) List<ChatMessageDto> messages,

    /// The conversation's own system prompt, when it has one.
    /// Null means turns use the account's default from its settings.
    String? systemPrompt,
  }) = _ChatDetail;

  factory ChatDetail.fromJson(Map<String, dynamic> json) =>
      _$ChatDetailFromJson(json);
}

/// One message in a conversation's tree, for the overview.
@freezed
abstract class ChatTreeNode with _$ChatTreeNode {
  const factory ChatTreeNode({
    required String id,
    String? parentId,
    required String role,

    /// The start of the message, on one line.
    required String preview,
    required int timestampMs,
    String? model,
  }) = _ChatTreeNode;

  factory ChatTreeNode.fromJson(Map<String, dynamic> json) =>
      _$ChatTreeNodeFromJson(json);
}

/// Reply to `chats.tree`: every message, on every branch.
///
/// The transcript shows one path through this; the rest are edits and
/// regenerations the user moved away from, which only the overview reaches.
@freezed
abstract class ChatTree with _$ChatTree {
  const factory ChatTree({
    required String chatId,
    @Default(<ChatTreeNode>[]) List<ChatTreeNode> nodes,

    /// The last message of the path the transcript shows.
    String? currentId,
  }) = _ChatTree;

  factory ChatTree.fromJson(Map<String, dynamic> json) =>
      _$ChatTreeFromJson(json);
}

/// Params for `chats.setCurrent`: show the branch through [messageId].
@freezed
abstract class ChatCurrent with _$ChatCurrent {
  const factory ChatCurrent({
    required String chatId,
    required String messageId,
  }) = _ChatCurrent;

  factory ChatCurrent.fromJson(Map<String, dynamic> json) =>
      _$ChatCurrentFromJson(json);
}

/// Params for `chats.folder`.
@freezed
abstract class FolderRef with _$FolderRef {
  const factory FolderRef({required String folderId}) = _FolderRef;

  factory FolderRef.fromJson(Map<String, dynamic> json) =>
      _$FolderRefFromJson(json);
}

/// Reply to `chats.folder`: every conversation in a folder, newest first.
///
/// All of them, from the local database, rather than the part of the
/// sidebar's list that happens to be loaded: a folder page that stops at
/// the sidebar's page size would look complete and not be.
@freezed
abstract class FolderContents with _$FolderContents {
  const factory FolderContents({
    required FolderSummary folder,
    @Default(<ChatSummary>[]) List<ChatSummary> chats,
  }) = _FolderContents;

  factory FolderContents.fromJson(Map<String, dynamic> json) =>
      _$FolderContentsFromJson(json);
}

/// Params for `chats.setSystemPrompt`.
@freezed
abstract class ChatSystemPrompt with _$ChatSystemPrompt {
  const factory ChatSystemPrompt({
    required String chatId,

    /// Empty clears it, and turns fall back to the account's default.
    required String prompt,
  }) = _ChatSystemPrompt;

  factory ChatSystemPrompt.fromJson(Map<String, dynamic> json) =>
      _$ChatSystemPromptFromJson(json);
}

/// A tag, as Open WebUI keeps it.
///
/// [id] is what a chat's `tags` lists -- the name lower-cased, spaces as
/// underscores -- and [name] is what the user typed.
@freezed
abstract class TagDto with _$TagDto {
  const factory TagDto({required String id, required String name}) = _TagDto;

  factory TagDto.fromJson(Map<String, dynamic> json) => _$TagDtoFromJson(json);
}

/// Reply to `chats.tags.all`, and to adding or removing one: the tags in
/// question, by name.
@freezed
abstract class TagList with _$TagList {
  const factory TagList({@Default(<TagDto>[]) List<TagDto> tags}) = _TagList;

  factory TagList.fromJson(Map<String, dynamic> json) =>
      _$TagListFromJson(json);
}

/// What `chats.bulk` does to every conversation it is given.
enum BulkChatAction { archive, unarchive, delete, move }

/// Params for `chats.bulk`.
@freezed
abstract class BulkChats with _$BulkChats {
  const factory BulkChats({
    required List<String> chatIds,
    required BulkChatAction action,

    /// For [BulkChatAction.move]: the folder, or null for none.
    String? folderId,
  }) = _BulkChats;

  factory BulkChats.fromJson(Map<String, dynamic> json) =>
      _$BulkChatsFromJson(json);
}

/// Reply to `chats.bulk`: the list afterwards, and which ones failed.
///
/// Partial success is the normal case to design for. Twenty deletes where
/// one conversation was already gone should delete nineteen and say so,
/// not roll back or stop at the first.
@freezed
abstract class BulkChatsResult with _$BulkChatsResult {
  const factory BulkChatsResult({
    required ChatList list,
    @Default(<String>[]) List<String> failed,
  }) = _BulkChatsResult;

  factory BulkChatsResult.fromJson(Map<String, dynamic> json) =>
      _$BulkChatsResultFromJson(json);
}

/// Params for `chats.move`: into a folder, or out of all of them.
@freezed
abstract class MoveChat with _$MoveChat {
  const factory MoveChat({
    required String chatId,

    /// Null takes it out of any folder.
    String? folderId,
  }) = _MoveChat;

  factory MoveChat.fromJson(Map<String, dynamic> json) =>
      _$MoveChatFromJson(json);
}

/// Params for `chats.tags.add` and `chats.tags.remove`.
@freezed
abstract class ChatTagEdit with _$ChatTagEdit {
  const factory ChatTagEdit({required String chatId, required String name}) =
      _ChatTagEdit;

  factory ChatTagEdit.fromJson(Map<String, dynamic> json) =>
      _$ChatTagEditFromJson(json);
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

    /// False while the local index may be missing conversations: before
    /// the first full sync has finished, or while one is running.
    ///
    /// Search runs against the database, which is right, but the database
    /// fills over the first minute after sign-in. Without this, a search
    /// in that window answered "Nothing matched" as though that were
    /// settled.
    @Default(true) bool complete,
  }) = _ChatSearchResults;

  factory ChatSearchResults.fromJson(Map<String, dynamic> json) =>
      _$ChatSearchResultsFromJson(json);
}

/// Params for `chats.rename`.
@freezed
abstract class RenameChat with _$RenameChat {
  const factory RenameChat({required String id, required String title}) =
      _RenameChat;

  factory RenameChat.fromJson(Map<String, dynamic> json) =>
      _$RenameChatFromJson(json);
}

/// Params for `chats.setPinned` and `chats.setArchived`.
///
/// One type for both because they are the same shape, and a caller that
/// muddles them gets a compile error at the method name rather than a
/// silently wrong flag.
@freezed
abstract class SetChatFlag with _$SetChatFlag {
  const factory SetChatFlag({required String id, required bool value}) =
      _SetChatFlag;

  factory SetChatFlag.fromJson(Map<String, dynamic> json) =>
      _$SetChatFlagFromJson(json);
}

/// Reply to `chats.share`.
@freezed
abstract class ChatShare with _$ChatShare {
  const factory ChatShare({
    required String chatId,

    /// The share id, or null once unshared. The renderer builds the URL from
    /// the active server rather than receiving one, so a stale link cannot
    /// outlive a server change.
    String? shareId,
  }) = _ChatShare;

  factory ChatShare.fromJson(Map<String, dynamic> json) =>
      _$ChatShareFromJson(json);
}

/// Params for `chats.setArchivedVisible`.
@freezed
abstract class ArchivedVisibility with _$ArchivedVisibility {
  const factory ArchivedVisibility({required bool visible}) =
      _ArchivedVisibility;

  factory ArchivedVisibility.fromJson(Map<String, dynamic> json) =>
      _$ArchivedVisibilityFromJson(json);
}

/// Payload of `chats.changed`.
///
/// Published unscoped, so every window hears it. Every window's sidebar
/// may need to reorder, including windows showing a different chat.
/// [chatId] says whether it is about one conversation. A transcript only
/// refetches for its own chat, or when the change is general (a sync that
/// may have touched anything).
@freezed
abstract class ChatsChanged with _$ChatsChanged {
  const factory ChatsChanged({String? chatId}) = _ChatsChanged;

  factory ChatsChanged.fromJson(Map<String, dynamic> json) =>
      _$ChatsChangedFromJson(json);
}

/// Payload of `route.remap`.
///
/// A chat made on this computer -- a direct-connection chat mirrored to
/// Open WebUI -- starts with a `local:` id and is given the server's on its
/// first sync. A window showing it rewrites its address rather than
/// losing the conversation.
@freezed
abstract class RouteRemap with _$RouteRemap {
  const factory RouteRemap({required String fromId, required String toId}) =
      _RouteRemap;

  factory RouteRemap.fromJson(Map<String, dynamic> json) =>
      _$RouteRemapFromJson(json);
}

/// Payload of `sync.status`.
///
/// Published whenever the sync engine starts or finishes a cycle. The
/// sidebar shows it, and search re-runs on it, because the index fills
/// while a sync runs and a search typed during the first one should pick up
/// what lands.
@freezed
abstract class SyncState with _$SyncState {
  const factory SyncState({
    @Default(false) bool running,

    /// Between 0 and 1 while running, when the engine knows the total.
    double? progress,

    /// Whether a full cycle has ever succeeded. Before the first one, the
    /// local database is known to be missing conversations.
    @Default(false) bool everCompleted,

    /// The last cycle's failure, as the engine reported it.
    String? lastError,

    /// False when this computer has no network at all. Narrow on
    /// purpose: "an interface exists" is all the daemon can know without
    /// asking the server, and a server that will not answer is what
    /// [lastError] is for.
    @Default(true) bool online,
  }) = _SyncState;

  factory SyncState.fromJson(Map<String, dynamic> json) =>
      _$SyncStateFromJson(json);
}
