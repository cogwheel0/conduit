/// Typed events emitted by the Hermes Agent runs stream
/// (`GET /v1/runs/{id}/events`) and the chat-completions
/// `hermes.tool.progress` custom event.
///
/// The Hermes runs API is young and its exact payload shapes vary across
/// versions, so [parseHermesRunFrame] decodes defensively and maps everything
/// it recognizes onto this small, render-focused set of events. Anything
/// unrecognized becomes a no-op rather than an error.
sealed class HermesRunEvent {
  const HermesRunEvent();
}

/// Identity announced by the OpenAI-compatible Responses stream.
final class HermesResponseCreated extends HermesRunEvent {
  const HermesResponseCreated(this.responseId);

  final String responseId;
}

/// Incremental assistant text (token delta).
final class HermesTokenDelta extends HermesRunEvent {
  const HermesTokenDelta(this.content);

  final String content;
}

/// Incremental reasoning/thinking text, when the agent exposes it.
final class HermesReasoningDelta extends HermesRunEvent {
  const HermesReasoningDelta(this.content);

  final String content;
}

/// A tool the agent is running (started / progressing / completed).
///
/// [done] is false while the tool is in flight and true once it finishes, which
/// maps directly onto Conduit's `ChatStatusUpdate.done` rendering.
final class HermesToolProgress extends HermesRunEvent {
  const HermesToolProgress({
    required this.toolName,
    required this.done,
    this.detail,
    this.failed = false,
  });

  /// Tool/toolset name, e.g. `terminal`, `web_search`, `file_edit`.
  final String toolName;

  /// A short human-readable description of what the tool is doing.
  final String? detail;

  /// Whether the tool has finished (vs. just started / progressing).
  final bool done;

  /// Whether this terminal progress event reports a tool failure.
  final bool failed;
}

/// The run paused and is waiting for human approval before continuing.
final class HermesApprovalRequested extends HermesRunEvent {
  const HermesApprovalRequested({
    required this.approvalId,
    this.summary,
    this.raw = const {},
  });

  /// Identifier passed back to `POST /v1/runs/{id}/approval`.
  final String approvalId;

  /// Human-readable description of what is being approved.
  final String? summary;

  /// The raw approval payload, preserved for forward-compatibility.
  final Map<String, dynamic> raw;
}

/// A lifecycle transition (created / completed / failed / cancelled / stopping).
final class HermesLifecycle extends HermesRunEvent {
  const HermesLifecycle(this.status);

  final String status;
}

/// The run's final/full output text (e.g. from `run.completed`). Used as a
/// fallback when no incremental deltas were streamed, so the message is never
/// left empty.
final class HermesFinalOutput extends HermesRunEvent {
  const HermesFinalOutput(this.text);

  final String text;
}

/// A terminal error reported by the run.
final class HermesRunError extends HermesRunEvent {
  const HermesRunError(this.message);

  final String message;
}

/// The stream is finished (`[DONE]`, `event: done`, or a terminal lifecycle).
final class HermesRunDone extends HermesRunEvent {
  const HermesRunDone();
}
