import 'package:freezed_annotation/freezed_annotation.dart';

import 'blocks.dart';
import 'hermes.dart';

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

    /// Another user's chat, reached through a folder shared with this
    /// account: it can be read, and every write to it is refused by the
    /// server, so a window offers no composer, follow-ups, edit, regenerate
    /// or rating (issue #710).
    @Default(false) bool readOnly,

    /// Something arrived since the account last read it, or it was marked
    /// unread (the core's `isConversationUnread`). Never true while the chat
    /// is answering; a window draws no dot on the chat it shows.
    @Default(false) bool unread,

    /// What its menus offer (the sidebar's context menu, the Chat menu), by
    /// the core's rule for the chat's backend: an Open WebUI chat, a
    /// LibreChat one, an on-device Direct one.
    @Default(ChatMenuAbilities()) ChatMenuAbilities menu,
  }) = _ChatSummary;

  factory ChatSummary.fromJson(Map<String, dynamic> json) =>
      _$ChatSummaryFromJson(json);
}

/// What a listed chat's menus offer, from the core's `chatMenuAvailability`
/// (the phone's conversation menu rules), as loaded when it was listed: a
/// permission still loading reads as not allowed, and the list is sent
/// again once it loads. A window leaves out what is false.
@freezed
abstract class ChatMenuAbilities with _$ChatMenuAbilities {
  const factory ChatMenuAbilities({
    /// Share Chat… (a LibreChat chat where its server allows links).
    @Default(false) bool share,

    /// Duplicate Chat (a LibreChat chat, while online).
    @Default(false) bool duplicate,

    /// Move To a folder (an Open WebUI chat, folders on).
    @Default(false) bool move,

    /// Mark as Unread or Read (an Open WebUI chat).
    @Default(false) bool markUnread,

    /// Generate Title (a chat the server holds).
    @Default(false) bool generateTitle,

    /// Export as a JSON backup or a Markdown transcript.
    @Default(false) bool export,
  }) = _ChatMenuAbilities;

  factory ChatMenuAbilities.fromJson(Map<String, dynamic> json) =>
      _$ChatMenuAbilitiesFromJson(json);
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

    /// Owned by another user and shared with this account (issue #710). Its
    /// chats are listed by `chats.folder` only, never by `chats.list`, and
    /// another user's chat in it is [ChatSummary.readOnly].
    @Default(false) bool shared,

    /// The display name of a [shared] folder's owner.
    String? ownerName,

    /// Whether chats may be put in it: always for the account's own folders,
    /// and for a [shared] one only with a write grant.
    @Default(true) bool canWrite,

    /// Its icon as the sidebar draws it (an emoji), from the folder's
    /// settings; null draws the plain folder.
    String? icon,
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

    /// Whether folders can be made here: an Open WebUI account whose
    /// server has the folders feature on. Without one, `folders.create`
    /// is refused, so the sidebar does not offer New Folder.
    @Default(true) bool foldersEnabled,
  }) = _ChatList;

  factory ChatList.fromJson(Map<String, dynamic> json) =>
      _$ChatListFromJson(json);
}

