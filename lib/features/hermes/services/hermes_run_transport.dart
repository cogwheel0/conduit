import 'dart:async';

import 'package:dio/dio.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/hermes_run_event.dart';
import '../providers/hermes_providers.dart';
import 'hermes_api_service.dart';

/// Metadata key under which Hermes approval state is stored on an assistant
/// [ChatMessage]. The value is a map: `{state, approvalId, runId, summary}`.
const String kHermesApprovalMeta = 'hermesApproval';

/// Transport metadata marker so the stop path can recognize a Hermes run.
const String kHermesTransport = 'hermesRun';

/// Drives one Hermes run end-to-end: creates the run, subscribes to its event
/// stream, and maps each [HermesRunEvent] onto the supplied chat-notifier
/// callbacks (the same surface the OpenWebUI transport uses).
///
/// Callbacks are pre-bound to the target assistant message so this stays
/// decoupled from `chat_providers` (no circular import) and unit-testable.
Future<void> dispatchHermesRun({
  required HermesApiService service,
  required HermesRunRegistry registry,
  required String assistantMessageId,
  required String input,
  String? sessionId,
  String? previousResponseId,
  required void Function(String content) appendContent,
  required void Function(ChatStatusUpdate update) appendStatus,
  required void Function(ChatMessage Function(ChatMessage) updater) updateMessage,
  required void Function() finishStreaming,
  required void Function() completeStreamingUi,
}) async {
  final cancelToken = CancelToken();

  String runId;
  try {
    runId = await service.createRun(
      input: input,
      sessionId: sessionId,
      previousResponseId: previousResponseId,
    );
  } catch (e, st) {
    DebugLogger.error(
      'create-run-failed',
      scope: 'hermes/transport',
      error: e,
      stackTrace: st,
    );
    updateMessage(
      (m) => m.copyWith(error: ChatMessageError(content: _friendlyError(e))),
    );
    finishStreaming();
    return;
  }

  // Record transport metadata so the stop path can find this run.
  updateMessage((m) {
    final meta = Map<String, dynamic>.from(m.metadata ?? const {});
    meta['transport'] = kHermesTransport;
    meta['hermesRunId'] = runId;
    return m.copyWith(metadata: meta);
  });

  final completer = Completer<void>();
  var sawTerminal = false;
  var gotContent = false;
  String? finalOutput;
  Object? streamError;

  late final StreamSubscription<HermesRunEvent> sub;
  sub = service.runEvents(runId, sessionId: sessionId, cancelToken: cancelToken)
      .listen(
        (event) {
          if (event is HermesTokenDelta) gotContent = true;
          if (event is HermesFinalOutput) finalOutput = event.text;
          if (event is HermesRunDone || event is HermesRunError) {
            sawTerminal = true;
          }
          _handleEvent(
            event,
            runId: runId,
            appendContent: appendContent,
            appendStatus: appendStatus,
            updateMessage: updateMessage,
          );
        },
        onError: (Object e, StackTrace st) {
          if (!cancelToken.isCancelled) streamError = e;
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: true,
      );

  registry.register(
    assistantMessageId,
    runId: runId,
    cancelToken: cancelToken,
    subscription: sub,
  );

  try {
    await completer.future;

    // The run finished but streamed no incremental text — fall back to the
    // final output carried by `run.completed`.
    if (sawTerminal &&
        !gotContent &&
        finalOutput != null &&
        finalOutput!.isNotEmpty) {
      appendContent(finalOutput!);
    }

    // The events stream ended without a terminal event and the user didn't
    // stop — it likely dropped (network blip / app backgrounded). Reconcile the
    // final result by polling the run instead of leaving the message hung.
    if (!sawTerminal && !cancelToken.isCancelled) {
      final recovered = await _recoverRunOutput(service, runId);
      if (recovered != null) {
        if (!gotContent && recovered.text.isNotEmpty) {
          appendContent(recovered.text);
        }
        if (recovered.failed) {
          updateMessage(
            (m) => m.copyWith(
              error: const ChatMessageError(content: 'Hermes run failed.'),
            ),
          );
        }
      } else if (streamError != null) {
        DebugLogger.error(
          'run-stream-error',
          scope: 'hermes/transport',
          error: streamError,
        );
        updateMessage(
          (m) => m.copyWith(
            error: ChatMessageError(content: _friendlyError(streamError!)),
          ),
        );
      }
    }
  } finally {
    await sub.cancel();
    registry.complete(assistantMessageId);
    finishStreaming();
    completeStreamingUi();
  }
}

/// Polls `GET /v1/runs/{id}` a few times to reconcile a run whose event stream
/// dropped. Returns the final text + failure flag, or null if nothing resolved.
Future<({String text, bool failed})?> _recoverRunOutput(
  HermesApiService service,
  String runId,
) async {
  for (var attempt = 0; attempt < 4; attempt++) {
    Map<String, dynamic> run;
    try {
      run = await service.getRun(runId);
    } catch (_) {
      run = const {};
    }
    final status = run['status']?.toString();
    final text = _extractRunText(
      run['output'] ?? run['response'] ?? run['message'],
    );
    final terminal =
        status == 'completed' || status == 'failed' || status == 'cancelled';
    if (terminal) return (text: text, failed: status == 'failed');
    if (text.isNotEmpty) return (text: text, failed: false);
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }
  return null;
}

/// Best-effort text extraction from a run's `output` (string, message-item
/// array, or nested content parts).
String _extractRunText(dynamic output) {
  if (output == null) return '';
  if (output is String) return output;
  final buffer = StringBuffer();
  if (output is List) {
    for (final item in output) {
      if (item is String) {
        buffer.write(item);
      } else if (item is Map) {
        final type = item['type']?.toString();
        if (type != null && type.contains('function')) continue;
        buffer.write(_extractRunText(item['content'] ?? item['text']));
      }
    }
  } else if (output is Map) {
    buffer.write(_extractRunText(output['text'] ?? output['content']));
  }
  return buffer.toString();
}

void _handleEvent(
  HermesRunEvent event, {
  required String runId,
  required void Function(String) appendContent,
  required void Function(ChatStatusUpdate) appendStatus,
  required void Function(ChatMessage Function(ChatMessage)) updateMessage,
}) {
  switch (event) {
    case HermesTokenDelta(:final content):
      appendContent(content);

    case HermesReasoningDelta(:final content):
      appendStatus(
        ChatStatusUpdate(
          action: 'reasoning',
          description: 'Thinking… ${_truncate(content)}',
          done: false,
        ),
      );

    case HermesToolProgress(:final toolName, :final done):
      // Stable action+description so start→finish updates the same status line
      // in place (the notifier dedupes on action+description and flips `done`).
      appendStatus(
        ChatStatusUpdate(
          action: 'hermes_tool_$toolName',
          description: toolName,
          done: done,
        ),
      );

    case HermesApprovalRequested(:final approvalId, :final summary):
      updateMessage((m) {
        final meta = Map<String, dynamic>.from(m.metadata ?? const {});
        meta[kHermesApprovalMeta] = {
          'state': 'pending',
          'approvalId': approvalId,
          'runId': runId,
          'summary': ?summary,
        };
        return m.copyWith(metadata: meta);
      });

    case HermesFinalOutput():
      // Captured in the stream listener (appended only if no deltas streamed).
      break;

    case HermesLifecycle():
      // Lifecycle transitions are advisory; terminal ones also emit RunDone.
      break;

    case HermesRunError(:final message):
      updateMessage(
        (m) => m.copyWith(error: ChatMessageError(content: message)),
      );

    case HermesRunDone():
      break;
  }
}

String _truncate(String value, [int max = 120]) =>
    value.length <= max ? value : '${value.substring(0, max)}…';

String _friendlyError(Object e) {
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code != null) return 'Hermes request failed (HTTP $code).';
    return 'Could not reach the Hermes agent. Check the server URL and that it is reachable.';
  }
  return 'Hermes run failed: $e';
}
