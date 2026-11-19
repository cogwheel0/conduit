import 'package:freezed_annotation/freezed_annotation.dart';

import 'settings.dart' show QuickPillOption;

part 'composer.freezed.dart';
part 'composer.g.dart';

/// A tool the server offers for a turn.
@freezed
abstract class ToolSummary with _$ToolSummary {
  const factory ToolSummary({
    required String id,
    required String name,
    String? description,
  }) = _ToolSummary;

  factory ToolSummary.fromJson(Map<String, dynamic> json) =>
      _$ToolSummaryFromJson(json);
}

/// What the composer may offer for the next turn.
///
/// Decided by the daemon from the server's permissions and the selected
/// model, the same way the mobile app decides it, so the two front ends
/// offer the same switches for the same account.
@freezed
abstract class ComposerOptions with _$ComposerOptions {
  const factory ComposerOptions({
    @Default(false) bool webSearch,
    @Default(false) bool imageGeneration,
    @Default(<ToolSummary>[]) List<ToolSummary> tools,

    /// The MCP servers the app talks to itself, as tools with the id
    /// `local_mcp:<server id>`. Offered instead of [tools] when the
    /// model is a direct connection's: the server's tools run on the
    /// server, and a direct model never reaches it.
    @Default(<ToolSummary>[]) List<ToolSummary> mcpTools,

    /// Open WebUI's toggle filters (the server's `toggle` functions), as
    /// mobile's + panel lists them under Filters.
    @Default(<ToolSummary>[]) List<ToolSummary> filters,

    /// The [filters] the selected model turns on by itself (the core's
    /// `defaultFilterIdsForModel`): where a new message's filters start.
    @Default(<String>[]) List<String> filterDefaults,

    /// The + menu offers the code interpreter: the core's
    /// `codeInterpreterOfferProvider` with nothing chosen yet. Off for a
    /// turn that never reaches an Open WebUI server.
    @Default(false) bool codeInterpreter,

    /// Why the code interpreter cannot run for the selected model, as the
    /// core's `CodeInterpreterBlock` names it (`unsupportedEngine`,
    /// `serverDisabled`, ...); null when it can.
    String? codeInterpreterBlock,

    /// What the + menu may attach for the selected model, as mobile's
    /// `_overflowAttachmentAvailability` decides it.
    @Default(AttachmentAvailability()) AttachmentAvailability attachments,

    /// `$` lists Open WebUI skills: an Open WebUI account, and a model
    /// that is not Hermes, LibreChat or an on-device Direct one.
    @Default(false) bool skills,

    /// `#` lists context (notes, knowledge bases and their files): not for
    /// a Hermes or LibreChat model, which cannot resolve Open WebUI ids.
    @Default(false) bool context,

    /// `#` includes notes: the account's notes feature is on.
    @Default(false) bool notes,

    /// `@` lists the server's users and channels besides the models.
    @Default(false) bool mentions,

    /// The selected model is Hermes on a Desktop Gateway: a message typed
    /// while it answers goes to the running turn (`turns.steer`).
    @Default(false) bool steer,

    /// Image extensions (with the dot, lower case) the composer turns into a
    /// JPEG before uploading, as mobile does: HEIC, RAW and BMP (the core's
    /// `alwaysConvertImageFormats`).
    @Default(<String>[]) List<String> imageConversions,

    /// "Compare Models" may send one message to two models: an Open WebUI
    /// account and model, a stored chat, and the Advanced setting on, as
    /// the core's `comparisonCommandAvailableProvider` decides.
    @Default(false) bool compareModels,

    /// The quick pills Settings › Chats chose that this model can turn on,
    /// in their order (the core's `composerQuickPills`, as mobile's composer
    /// draws them); none outside Open WebUI.
    @Default(<QuickPillOption>[]) List<QuickPillOption> quickPills,

    /// A voice call can start with the selected model: the core's
    /// `voiceCallEligibilityProvider`, the phone's admission. A model is
    /// chosen, and it is Hermes while its connection is usable (a Hermes
    /// chat's call is a Standard one on the desktop), an on-device Direct
    /// model while its connection is there, or else a signed-in Open WebUI
    /// account's. The composer's call button and Start Voice Call follow it.
    @Default(false) bool voiceCall,

    /// The chat talks to a coding agent (Open WebUI 0.13.1 and later): the
    /// selected model is one, or the chat was started with one or has a
    /// reply from one (core's `chatUsesTerminalAgent`). Open WebUI answers an
    /// agent only with a new message at the end of the chat, so Regenerate,
    /// Retry, Edit and Compare Models are not offered.
    @Default(false) bool agentChat,

    /// The selected model has a reasoning-effort control of its own (a
    /// coding agent's, or a `model_controls` entry: `models.controls`), which
    /// takes the place of the app's Reasoning Effort.
    @Default(false) bool ownEffortControl,
  }) = _ComposerOptions;