/// One message, flattened for rendering.
///
/// An assistant message carries its [blocks], parsed once in the daemon:
/// the renderer draws those and keeps [content] for copying and search.
@freezed
abstract class ChatMessageDto with _$ChatMessageDto {
  const factory ChatMessageDto({
    required String id,
    required String role,
    required String content,
    required int timestampMs,
    String? model,

    /// The name [model] went by when it answered, as the stored answer keeps
    /// it (the core's `modelName`): what the header shows when [model] is
    /// not among the models on offer, as a Hermes answer's agent id after a
    /// confirmed model switch. Null when the answer kept none.
    String? modelName,

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

    /// An assistant message, ready to draw: files, status, content,
    /// error, code executions, sources and follow-ups, in the order
    /// [MessageBlockKind] gives. Empty for the user's messages.
    @Default(<MessageBlockDto>[]) List<MessageBlockDto> blocks,

    /// The message this one answers or follows; null for the first.
    String? parentId,

    /// The model column (Open WebUI's `modelIdx`) of an answer whose
    /// question more than one model answered (Compare Models); null for an
    /// ordinary answer.
    int? slot,

    /// The merged response saved on this answer (Merge Responses), when it
    /// has one.
    String? merged,

    /// The answer failed on the reasoning effort the chat or the picker sent
    /// it, and a retry without one would go out differently (the core's
    /// `isReasoningEffortRejection`): Retry Without Reasoning Effort applies.
    @Default(false) bool retryWithoutEffort,

    /// When the question was answered by more than one model: each column,
    /// in order, with its answers (this message and its [versions] by id).
    /// Empty for an ordinary answer, whose versions are regenerations.
    @Default(<ComparisonSlotDto>[]) List<ComparisonSlotDto> comparison,

    /// Of [comparison]'s answers, those a merge may read: finished, without
    /// an error, with text. The current answer of each column, as the core
    /// picks them.
    @Default(<String>[]) List<String> mergeableIds,

    /// This message and its [versions], by id, in the order the server keeps
    /// them (its parent's `childrenIds`), so a window shows where the one on
    /// screen stands (`2 / 3`) whichever is current. Empty when it has no
    /// versions.
    @Default(<String>[]) List<String> siblingIds,

    /// An assistant answer whose request is waiting to go out: sent while
    /// offline, or retried after failing. Null once it has gone (or for
    /// any other message).
    QueuedCompletionDto? queued,

    /// A question the server holds until a reply still running in the chat
    /// ends, and answers then (Open WebUI 0.13.4). False for any other
    /// message.
    @Default(false) bool held,
  }) = _ChatMessageDto;

  factory ChatMessageDto.fromJson(Map<String, dynamic> json) =>
      _$ChatMessageDtoFromJson(json);
}

/// One model's column of a Compare Models answer.
@freezed
abstract class ComparisonSlotDto with _$ComparisonSlotDto {
  const factory ComparisonSlotDto({
    /// Open WebUI's `modelIdx`.
    required int index,

    /// The column's answers, oldest first: regenerating one column adds to
    /// its own. The last is the one it shows.
    @Default(<String>[]) List<String> answerIds,

    /// The model that answered, by id.
    String? model,
  }) = _ComparisonSlotDto;

  factory ComparisonSlotDto.fromJson(Map<String, dynamic> json) =>
      _$ComparisonSlotDtoFromJson(json);
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

    /// What an inline citation reads: the source's site, shortened as the
    /// mobile app shortens it. Absent from older daemons; hosts then use
    /// the number.
    String? inlineLabel,

    /// What an inline citation reads with "show citation titles" on: the
    /// source's own title where it has one, else [inlineLabel].
    String? inlineTitle,

    /// The kind of source Open WebUI recorded (`file`, `collection`, …),
    /// shown where there is no address.
    String? type,
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

    /// The context window of the model that answered, in tokens, when the
    /// model says (or one is set for a Direct model).
    int? contextLength,

    /// How much of that window the reply used (the core's
    /// `UsageSummary.contextTokens`).
    int? contextTokens,

    /// Some steps of the reply (a tool round, say) reported no usage, so
    /// the figures may be low.
    @Default(false) bool incomplete,
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

    /// Its model's name when it answered, as [ChatMessageDto.modelName].
    String? modelName,

    /// This version's own sources; a regenerated answer searches again.
    @Default(<ChatSourceDto>[]) List<ChatSourceDto> sources,
    ChatUsageDto? usage,

    /// This answer, ready to draw, as [ChatMessageDto.blocks]. A version
    /// keeps no status timeline.
    @Default(<MessageBlockDto>[]) List<MessageBlockDto> blocks,

    /// Its model column, as [ChatMessageDto.slot].
    int? slot,

    /// Its saved merged response, as [ChatMessageDto.merged].
    String? merged,

    /// The server still reports it as being written (another column of a
    /// comparison that is still answering).
    @Default(false) bool streaming,

