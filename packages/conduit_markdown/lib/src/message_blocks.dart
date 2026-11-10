import 'package:meta/meta.dart';

/// The kinds of [MessageBlock], as written in [MessageBlock.toJson].
enum MessageBlockKind {
  /// Answer markdown.
  text,

  /// A reasoning (thinking) section.
  reasoning,

  /// One or more tool calls in a row.
  toolCalls,

  /// A code-interpreter run.
  codeInterpreter,

  /// Any other `<details>` section, shown as a plain disclosure.
  details,
}

/// One ordered piece of an assistant message, as produced by
/// [segmentAssistantMessage].
///
/// Blocks are immutable values. Markdown fields hold the markdown the mobile
/// renderer would parse; [normalizeBlocksForPlainMarkdown] turns them into
/// the dialect a plain markdown renderer understands.
@immutable
sealed class MessageBlock {
  const MessageBlock();

  MessageBlockKind get kind;

  /// A JSON-compatible map keyed by field name, with `kind` first. Fixture
  /// and golden files use this shape.
  Map<String, Object?> toJson();

  @override
  String toString() => '$runtimeType(${toJson()})';
}

/// Answer markdown between the other blocks.
final class TextMessageBlock extends MessageBlock {
  const TextMessageBlock(this.markdown);

  /// Markdown with any `<details>` sections lifted out into their own blocks.
  final String markdown;

  @override
  MessageBlockKind get kind => MessageBlockKind.text;

  @override
  Map<String, Object?> toJson() => {'kind': kind.name, 'markdown': markdown};

  @override
  bool operator ==(Object other) =>
      other is TextMessageBlock && other.markdown == markdown;

  @override
  int get hashCode => markdown.hashCode;
}

/// What the header of a reasoning block reads.
enum ReasoningTitleKind {
  /// "Thinking…": the block is not done.
  thinking,

  /// "Thought for N seconds": done, with a duration of at least a second.
  thoughtFor,

  /// The block's own summary text.
  summary,

  /// "Thoughts": done, with no timing at all or one under a second.
  thoughts,
}

/// The resolved header of a [ReasoningMessageBlock].
@immutable
final class ReasoningTitle {
  const ReasoningTitle._(this.kind, {this.seconds = 0, this.summary = ''});

  final ReasoningTitleKind kind;

  /// Seconds for [ReasoningTitleKind.thoughtFor]; otherwise 0.
  final int seconds;

  /// Text for [ReasoningTitleKind.summary]; otherwise empty.
  final String summary;

  @override
  bool operator ==(Object other) =>
      other is ReasoningTitle &&
      other.kind == kind &&
      other.seconds == seconds &&
      other.summary == summary;

  @override
  int get hashCode => Object.hash(kind, seconds, summary);

  @override
  String toString() => 'ReasoningTitle(${kind.name}, $seconds, $summary)';
}

final RegExp _summaryDuration = RegExp(
  r'\((\d+)s\)|\bfor (\d+) seconds?\b',
  caseSensitive: false,
);

/// A reasoning section.
final class ReasoningMessageBlock extends MessageBlock {
  const ReasoningMessageBlock({
    required this.summary,
    required this.durationSeconds,
    required this.done,
    required this.pending,
    required this.body,
  });

  /// The `<summary>` text, entity-decoded and trimmed (often "Thinking…" or
  /// "Thought for N seconds"; may be empty).
  final String summary;

  /// The `duration` attribute in whole seconds, or null when the block
  /// carries none. A duration that is present but not a number reads 0.
  final int? durationSeconds;

  /// `done="true"`.
  final bool done;

  /// Not done, but the block says so explicitly (`done="false"`): show a
  /// spinner.
  final bool pending;

  /// The reasoning markdown.
  final String body;

  /// The header, resolved the way Open WebUI's `Collapsible.svelte` and the
  /// mobile renderer do: "Thought for…" only once the block is done and
  /// carries a duration; a pending block reads "Thinking…"; a finished block
  /// with no timing reads "Thoughts" rather than inventing one. Legacy
  /// content that kept its timing only in the summary text still reads
  /// "Thought for…". A timing under a second reads "Thoughts" too: the
  /// server times the block from its first chunk to its last, so a block
  /// that arrives in one burst after a long wait reads 0.
  ReasoningTitle get title {
    final trimmed = summary.trim();
    final lower = trimmed.toLowerCase();
    final isThinkingSummary =
        lower == 'thinking…' ||
        lower == 'thinking...' ||
        lower.startsWith('thinking');
    if (!done) {
      return trimmed.isNotEmpty && !isThinkingSummary
          ? ReasoningTitle._(ReasoningTitleKind.summary, summary: trimmed)
          : const ReasoningTitle._(ReasoningTitleKind.thinking);
    }
    final duration = durationSeconds;
    if (duration != null && duration >= 1) {
      return ReasoningTitle._(ReasoningTitleKind.thoughtFor, seconds: duration);
    }
    final legacy = _summaryDuration.firstMatch(trimmed);
    if (legacy != null) {
      final seconds = int.tryParse(legacy.group(1) ?? legacy.group(2) ?? '');
      if (seconds != null && seconds >= 1) {
        return ReasoningTitle._(
          ReasoningTitleKind.thoughtFor,
          seconds: seconds,
        );
      }
    }
    if (legacy != null || duration != null) {
      return const ReasoningTitle._(ReasoningTitleKind.thoughts);
    }
    if (trimmed.isNotEmpty && !isThinkingSummary) {
      return ReasoningTitle._(ReasoningTitleKind.summary, summary: trimmed);
    }
    return const ReasoningTitle._(ReasoningTitleKind.thoughts);
  }