  factory ComposerOptions.fromJson(Map<String, dynamic> json) =>
      _$ComposerOptionsFromJson(json);
}

/// Params for `composer.options`: the chat the composer is for. Nothing set
/// answers for a new chat.
@freezed
abstract class ComposerOptionsQuery with _$ComposerOptionsQuery {
  const factory ComposerOptionsQuery({
    /// The open chat; null for a new one.
    String? chatId,

    /// The model the composer shows, which the next turn goes to; null for
    /// the account's selection.
    String? modelId,
  }) = _ComposerOptionsQuery;

  factory ComposerOptionsQuery.fromJson(Map<String, dynamic> json) =>
      _$ComposerOptionsQueryFromJson(json);
}

/// A knowledge base, as the `#` menu lists it.
@freezed
abstract class KnowledgeSummary with _$KnowledgeSummary {
  const factory KnowledgeSummary({
    required String id,
    required String name,
    String? description,
  }) = _KnowledgeSummary;

  factory KnowledgeSummary.fromJson(Map<String, dynamic> json) =>
      _$KnowledgeSummaryFromJson(json);
}

/// Params for `composer.knowledge`.
@freezed
abstract class KnowledgeQuery with _$KnowledgeQuery {
  const factory KnowledgeQuery({@Default('') String query}) = _KnowledgeQuery;

  factory KnowledgeQuery.fromJson(Map<String, dynamic> json) =>
      _$KnowledgeQueryFromJson(json);
}

/// Reply to `composer.knowledge`.
@freezed
abstract class KnowledgeList with _$KnowledgeList {
  const factory KnowledgeList({
    @Default(<KnowledgeSummary>[]) List<KnowledgeSummary> items,
  }) = _KnowledgeList;

  factory KnowledgeList.fromJson(Map<String, dynamic> json) =>
      _$KnowledgeListFromJson(json);
}

/// Which attachment kinds the + menu offers for the selected model.
///
/// Mobile's table (`_overflowAttachmentAvailability`): Open WebUI takes
/// every kind but MCP content; a Direct model takes files, images and, with
/// an enabled MCP server, MCP content; Hermes takes files, and images when
/// the server reads them; LibreChat files and images.
@freezed
abstract class AttachmentAvailability with _$AttachmentAvailability {
  const factory AttachmentAvailability({
    @Default(true) bool files,

    /// Files already on the Open WebUI server (`files.list`).
    @Default(false) bool serverFiles,
    @Default(true) bool images,

    /// A web page's readable text or a YouTube video's transcript
    /// (`context.fetchUrl`).
    @Default(false) bool webPage,

    /// A Direct MCP server's prompts and resources (`mcp.content`).
    @Default(false) bool mcpContent,
  }) = _AttachmentAvailability;

  factory AttachmentAvailability.fromJson(Map<String, dynamic> json) =>
      _$AttachmentAvailabilityFromJson(json);
}

/// Params for the composer's searches: `mentions.search`, `skills.search`,
/// `context.search` and `files.list`.
@freezed
abstract class ComposerSearch with _$ComposerSearch {
  const factory ComposerSearch({@Default('') String query}) = _ComposerSearch;

  factory ComposerSearch.fromJson(Map<String, dynamic> json) =>
      _$ComposerSearchFromJson(json);
}

/// A user or channel the `@` menu offers.
@freezed
abstract class MentionTarget with _$MentionTarget {
  const factory MentionTarget({
    required String id,
    required String name,

    /// A second line: a user's email, a channel's description.
    String? detail,
  }) = _MentionTarget;

  factory MentionTarget.fromJson(Map<String, dynamic> json) =>
      _$MentionTargetFromJson(json);
}

/// Reply to `mentions.search`.
@freezed
abstract class MentionList with _$MentionList {
  const factory MentionList({
    @Default(<MentionTarget>[]) List<MentionTarget> users,
    @Default(<MentionTarget>[]) List<MentionTarget> channels,
  }) = _MentionList;

  factory MentionList.fromJson(Map<String, dynamic> json) =>
      _$MentionListFromJson(json);
}

/// An Open WebUI skill, as the `$` menu lists it.
@freezed
abstract class SkillSummary with _$SkillSummary {
  const factory SkillSummary({
    required String id,
    required String name,
    String? description,
  }) = _SkillSummary;

  factory SkillSummary.fromJson(Map<String, dynamic> json) =>
      _$SkillSummaryFromJson(json);
}