    /// Set when this answer failed.
    String? errorCode,
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

    /// As [ChatSummary.readOnly], decided from the whole conversation as it
    /// was opened (its owner is known once the server's copy is loaded,
    /// before it is ever listed).
    @Default(false) bool readOnly,

    /// What this chat offers, as the core decides it for a phone.
    @Default(ChatAbilities()) ChatAbilities abilities,

    /// A temporary chat: never stored, until Save Chat makes it a normal one.
    @Default(false) bool temporary,

    /// The public link's share id, when the chat has one.
    String? shareId,

    /// Open WebUI's task checklist for this chat, in order; empty when it
    /// has none. A running turn sends newer ones with `turn.blocks`.
    @Default(<ChatTaskDto>[]) List<ChatTaskDto> tasks,

    /// A Hermes session's chat (`local:hermes_<session>`): its session, and
    /// whether this app may continue it.
    HermesChatDto? hermes,
  }) = _ChatDetail;

  factory ChatDetail.fromJson(Map<String, dynamic> json) =>
      _$ChatDetailFromJson(json);
}

/// What one open chat offers right now, from the core's own rules (the
/// account, the server's permissions, the backend). A window hides what is
/// false rather than offering something the daemon would refuse.
@freezed
abstract class ChatAbilities with _$ChatAbilities {
  const factory ChatAbilities({
    /// Fork Chat: a new chat from a message (Open WebUI's fork, which needs
    /// the account's `chat.import`).
    @Default(false) bool fork,

    /// Export: a JSON backup or a Markdown transcript (`chat.export`).
    @Default(false) bool export,

    /// Merge Responses on a Compare Models answer (Advanced is on).
    @Default(false) bool merge,

    /// Switching versions and branches on the server, and Continue from
    /// This Response: the account's own stored Open WebUI chat.
    @Default(false) bool branch,

    /// Deleting messages.
    @Default(false) bool deleteMessages,

    /// Mark as Unread (the server keeps read state).
    @Default(false) bool markUnread,

    /// Generate Title (the server holds the chat).
    @Default(false) bool generateTitle,

    /// Share: a public link and who may open it.
    @Default(false) bool share,

    /// Save Chat: a temporary chat with messages, which can become a
    /// normal one.
    @Default(false) bool saveTemporary,

    /// Compare Models: one question to two models side by side (Advanced is
    /// on, a stored Open WebUI chat).
    @Default(false) bool compare,

    /// Branch from Here on a reply of a Hermes chat this app may continue:
    /// a new session with the chat up to that reply (`hermes.history.branch`).
    @Default(false) bool branchFromHere,

    /// Undo Last Turn on a Hermes chat's last reply: a Desktop Gateway
    /// session, whose transcript the gateway keeps (`hermes.history.undo`).
    @Default(false) bool undoLastTurn,

    /// A Hermes agent works in this chat: its subagents, processes and plan
    /// can be watched (`hermes.work.watch`).
    @Default(false) bool hermesWork,

    /// Context & Usage: the chat is a Hermes session whose context window
    /// and usage can be read (`hermes.context.get`).
    @Default(false) bool hermesContext,
  }) = _ChatAbilities;

  factory ChatAbilities.fromJson(Map<String, dynamic> json) =>
      _$ChatAbilitiesFromJson(json);
}

/// What a queued answer is waiting for.
@freezed
abstract class QueuedCompletionDto with _$QueuedCompletionDto {
  const factory QueuedCompletionDto({
    /// It stopped retrying: only Retry (or Remove) moves it on.
    @Default(false) bool failed,

    /// It waits for the connection to come back, and goes out on its own
    /// then.
    @Default(false) bool offline,

    /// The last failure, in the server's or the core's words.
    String? error,

    /// The provider refused the reasoning effort it was sent with: Retry
    /// Without Reasoning Effort is offered.
    @Default(false) bool reasoningEffortRejected,
  }) = _QueuedCompletionDto;

