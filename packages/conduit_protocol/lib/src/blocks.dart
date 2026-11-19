import 'package:freezed_annotation/freezed_annotation.dart';

import 'chats.dart';
import 'hermes_work.dart';
import 'mcp_apps.dart';

part 'blocks.freezed.dart';
part 'blocks.g.dart';

/// What a [MessageBlockDto] is.
///
/// An assistant answer is an ordered list of blocks, in the order the
/// mobile app draws them (its `AssistantMessageWidget`, top to bottom):
///
/// 1. [files] -- at most one;
/// 2. [embeds] -- at most one;
/// 3. [status] -- at most one;
/// 4. the content, in the order it was written: [text], [alert],
///    [reasoning], [toolCalls], [codeInterpreter] and [details], any number
///    of each;
/// 5. [error] -- at most one;
/// 6. [codeExecution] -- one per execution;
/// 7. [sources] -- at most one;
/// 8. [followUps] -- at most one, only once the answer is finished.
///
/// A kind this build does not know (from a newer daemon) is skipped.
enum MessageBlockKind {
  /// Answer markdown: [MessageBlockDto.markdown].
  text,

  /// A reasoning (thinking) section: [MessageBlockDto.title],
  /// [MessageBlockDto.summary], [MessageBlockDto.durationSeconds],
  /// [MessageBlockDto.done], [MessageBlockDto.pending] and
  /// [MessageBlockDto.body]. Collapsed by default.
  reasoning,

  /// Tool calls that sit next to each other, shown as one group:
  /// [MessageBlockDto.calls].
  toolCalls,

  /// A code-interpreter run written into the content:
  /// [MessageBlockDto.code], [MessageBlockDto.language],
  /// [MessageBlockDto.output], [MessageBlockDto.done] and
  /// [MessageBlockDto.pending].
  codeInterpreter,

  /// Any other `<details>` section, as a plain disclosure:
  /// [MessageBlockDto.type], [MessageBlockDto.summary],
  /// [MessageBlockDto.body], [MessageBlockDto.done] and
  /// [MessageBlockDto.pending].
  details,

  /// The answer's files, above everything else: generated images, files the
  /// model showed. [MessageBlockDto.files].
  files,

  /// The status timeline (searching the web, reading a knowledge base,
  /// Hermes tools): [MessageBlockDto.statuses], [MessageBlockDto.pending]
  /// and, for a run of Hermes tools, [MessageBlockDto.summary]. The row
  /// shows the last status (or the summary) and opens to all of them.
  status,

  /// The error banner under the content: [MessageBlockDto.error] and
  /// [MessageBlockDto.type]. A Hermes turn that Hermes classified also
  /// carries [MessageBlockDto.hermesError], drawn as its error card.
  error,

  /// One code execution, a header that opens to its code and result:
  /// [MessageBlockDto.id], [MessageBlockDto.name], [MessageBlockDto.code],
  /// [MessageBlockDto.language], [MessageBlockDto.output],
  /// [MessageBlockDto.error], [MessageBlockDto.files],
  /// [MessageBlockDto.done], [MessageBlockDto.pending] and
  /// [MessageBlockDto.isError].
  codeExecution,

  /// What the answer cites: [MessageBlockDto.sources]. A
  /// `conduit-cite:n` link in a text block names `sources[n - 1]`. The
  /// mobile app shows them as a pill in the action row once the answer is
  /// finished.
  sources,

  /// Suggested follow-ups, at most three: [MessageBlockDto.followUps].
  /// The mobile app offers them under the last answer of a chat only.
  followUps,

  /// A GitHub-style alert written at the top level of the answer
  /// (`> [!NOTE]`): its kind in [MessageBlockDto.type] (`note`, `tip`,
  /// `important`, `warning` or `caution`) and its body in
  /// [MessageBlockDto.markdown]. Hosts label it in their own words.
  alert,

  /// Rich content the answer carries: tool-returned HTML, a page to embed,
  /// or an MCP App ([MessageBlockDto.embeds]). Each loads only when the
  /// user opens it.
  embeds,

  /// The files a Hermes reply's tools changed, with their added and removed
  /// lines ([MessageBlockDto.changedFiles]): a card that opens each file's
  /// coloured diff.
  changedFiles,
}

