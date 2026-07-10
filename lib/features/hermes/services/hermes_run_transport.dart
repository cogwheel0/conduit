import 'dart:async';

import 'package:dio/dio.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/hermes_run_event.dart';
import '../providers/hermes_providers.dart';
import 'hermes_api_service.dart';
import 'hermes_stream_parser.dart';

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
  CancelToken? cancelToken,
  Duration remoteStopTimeout = const Duration(seconds: 5),
  required void Function(String content) appendContent,
  void Function(String content)? replaceContent,
  required void Function(ChatStatusUpdate update) appendStatus,
  required void Function(ChatMessage Function(ChatMessage) updater)
  updateMessage,
  required void Function() finishStreaming,
  required void Function() completeStreamingUi,
}) async {
  final runCancelToken = cancelToken ?? CancelToken();
  final completer = Completer<void>();
  void reportStopFailure() {
    updateMessage(
      (message) => message.copyWith(
        error: const ChatMessageError(
          content:
              'Could not confirm that Hermes stopped this run. It may still '
              'be running on the server.',
        ),
      ),
    );
  }

  if (runCancelToken.isCancelled) {
    finishStreaming();
    completeStreamingUi();
    return;
  }
  registry.registerPending(
    assistantMessageId,
    cancelToken: runCancelToken,
    onCancelled: () {
      if (!completer.isCompleted) completer.complete();
    },
  );

  String runId;
  try {
    runId = await service.createRun(
      input: input,
      sessionId: sessionId,
      previousResponseId: previousResponseId,
      cancelToken: runCancelToken,
    );
  } catch (e, st) {
    registry.complete(assistantMessageId, cancelToken: runCancelToken);
    if (runCancelToken.isCancelled) {
      finishStreaming();
      completeStreamingUi();
      return;
    }
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
    completeStreamingUi();
    return;
  }

  // A Stop/New Chat can race a server that commits the run just before Dio
  // observes cancellation. Stop the newly-known remote id before subscribing.
  if (runCancelToken.isCancelled) {
    finishStreaming();
    completeStreamingUi();
    await _bestEffortStopRemote(
      service,
      runId,
      timeout: remoteStopTimeout,
      onFailure: reportStopFailure,
    );
    registry.complete(assistantMessageId, cancelToken: runCancelToken);
    return;
  }

  // Record transport metadata so the stop path can find this run.
  updateMessage((m) {
    final meta = Map<String, dynamic>.from(m.metadata ?? const {});
    meta['transport'] = kHermesTransport;
    meta['hermesRunId'] = runId;
    return m.copyWith(metadata: meta);
  });

  var sawTerminal = false;
  var gotContent = false;
  var streamedText = '';
  String? finalOutput;
  Object? streamError;

  late final StreamSubscription<HermesRunEvent> sub;
  sub = service
      .runEvents(runId, sessionId: sessionId, cancelToken: runCancelToken)
      .listen(
        (event) {
          if (sawTerminal) return;
          if (event is HermesTokenDelta) {
            gotContent = true;
            streamedText += event.content;
          }
          if (event is HermesFinalOutput) finalOutput = event.text;
          if (event is HermesRunDone || event is HermesRunError) {
            sawTerminal = true;
            if (!completer.isCompleted) completer.complete();
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
          if (!runCancelToken.isCancelled) streamError = e;
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: true,
      );

  final attached = registry.attachRun(
    assistantMessageId,
    cancelToken: runCancelToken,
    runId: runId,
    subscription: sub,
    stopRemote: (runId) => _bestEffortStopRemote(
      service,
      runId,
      timeout: remoteStopTimeout,
      onFailure: reportStopFailure,
    ),
  );
  if (!attached) {
    await sub.cancel();
    finishStreaming();
    completeStreamingUi();
    await _bestEffortStopRemote(
      service,
      runId,
      timeout: remoteStopTimeout,
      onFailure: reportStopFailure,
    );
    return;
  }

  try {
    await completer.future;

    // `run.completed.output` is authoritative. Reconcile a missing terminal
    // suffix even when earlier deltas were received, without duplicating text.
    if (sawTerminal && finalOutput != null && finalOutput!.isNotEmpty) {
      _appendAuthoritativeOutput(
        finalOutput!,
        streamedText: streamedText,
        gotContent: gotContent,
        appendContent: appendContent,
        replaceContent: replaceContent,
      );
    }

    // The events stream ended without a terminal event and the user didn't
    // stop — it likely dropped (network blip / app backgrounded). Reconcile the
    // final result by polling the run instead of leaving the message hung.
    if (!sawTerminal && !runCancelToken.isCancelled) {
      try {
        final recovered = await _recoverRunOutput(
          service,
          runId,
          cancelToken: runCancelToken,
        );
        if (recovered == null) return;
        if (recovered.text.isNotEmpty) {
          _appendAuthoritativeOutput(
            recovered.text,
            streamedText: streamedText,
            gotContent: gotContent,
            appendContent: appendContent,
            replaceContent: replaceContent,
          );
        }
        if (recovered.status != 'completed') {
          final errorMessage = switch (recovered.status) {
            'cancelled' || 'canceled' => 'Hermes run was cancelled.',
            'stopped' => 'Hermes run was stopped.',
            _ => 'Hermes run failed.',
          };
          updateMessage(
            (m) => m.copyWith(error: ChatMessageError(content: errorMessage)),
          );
        }
      } catch (recoveryError, recoveryStack) {
        final error = streamError ?? recoveryError;
        DebugLogger.error(
          'run-stream-error',
          scope: 'hermes/transport',
          error: error,
          stackTrace: recoveryStack,
        );
        updateMessage(
          (m) => m.copyWith(
            error: ChatMessageError(content: _friendlyError(error)),
          ),
        );
      }
    }
  } finally {
    await sub.cancel();
    registry.complete(assistantMessageId, cancelToken: runCancelToken);
    finishStreaming();
    completeStreamingUi();
  }
}

Future<void> _stopRemote(
  HermesApiService service,
  String runId, {
  required Duration timeout,
}) async {
  // The run token is already cancelled in the create/stop race. A fresh token
  // is required or Dio will reject this cleanup request before sending it.
  final stopToken = CancelToken();
  try {
    await service
        .stopRun(runId, cancelToken: stopToken)
        .timeout(
          timeout,
          onTimeout: () {
            stopToken.cancel('Hermes stop request timed out');
            throw TimeoutException('Hermes stop request timed out', timeout);
          },
        );
  } catch (_) {
    if (!stopToken.isCancelled) stopToken.cancel('Hermes stop request failed');
    rethrow;
  }
}

Future<void> _bestEffortStopRemote(
  HermesApiService service,
  String runId, {
  required Duration timeout,
  void Function()? onFailure,
}) async {
  try {
    await _stopRemote(service, runId, timeout: timeout);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'stop-run-cleanup-failed',
      scope: 'hermes/transport',
      error: error,
      stackTrace: stackTrace,
      data: {'runId': runId},
    );
    try {
      onFailure?.call();
    } catch (_) {
      // The owning chat may already have been cleared or disposed. Reporting
      // failure must not turn best-effort remote cleanup into an uncaught error.
    }
  }
}

void _appendAuthoritativeOutput(
  String output, {
  required String streamedText,
  required bool gotContent,
  required void Function(String) appendContent,
  required void Function(String)? replaceContent,
}) {
  if (!gotContent) {
    appendContent(output);
    return;
  }
  if (output.length > streamedText.length && output.startsWith(streamedText)) {
    appendContent(output.substring(streamedText.length));
  } else if (output != streamedText) {
    // Terminal/recovered output is authoritative even when the server corrected
    // or normalized an earlier delta instead of merely extending it.
    replaceContent?.call(output);
  }
}

/// Polls `GET /v1/runs/{id}` until the server reports a terminal state.
///
/// A running run may expose partial output; that is never treated as final. The
/// user can cancel this loop through [cancelToken]. Repeated polling failures
/// become an observable error instead of silently completing a truncated turn.
Future<({String text, String status})?> _recoverRunOutput(
  HermesApiService service,
  String runId, {
  required CancelToken cancelToken,
}) async {
  var consecutiveErrors = 0;
  var malformedResponses = 0;
  while (!cancelToken.isCancelled) {
    Map<String, dynamic> run;
    try {
      run = await service.getRun(runId, cancelToken: cancelToken);
      consecutiveErrors = 0;
    } catch (_) {
      consecutiveErrors++;
      if (consecutiveErrors >= 3) rethrow;
      await Future<void>.delayed(const Duration(seconds: 1));
      continue;
    }
    final status = run['status']?.toString().toLowerCase();
    final text = extractHermesOutputText(
      run['output'] ?? run['response'] ?? run['message'],
    );
    final terminal =
        status == 'completed' ||
        status == 'failed' ||
        status == 'cancelled' ||
        status == 'canceled' ||
        status == 'stopped';
    if (terminal) return (text: text, status: status!);
    const nonTerminalStatuses = {
      'created',
      'queued',
      'pending',
      'running',
      'in_progress',
      'requires_action',
      'waiting',
      'stopping',
    };
    if (status == null || !nonTerminalStatuses.contains(status)) {
      malformedResponses++;
      if (malformedResponses >= 3) {
        throw StateError(
          'Hermes getRun returned an unknown status: ${status ?? '(missing)'}',
        );
      }
    } else {
      malformedResponses = 0;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return null;
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