  factory QueuedCompletionDto.fromJson(Map<String, dynamic> json) =>
      _$QueuedCompletionDtoFromJson(json);
}

/// One item of Open WebUI's task checklist.
@freezed
abstract class ChatTaskDto with _$ChatTaskDto {
  const factory ChatTaskDto({
    @Default('') String id,
    required String content,

    /// `pending`, `in_progress`, `completed` or `cancelled`.
    @Default('pending') String status,
  }) = _ChatTaskDto;

  factory ChatTaskDto.fromJson(Map<String, dynamic> json) =>
      _$ChatTaskDtoFromJson(json);
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

    /// The message the window shows in [messageId]'s place (Continue from
    /// This Response, a version's arrows): [messageId] must then be another
    /// answer to the same message in the same role, or nothing changes.
    String? alternativeTo,
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

/// One of the icons a folder may take.
@freezed
abstract class FolderIconChoice with _$FolderIconChoice {
  const factory FolderIconChoice({
    /// The shortcode alias the folder saves.
    required String alias,

    /// What it draws as.
    required String emoji,
  }) = _FolderIconChoice;

  factory FolderIconChoice.fromJson(Map<String, dynamic> json) =>
      _$FolderIconChoiceFromJson(json);
}

/// A model a folder may start its chats on.
@freezed
abstract class FolderModelChoice with _$FolderModelChoice {
  const factory FolderModelChoice({required String id, required String name}) =
      _FolderModelChoice;

  factory FolderModelChoice.fromJson(Map<String, dynamic> json) =>
      _$FolderModelChoiceFromJson(json);
}

/// One item of a folder's project knowledge.
@freezed
abstract class FolderKnowledgeItem with _$FolderKnowledgeItem {
  const factory FolderKnowledgeItem({
    /// `collection`, `file` or `note`.
    @Default('file') String type,
    required String id,
    @Default('') String name,

    /// The server says the file is gone.
    @Default(false) bool missing,
  }) = _FolderKnowledgeItem;

  factory FolderKnowledgeItem.fromJson(Map<String, dynamic> json) =>
      _$FolderKnowledgeItemFromJson(json);
}

/// Reply to `folders.get` and `folders.update`: a folder's settings, as
/// its page and settings sheet edit them.
@freezed
abstract class FolderSettings with _$FolderSettings {
  const factory FolderSettings({
    required String id,
    required String name,
    String? icon,

    /// Applied by the server to every chat in the folder.
    @Default('') String systemPrompt,

    /// The models new chats in the folder start on, in slot order.
    @Default(<String>[]) List<String> modelIds,

    /// Knowledge applied to every chat in the folder.
    @Default(<FolderKnowledgeItem>[]) List<FolderKnowledgeItem> knowledge,

    /// Owned by another user and shared with this account.
    @Default(false) bool shared,
    String? ownerName,

    /// The name and icon may be changed (the account owns the folder).
    @Default(false) bool canRename,

    /// The system prompt, models and knowledge may be changed (the owner, or
    /// a write grant).
    @Default(false) bool canWrite,

    /// The system prompt may be changed too (a write grant, and the
    /// account's chat permissions allow system prompts).
    @Default(false) bool canEditSystemPrompt,

    /// Its access may be changed (Share Folder).
    @Default(false) bool canShare,

    /// The icons to choose from.
    @Default(<FolderIconChoice>[]) List<FolderIconChoice> iconChoices,

    /// The models a folder may start its chats on: the server's own, not
    /// this computer's Direct or Hermes ones.
    @Default(<FolderModelChoice>[]) List<FolderModelChoice> modelChoices,
  }) = _FolderSettings;

  factory FolderSettings.fromJson(Map<String, dynamic> json) =>
      _$FolderSettingsFromJson(json);
}

/// Params for `folders.update`: what changed; a null field stays as it is.
@freezed
abstract class FolderUpdate with _$FolderUpdate {
  const factory FolderUpdate({
    required String id,
    String? name,

    /// An empty alias clears the icon.
    String? icon,
    String? systemPrompt,
    List<String>? modelIds,
    List<FolderKnowledgeItem>? knowledge,
  }) = _FolderUpdate;

