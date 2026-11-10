import 'package:conduit_core/features/hermes/models/hermes_error_surface.dart';

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
  const HermesReasoningDelta(this.content, {this.terminal = false});

  final String content;

  /// Whether this is the whole reasoning repeated by a terminal response,
  /// which duplicates any reasoning already streamed as deltas.
  final bool terminal;
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
    this.arguments,
    this.result,
    this.inlineDiff,
    this.subagent = false,
    this.failed = false,
  });

  /// Tool/toolset name, e.g. `terminal`, `web_search`, `file_edit`.
  final String toolName;

  /// A short human-readable description of what the tool is doing.
  final String? detail;
  final String? arguments;
  final String? result;
  final String? inlineDiff;
  final bool subagent;

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
    this.choices = const <String>[],
    this.executionGeneration,
    this.raw = const {},
  });

  /// Identifier passed back to `POST /v1/runs/{id}/approval`. On Hermes
  /// v0.22.1+ this is the prompt's `prompt_id`.
  final String approvalId;

  /// Human-readable description of what is being approved.
  final String? summary;
  final List<String> choices;

  /// The session execution generation that owns the prompt. Present only on
  /// servers that require the exact `{request_id, execution_generation,
  /// choice}` approval body.
  final int? executionGeneration;

  /// The raw approval payload, preserved for forward-compatibility.
  final Map<String, dynamic> raw;
}

/// An approval or clarify prompt was answered, timed out, or was withdrawn.
///
/// The card for [promptId] must close and never come back for this prompt.
final class HermesPromptSettled extends HermesRunEvent {
  const HermesPromptSettled({required this.promptId, required this.kind});

  final String promptId;

  /// `approval` or `clarify`.
  final String kind;
}

enum HermesDecisionKind { clarification, sudo, secret, mcpSetup }

/// A Desktop Gateway request that needs a structured user response.
final class HermesDecisionRequested extends HermesRunEvent {
  const HermesDecisionRequested({
    required this.kind,
    required this.requestId,
    this.prompt,
    this.raw = const {},
  });

  final HermesDecisionKind kind;
  final String requestId;
  final String? prompt;
  final Map<String, dynamic> raw;
}

/// A non-error note about how a run ended, such as a wrap-up after Hermes
/// ran out of steps. The answer so far is kept and shown with the note.
final class HermesRunNotice extends HermesRunEvent {
  const HermesRunNotice(this.message);

  final String message;
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

/// Text returned by a Desktop slash command that belongs back in the composer.
final class HermesComposerPrefill extends HermesRunEvent {
  const HermesComposerPrefill(this.text);

  final String text;
}

/// A terminal error reported by the run.
final class HermesRunError extends HermesRunEvent {
  const HermesRunError(this.message, {this.surface});

  final String message;

  /// What broke, when Hermes classified the failure.
  final HermesErrorSurface? surface;
}

/// The stream is finished (`[DONE]`, `event: done`, or a terminal lifecycle).
final class HermesRunDone extends HermesRunEvent {
  const HermesRunDone();
}