/// What an [EmbedDto] shows.
enum EmbedKind {
  /// Inline HTML (or SVG) a tool returned: [EmbedDto.source].
  html,

  /// A web page to embed: [EmbedDto.source] is its http(s) address.
  url,

  /// An MCP App: [EmbedDto.app].
  mcpApp,
}

/// One piece of rich content in an answer or a tool call's result.
@freezed
abstract class EmbedDto with _$EmbedDto {
  const factory EmbedDto({
    required EmbedKind kind,

    /// [EmbedKind.html]: the markup. [EmbedKind.url]: the address.
    String? source,

    /// A tool call's arguments as written, which an HTML embed may read as
    /// `window.args`; empty for an answer's own embeds.
    @Default('') String argsText,

    /// [EmbedKind.mcpApp]: the app, to open with `mcpApps.open`.
    McpAppDto? app,
  }) = _EmbedDto;

  factory EmbedDto.fromJson(Map<String, dynamic> json) =>
      _$EmbedDtoFromJson(json);
}

/// What a reasoning block's header reads.
enum ReasoningTitle {
  /// "Thinking…": not done yet.
  thinking,

  /// "Thought for N seconds", N being [MessageBlockDto.durationSeconds].
  thoughtFor,

  /// The block's own [MessageBlockDto.summary].
  summary,

  /// "Thoughts": done, with no timing.
  thoughts,
}

/// One block of an assistant answer, already parsed by the daemon.
///
/// One flat record for every [MessageBlockKind]: [kind] says which fields
/// are set, and the rest are left out. Markdown fields ([markdown], [body],
/// and [output] of a code-interpreter run) are written for a plain markdown
/// renderer (CommonMark + GFM + `$` math): prose dollars are escaped, math
/// is `$…$` or a `$$` block, raw HTML is escaped, and a citation `[n]` is a
/// link to `conduit-cite:n`. Code, tool arguments and results are as
/// written.
@freezed
abstract class MessageBlockDto with _$MessageBlockDto {
  const factory MessageBlockDto({
    required MessageBlockKind kind,

    /// `text`: the markdown. `alert`: its body, as markdown.
    String? markdown,

    /// `reasoning`, `details`: the `<summary>` text (may be empty).
    /// `status`: what a run of Hermes tools did (`terminal (2), search`),
    /// for the row's own "Exploring …" or "Explored …".
    String? summary,

    /// `reasoning`: what the header reads.
    ReasoningTitle? title,

    /// `reasoning`: the seconds a [ReasoningTitle.thoughtFor] header reads
    /// (the section's duration, or the timing an older answer kept only in
    /// its summary); otherwise the duration, when the section has one.
    int? durationSeconds,

    /// `reasoning`, `codeInterpreter`, `details`, `codeExecution`: finished.
    bool? done,

    /// `reasoning`, `codeInterpreter`, `details`, `codeExecution`: not
    /// finished, and says so -- show a spinner. `status`: the row shimmers.
    bool? pending,

    /// `reasoning`, `details`: the section's markdown.
    String? body,

    /// `toolCalls`: the calls, in order.
    List<ToolCallDto>? calls,

    /// `codeInterpreter`, `codeExecution`: the code.
    String? code,

    /// `codeInterpreter`, `codeExecution`: its language (`python`, …); may
    /// be empty.
    String? language,

    /// `codeInterpreter`: the run's output, as markdown.
    /// `codeExecution`: its output, as plain text.
    String? output,

    /// `codeExecution`: the execution's id.
    String? id,

    /// `codeExecution`: its name, when it has one (hosts say "Execution"
    /// otherwise).
    String? name,

    /// `codeExecution`: the error it ended with, as plain text.
    /// `error`: the server's or provider's words, as plain text; empty when
    /// it gave none.
    String? error,

    /// `codeExecution`: it ended with [error].
    bool? isError,

    /// `details`: the section's `type` attribute; empty when absent.
    /// `alert`: its kind (`note`, `tip`, `important`, `warning`,
    /// `caution`).
    /// `error`: why, when hosts should say something other than [error]:
    /// `directToolsUnsupported` (the model refused tool definitions; advise
    /// turning web search off), `heldReplyStillRunning` (a polling-only
    /// server may still be writing the reply; open the chat again later).
    /// Absent otherwise.
    String? type,

    /// `status`: the timeline, oldest first.
    List<MessageStatusDto>? statuses,

    /// `files`: the answer's files. `codeExecution`: files it wrote.
    List<ChatFileDto>? files,

    /// `sources`: what `[n]` cites, in order.
    List<ChatSourceDto>? sources,

    /// `followUps`: the suggestions.
    List<String>? followUps,

    /// `embeds`: what the answer carries, in order.
    List<EmbedDto>? embeds,

    /// `changedFiles`: each changed file, in the order the tools changed
    /// them.
    List<ChangedFileDto>? changedFiles,

    /// `error`: a Hermes failure as Hermes classified it, for its card.
    HermesErrorDto? hermesError,
  }) = _MessageBlockDto;