  factory FolderUpdate.fromJson(Map<String, dynamic> json) =>
      _$FolderUpdateFromJson(json);
}

/// Reply to `folders.draftModel`: what a new chat in the folder starts on.
@freezed
abstract class FolderDraftModel with _$FolderDraftModel {
  const factory FolderDraftModel({
    required String folderId,

    /// The folder's default models this server offers, in slot order; the
    /// first is the new chat's. Empty: the account's own default applies.
    @Default(<String>[]) List<String> modelIds,

    /// The folder saved models, but the server offers none of them.
    @Default(false) bool missing,
  }) = _FolderDraftModel;

  factory FolderDraftModel.fromJson(Map<String, dynamic> json) =>
      _$FolderDraftModelFromJson(json);
}

/// Reply to `chats.folder`: every conversation in a folder, newest first.
///
/// All of them, rather than the part of the sidebar's list that happens to
/// be loaded: a folder page that stops at the sidebar's page size would
/// look complete and not be. The account's own chats come from the local
/// database; other users' chats in a folder shared with the account, or
/// written into one of its own by a user with a write grant, come from the
/// server, as a phone lists them, and are [ChatSummary.readOnly].
@freezed
abstract class FolderContents with _$FolderContents {
  const factory FolderContents({
    required FolderSummary folder,
    @Default(<ChatSummary>[]) List<ChatSummary> chats,
  }) = _FolderContents;

  factory FolderContents.fromJson(Map<String, dynamic> json) =>
      _$FolderContentsFromJson(json);
}

/// Params for `folders.create`.
@freezed
abstract class CreateFolder with _$CreateFolder {
  const factory CreateFolder({
    required String name,

    /// The folder it goes in, or null for the top level. Another user's
    /// folder takes one only with a write grant
    /// ([FolderSummary.canWrite]).
    String? parentId,
  }) = _CreateFolder;

  factory CreateFolder.fromJson(Map<String, dynamic> json) =>
      _$CreateFolderFromJson(json);
}

/// Reply to `folders.create`: the folder as the server made it, and the
/// list afterwards (which holds it).
@freezed
abstract class FolderCreated with _$FolderCreated {
  const factory FolderCreated({
    required FolderSummary folder,
    required ChatList list,
  }) = _FolderCreated;

  factory FolderCreated.fromJson(Map<String, dynamic> json) =>
      _$FolderCreatedFromJson(json);
}

/// Params for `folders.rename`.
@freezed
abstract class RenameFolder with _$RenameFolder {
  const factory RenameFolder({required String id, required String name}) =
      _RenameFolder;

  factory RenameFolder.fromJson(Map<String, dynamic> json) =>
      _$RenameFolderFromJson(json);
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

/// Who may open a chat's link, beyond the people and groups given access:
/// nobody else, every user on the server, or anyone with the link (the
/// core's `ResourceAudience`).
enum ShareAudience { private, public, open }

/// Params for `chats.share`.
@freezed
abstract class ShareChat with _$ShareChat {
  const factory ShareChat({
    required String id,

    /// Makes the link, or updates it to the chat as it is now. False only
    /// reads what the chat has (and sets [audience], when given).
    @Default(true) bool publish,

    /// Who may open it, chosen on purpose; null leaves it as it is.
    ShareAudience? audience,
  }) = _ShareChat;

