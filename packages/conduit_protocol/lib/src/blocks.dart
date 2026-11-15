import 'package:freezed_annotation/freezed_annotation.dart';

import 'chats.dart';

part 'blocks.freezed.dart';
part 'blocks.g.dart';

/// What a [MessageBlockDto] is.
///
/// An assistant answer is an ordered list of blocks, in the order the
/// mobile app draws them (its `AssistantMessageWidget`, top to bottom):
///
/// 1. [files] -- at most one;
/// 2. [status] -- at most one;
/// 3. the content, in the order it was written: [text], [reasoning],
///    [toolCalls], [codeInterpreter] and [details], any number of each;
/// 4. [error] -- at most one;
/// 5. [codeExecution] -- one per execution;
/// 6. [sources] -- at most one;
/// 7. [followUps] -- at most one, only once the answer is finished.
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
  /// [MessageBlockDto.type].
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

    /// `text`: the markdown.
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
    /// `error`: why, when hosts should say something other than [error]:
    /// `directToolsUnsupported` (the model refused tool definitions; advise
    /// turning web search off). Absent otherwise.
    String? type,

    /// `status`: the timeline, oldest first.
    List<MessageStatusDto>? statuses,

    /// `files`: the answer's files. `codeExecution`: files it wrote.
    List<ChatFileDto>? files,

    /// `sources`: what `[n]` cites, in order.
    List<ChatSourceDto>? sources,

    /// `followUps`: the suggestions.
    List<String>? followUps,
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
  }) = _ToolCallDto;

  factory ToolCallDto.fromJson(Map<String, dynamic> json) =>
      _$ToolCallDtoFromJson(json);
}

/// One line of a `status` block's timeline.
@freezed
abstract class MessageStatusDto with _$MessageStatusDto {
  const factory MessageStatusDto({
    /// What the line reads, worded as Open WebUI's client words it.
    required String description,

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