  factory MessageBlockDto.fromJson(Map<String, dynamic> json) =>
      _$MessageBlockDtoFromJson(json);
}

/// One tool call in a `toolCalls` block.
@freezed
abstract class ToolCallDto with _$ToolCallDto {
  const factory ToolCallDto({
    /// The call's id; may be empty.
    @Default('') String id,

    /// The tool's name; may be empty (hosts say "tool").
    @Default('') String name,

    /// The arguments as written, usually a JSON object; empty when none.
    @Default('') String arguments,

    /// The result as written: JSON, a JSON string or plain text; empty
    /// until it has one.
    @Default('') String result,

    /// Finished, or ended (failed, rejected, incomplete).
    @Default(false) bool done,

    /// Not finished, and says so: show a spinner.
    @Default(false) bool pending,

    /// Open WebUI's approval status (`pending`, `completed`, `failed`,
    /// `rejected`, `incomplete`, …), when it has one.
    String? status,

    /// The call failed, or its result reads as an error.
    @Default(false) bool isError,

    /// Files the tool returned, as the JSON array Open WebUI wrote.
    String? files,

    /// Embeds the tool returned, as the JSON array Open WebUI wrote.
    String? embeds,

    /// [embeds], read: what to show under the call, in order (HTML with
    /// the call's arguments, a page, or an MCP App).
    @Default(<EmbedDto>[]) List<EmbedDto> shownEmbeds,
  }) = _ToolCallDto;

  factory ToolCallDto.fromJson(Map<String, dynamic> json) =>
      _$ToolCallDtoFromJson(json);
}

/// The status lines core words itself (the core's `ChatStatusPhrase`).
enum StatusPhrase {
  /// "Searching Knowledge for "…"", with [MessageStatusDto.query].
  knowledgeSearch,
  searching,
  querying,

  /// "Retrieved N sources", with [MessageStatusDto.count].
  sourcesRetrieved,
  processing,
}

/// One line of a `status` block's timeline.
@freezed
abstract class MessageStatusDto with _$MessageStatusDto {
  const factory MessageStatusDto({
    /// What the line reads, worded as Open WebUI's client words it.
    required String description,

    /// When [description] is core's own wording rather than Open WebUI's:
    /// which, for the window to word in its own language.
    StatusPhrase? phrase,

    /// How many sources `sourcesRetrieved` found.
    int? count,

    /// What `knowledgeSearch` searched for.
    String? query,

    /// The update's action (`web_search`, `knowledge_search`, …), if any.
    String? action,

    /// The update reported done.
    @Default(false) bool done,

    /// Search queries it ran.
    @Default(<String>[]) List<String> queries,

    /// Pages it found. [ChatSourceDto.label] is the page's title, or its
    /// domain.
    @Default(<ChatSourceDto>[]) List<ChatSourceDto> links,

    /// Items to show as a snippet under a title: [ChatSourceDto.label] and
    /// [ChatSourceDto.snippet].
    @Default(<ChatSourceDto>[]) List<ChatSourceDto> details,
  }) = _MessageStatusDto;

  factory MessageStatusDto.fromJson(Map<String, dynamic> json) =>
      _$MessageStatusDtoFromJson(json);
}