  factory ShareChat.fromJson(Map<String, dynamic> json) =>
      _$ShareChatFromJson(json);
}

/// Reply to `chats.share` and `chats.unshare`.
@freezed
abstract class ChatShare with _$ChatShare {
  const factory ChatShare({
    required String chatId,

    /// The share id, or null once unshared.
    String? shareId,

    /// The link to copy, built by the core from the account's server (Open
    /// WebUI serves it at `/s/{shareId}`); null without a link.
    String? url,

    /// Who may open it, when the server said.
    ShareAudience? audience,
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

/// Reply to `chats.get`, `chats.setSystemPrompt` and `chats.setCurrent`.
///
/// Wrapped so the absence travels as data rather than as an error: opening
/// a chat that was deleted on another device is ordinary.
@freezed
abstract class ChatResult with _$ChatResult {
  const factory ChatResult({
    /// Null when there is no such chat. Always on the wire, as `null`.
    @JsonKey(includeIfNull: true) ChatDetail? chat,
  }) = _ChatResult;

  factory ChatResult.fromJson(Map<String, dynamic> json) =>
      _$ChatResultFromJson(json);
}

/// Params for `chats.fork`: a new chat from the start of [chatId] to
/// [messageId], as Open WebUI's fork makes it.
@freezed
abstract class ForkChat with _$ForkChat {
  const factory ForkChat({required String chatId, required String messageId}) =
      _ForkChat;

  factory ForkChat.fromJson(Map<String, dynamic> json) =>
      _$ForkChatFromJson(json);
}

/// Reply to `chats.fork` and `chats.saveTemporary`: the new chat.
@freezed
abstract class ChatForked with _$ChatForked {
  const factory ChatForked({required String chatId}) = _ChatForked;

  factory ChatForked.fromJson(Map<String, dynamic> json) =>
      _$ChatForkedFromJson(json);
}

/// What `chats.export` writes.
enum ChatExportFormat {
  /// The whole chat, every branch, as the JSON Open WebUI imports.
  json,

  /// The branch the transcript shows, as readable Markdown.
  markdown,
}

/// Params for `chats.export`.
@freezed
abstract class ExportChat with _$ExportChat {
  const factory ExportChat({
    required String chatId,
    required ChatExportFormat format,
  }) = _ExportChat;

  factory ExportChat.fromJson(Map<String, dynamic> json) =>
      _$ExportChatFromJson(json);
}

/// Reply to `chats.export`: the file to save, read from the chat's stored
/// copy. The window asks where to save it.
@freezed
abstract class ChatExportFile with _$ChatExportFile {
  const factory ChatExportFile({
    /// The name the save panel suggests: the title, then a stamp.
    required String fileName,
    required String content,
    required String mimeType,

    /// Edits made here that have not reached the server yet are in it.
    @Default(false) bool hasUnsyncedChanges,
  }) = _ChatExportFile;

  factory ChatExportFile.fromJson(Map<String, dynamic> json) =>
      _$ChatExportFileFromJson(json);
}

/// How `chats.generateTitle` ended.
enum GenerateTitleOutcome {
  /// A new title was saved.
  saved,

  /// The model wrote the title the chat already had.
  unchanged,

  /// The model wrote no title.
  none,
}

/// Reply to `chats.generateTitle`.
@freezed
abstract class GeneratedTitle with _$GeneratedTitle {
  const factory GeneratedTitle({
    required GenerateTitleOutcome outcome,
    String? title,
  }) = _GeneratedTitle;

  factory GeneratedTitle.fromJson(Map<String, dynamic> json) =>
      _$GeneratedTitleFromJson(json);
}

/// Params for `chats.markUnread`.
@freezed
abstract class MarkUnread with _$MarkUnread {
  const factory MarkUnread({
    required String chatId,

    /// False marks it read, as opening it does.
    @Default(true) bool unread,
  }) = _MarkUnread;

  factory MarkUnread.fromJson(Map<String, dynamic> json) =>
      _$MarkUnreadFromJson(json);
}

/// A view of a window that shows one chat at a time.
enum ChatView {
  /// The main window's chat pane.
  main,

  /// The Quick Ask panel.
  quickAsk,
}

/// Params for `chats.setShown`: the chat [view] shows on screen now, or
/// none (a new chat, another area's item, a hidden window).
@freezed
abstract class ShownChat with _$ShownChat {
  const factory ShownChat({required ChatView view, String? chatId}) =
      _ShownChat;

  factory ShownChat.fromJson(Map<String, dynamic> json) =>
      _$ShownChatFromJson(json);
}