  @override
  MessageBlockKind get kind => MessageBlockKind.reasoning;

  @override
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'summary': summary,
    'durationSeconds': durationSeconds,
    'done': done,
    'pending': pending,
    'body': body,
  };

  @override
  bool operator ==(Object other) =>
      other is ReasoningMessageBlock &&
      other.summary == summary &&
      other.durationSeconds == durationSeconds &&
      other.done == done &&
      other.pending == pending &&
      other.body == body;

  @override
  int get hashCode =>
      Object.hash(summary, durationSeconds, done, pending, body);
}

/// One tool call inside a [ToolCallsMessageBlock].
@immutable
final class MessageToolCall {
  const MessageToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    required this.result,
    required this.done,
    required this.pending,
    required this.isError,
    this.status,
    this.files,
    this.embeds,
  });

  /// The `id` attribute; may be empty.
  final String id;

  /// The tool name, trimmed; may be empty (the mobile renderer then says
  /// "tool").
  final String name;

  /// The call's arguments as written, usually a JSON object. Empty when the
  /// block has none.
  final String arguments;

  /// The result as written: JSON, a JSON string, or plain text. Open WebUI
  /// puts it in the `result` attribute or the block body; both end up here.
  final String result;

  /// Finished: `done="true"`, or a terminal status (`failed`, `incomplete`,
  /// `rejected`).
  final bool done;

  /// Not done, and the block says so (`done="false"` or any `status`): show a
  /// spinner.
  final bool pending;

  /// The `status` attribute (Open WebUI 0.13 approval flow: `pending`,
  /// `completed`, `failed`, `rejected`, `incomplete`, …), or null.
  final String? status;

  /// Whether the call failed: a `failed` status, or a result that reads as an
  /// error the way Open WebUI's `ToolCallDisplay.svelte` decides.
  final bool isError;

  /// The `files` attribute (a JSON array), or null.
  final String? files;

  /// The `embeds` attribute (a JSON array), or null.
  final String? embeds;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
    'result': result,
    'done': done,
    'pending': pending,
    'status': status,
    'isError': isError,
    'files': files,
    'embeds': embeds,
  };

  @override
  bool operator ==(Object other) =>
      other is MessageToolCall &&
      other.id == id &&
      other.name == name &&
      other.arguments == arguments &&
      other.result == result &&
      other.done == done &&
      other.pending == pending &&
      other.status == status &&
      other.isError == isError &&
      other.files == files &&
      other.embeds == embeds;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    arguments,
    result,
    done,
    pending,
    status,
    isError,
    files,
    embeds,
  );

  @override
  String toString() => 'MessageToolCall(${toJson()})';
}

/// Tool calls that sit next to each other in the message, shown as one
/// group (one call is a group of one).
final class ToolCallsMessageBlock extends MessageBlock {
  ToolCallsMessageBlock(List<MessageToolCall> calls)
    : calls = List<MessageToolCall>.unmodifiable(calls);

  final List<MessageToolCall> calls;

  @override
  MessageBlockKind get kind => MessageBlockKind.toolCalls;

  @override
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'calls': [for (final call in calls) call.toJson()],
  };

  @override
  bool operator ==(Object other) {
    if (other is! ToolCallsMessageBlock) return false;
    if (other.calls.length != calls.length) return false;
    for (var index = 0; index < calls.length; index++) {
      if (other.calls[index] != calls[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(calls);
}

/// A code-interpreter run.
final class CodeInterpreterMessageBlock extends MessageBlock {
  const CodeInterpreterMessageBlock({
    required this.code,
    required this.language,
    required this.output,
    required this.done,
    required this.pending,
  });

  /// The code from the block's leading fence; empty when it has none.
  final String code;

  /// The fence's language (`python`, …); may be empty.
  final String language;

  /// Everything after the code fence, as markdown: the run's output.
  final String output;

  /// `done="true"` ("Analyzed" rather than "Analyzing…").
  final bool done;

  /// Not done, and the block says so (`done="false"`).
  final bool pending;

  @override
  MessageBlockKind get kind => MessageBlockKind.codeInterpreter;

  @override
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'code': code,
    'language': language,
    'output': output,
    'done': done,
    'pending': pending,
  };

  @override
  bool operator ==(Object other) =>
      other is CodeInterpreterMessageBlock &&
      other.code == code &&
      other.language == language &&
      other.output == output &&
      other.done == done &&
      other.pending == pending;

  @override
  int get hashCode => Object.hash(code, language, output, done, pending);
}

/// Any other `<details>` section (no `type`, or one Conduit does not draw
/// specially, such as `openai_builtin_tool`): a disclosure with a summary.
final class DetailsMessageBlock extends MessageBlock {
  const DetailsMessageBlock({
    required this.type,
    required this.summary,
    required this.body,
    required this.done,
    required this.pending,
  });

  /// The `type` attribute, trimmed; empty when absent.
  final String type;

  /// The `<summary>` text; empty when absent (the mobile renderer then says
  /// "Details").
  final String summary;

  /// The section's markdown.
  final String body;

  final bool done;
  final bool pending;

  @override
  MessageBlockKind get kind => MessageBlockKind.details;

  @override
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'type': type,
    'summary': summary,
    'body': body,
    'done': done,
    'pending': pending,
  };

  @override
  bool operator ==(Object other) =>
      other is DetailsMessageBlock &&
      other.type == type &&
      other.summary == summary &&
      other.body == body &&
      other.done == done &&
      other.pending == pending;

  @override
  int get hashCode => Object.hash(type, summary, body, done, pending);
}