/// Reply to `skills.search`.
@freezed
abstract class SkillList with _$SkillList {
  const factory SkillList({
    @Default(<SkillSummary>[]) List<SkillSummary> items,
  }) = _SkillList;

  factory SkillList.fromJson(Map<String, dynamic> json) =>
      _$SkillListFromJson(json);
}

/// What a `#` suggestion attaches.
enum ContextSuggestionKind { note, knowledgeBase, knowledgeFile }

/// A `#` suggestion: the core's `ComposerContextSuggestion`.
@freezed
abstract class ContextSuggestion with _$ContextSuggestion {
  const factory ContextSuggestion({
    required ContextSuggestionKind kind,
    required String id,
    required String name,
    String? subtitle,

    /// A knowledge file's base.
    String? collectionName,
  }) = _ContextSuggestion;

  factory ContextSuggestion.fromJson(Map<String, dynamic> json) =>
      _$ContextSuggestionFromJson(json);
}

/// Reply to `context.search`: notes first, then knowledge bases, then
/// knowledge files, up to four of each (the core's per-type cap).
@freezed
abstract class ContextSuggestions with _$ContextSuggestions {
  const factory ContextSuggestions({
    @Default(<ContextSuggestion>[]) List<ContextSuggestion> items,
  }) = _ContextSuggestions;

  factory ContextSuggestions.fromJson(Map<String, dynamic> json) =>
      _$ContextSuggestionsFromJson(json);
}

/// What a context attachment is.
enum ContextAttachmentKind { web, youtube, knowledge, note }

/// Context that goes with a message without being a file: a web page's
/// text, a YouTube transcript, a note, a knowledge file. The core's
/// `ChatContextAttachment`.
@freezed
abstract class ContextAttachmentDto with _$ContextAttachmentDto {
  const factory ContextAttachmentDto({
    required String id,
    required ContextAttachmentKind kind,
    required String name,
    String? url,

    /// A page's readable text or a video's transcript, as the server
    /// extracted it.
    String? content,
    String? collectionName,

    /// A knowledge file's id.
    String? fileId,
  }) = _ContextAttachmentDto;

  factory ContextAttachmentDto.fromJson(Map<String, dynamic> json) =>
      _$ContextAttachmentDtoFromJson(json);
}

/// Params for `context.fetchUrl`.
@freezed
abstract class FetchUrl with _$FetchUrl {
  const factory FetchUrl({required String url}) = _FetchUrl;

  factory FetchUrl.fromJson(Map<String, dynamic> json) =>
      _$FetchUrlFromJson(json);
}

/// Reply to `context.fetchUrl`: the attachment, or why there is none.
@freezed
abstract class FetchedUrl with _$FetchedUrl {
  const factory FetchedUrl({
    ContextAttachmentDto? attachment,

    /// `invalidUrl`, `noContent` (a page with no readable text, a video
    /// with no transcript) or `failed`; null with an attachment.
    String? error,
  }) = _FetchedUrl;

  factory FetchedUrl.fromJson(Map<String, dynamic> json) =>
      _$FetchedUrlFromJson(json);
}

/// A file already on the Open WebUI server, for the server-file picker.
@freezed
abstract class ServerFile with _$ServerFile {
  const factory ServerFile({
    required String id,
    required String name,
    int? size,
    String? contentType,
    int? updatedAtMs,
  }) = _ServerFile;

  factory ServerFile.fromJson(Map<String, dynamic> json) =>
      _$ServerFileFromJson(json);
}

/// Reply to `files.list`.
@freezed
abstract class ServerFileList with _$ServerFileList {
  const factory ServerFileList({
    @Default(<ServerFile>[]) List<ServerFile> items,
  }) = _ServerFileList;

  factory ServerFileList.fromJson(Map<String, dynamic> json) =>
      _$ServerFileListFromJson(json);
}

/// What a mention stands for.
enum MentionKind { entity, skill }

/// A mention in a message: the core's `ComposerMention`. The daemon turns
/// the text into Open WebUI's wire format (`<@U:id|Name>`, `<$id|Name>`)
/// with the core's tracker.
@freezed
abstract class ComposerMentionDto with _$ComposerMentionDto {
  const factory ComposerMentionDto({
    /// UTF-16 offsets into the message text, [end] exclusive.
    required int start,
    required int end,
    required String id,
    required String label,

    /// `M` a model, `U` a user, `C` a channel.
    @Default('M') String idType,
    @Default(MentionKind.entity) MentionKind kind,
  }) = _ComposerMentionDto;

  factory ComposerMentionDto.fromJson(Map<String, dynamic> json) =>
      _$ComposerMentionDtoFromJson(json);
}
