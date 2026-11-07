import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/openai_responses_codec.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:conduit_core/utils/sensitive_value_utils.dart';

import 'package:conduit_core/features/hermes/models/hermes_clarify_form.dart';
import 'package:conduit_core/features/hermes/models/hermes_inline_diff.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_stream_parser.dart';

export 'package:conduit_core/features/hermes/services/hermes_identifier.dart'
    show kMaxHermesOpaqueIdentifierCharacters;

/// Metadata key under which Hermes approval state is stored on an assistant
/// [ChatMessage]. The value is a map: `{state, approvalId, runId, summary}`.
const String kHermesApprovalMeta = 'hermesApproval';
const String kHermesDecisionMeta = 'hermesDecision';

/// Transport metadata marker so the stop path can recognize a Hermes run.
const String kHermesTransport = 'hermesRun';

/// Metadata value distinguishing the attachment-capable Responses path from
/// detachable `/v1/runs` while retaining [kHermesTransport] for stop routing.
const String kHermesResponsesMode = 'responses';
const int kMaxHermesProviderErrorCharacters = 512;
const int kMaxHermesToolNameCharacters = 80;
const int kMaxHermesStatusDetailCharacters = 120;
const int kMaxHermesApprovalSummaryCharacters = 512;
const int _maxHermesRecoveryStatusCharacters = 64;
const String _hermesRunQueuedAction = 'hermes_run_queued';

/// Shown while a run Hermes saved during a restart waits for it to return.
const String kHermesRunQueuedMessage =
    'Hermes is restarting. Your message is saved and will run once Hermes '
    'is back, so there is no need to send it again.';

/// Maximum number of status-history rows one Hermes turn may introduce.
///
/// One slot is reserved for coalesced reasoning and one for a terminal
/// overflow summary, leaving the remaining slots for individual tool
/// invocations. Updates and completion for an admitted invocation continue to
/// flow after the limit is reached, while new invocations are summarized.
const int kMaxHermesStatusRowsPerTurn = 64;

/// Drives an attachment-capable Hermes turn over the existing Responses SSE
/// endpoint. The endpoint has no separate stop API; cancelling its request
/// closes the stream, which current Hermes servers use to interrupt the agent.
/// Returns whether Hermes reported a successful terminal response.
///
/// Callers that persist provenance must use this result rather than treating
/// normal Future completion as proof that the request was accepted: transport
/// failures and user cancellation are deliberately converted into message
/// state and do not escape this function as errors.
typedef HermesResponseRecoverer =
    Future<({String text, String status})?> Function(
      String responseId,
      CancelToken cancelToken,
      int maxPolls,
      Duration pollInterval,
    );

/// The recovery status of a turn that ran out of steps and ended with its
/// wrap-up answer: shown with a note, never as a failure.
const String kHermesWrappedUpStatus = 'wrapped_up';

/// Whether a `failed` run [record] (`GET /v1/runs/{id}`) is a turn that ran
/// out of steps and wrote its wrap-up answer, with no error.
bool hermesRunEndedOnBudget(Map<String, dynamic> record) {
  // The stream's rule: `False`, `None`, `0` and `{}` are no error.
  if (hermesErrorIsTruthy(record['error'])) return false;
  final reason = record['turn_exit_reason'];
  return reason is String &&
      (reason.startsWith('budget_exhausted') ||
          reason.startsWith('max_iterations_reached('));
}

/// The status action of a note shown with an answer (a wrap-up, a response
/// that stopped short).
const String kHermesRunNoticeAction = 'hermes_run_notice';

/// Marks a reply whose run Hermes saved during a restart and had not run
/// when polling for it ended: reopening the chat asks for its answer again.
const String kHermesRunAwaitingAnswerKey = 'hermesRunAwaitingAnswer';

/// The status action of the note on such a reply.
const String kHermesRunAwaitingAction = 'hermes_run_awaiting';

/// That note.
const String kHermesRunAwaitingNotice =
    "Hermes hasn't run this message yet. Reopen this chat later to get its "
    'answer.';

/// The note a recovered answer with [status] is shown with: a wrap-up or a
/// stopped-short answer is still the answer. Null for any other status.
String? hermesRecoveredRunNotice(String status) => switch (status) {
  kHermesWrappedUpStatus => kHermesBudgetExhaustedNotice,
  'incomplete' => kHermesIncompleteNotice,
  _ => null,
};

/// The error a recovered run with [status] ended with; null for an answer,
/// including one shown with a note ([hermesRecoveredRunNotice]).
String? hermesRecoveredRunError(String status) =>
    status == 'completed' || hermesRecoveredRunNotice(status) != null
    ? null
    : switch (status) {
        'cancelled' || 'canceled' => 'Hermes run was cancelled.',
        'stopped' => 'Hermes run was stopped.',
        'interrupted' => kHermesRunInterruptedMessage,
        _ => 'Hermes run failed.',
      };

/// How much streamed reasoning a turn keeps to compare with the terminal
/// copy; past it, the terminal copy is not shown.
const int _kMaxReconciledHermesReasoning = 65536;

/// What a terminal response's [terminal] reasoning adds to the [streamed]
/// deltas: the part after them. Items are joined by a newline in the
/// terminal copy and not in the stream, so whitespace is not compared.
/// Null when the stream is not a prefix of it (another projection, such as
/// a summary): nothing is added, rather than repeating what was shown.
@visibleForTesting
String? hermesUnstreamedReasoning(String streamed, String terminal) {
  bool blank(int unit) =>
      unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09;
  var i = 0;
  var j = 0;
  while (j < streamed.length) {
    final s = streamed.codeUnitAt(j);
    if (i < terminal.length && terminal.codeUnitAt(i) == s) {
      i++;
      j++;
    } else if (blank(s)) {
      j++;
    } else if (i < terminal.length && blank(terminal.codeUnitAt(i))) {
      i++;
    } else {
      return null;
    }
  }
  return terminal.substring(i);
}

HermesResponseRecoverer hermesResponseRecoverer(HermesApiService service) =>
    (responseId, cancelToken, maxPolls, pollInterval) => _recoverResponseOutput(
      service,
      responseId,
      cancelToken: cancelToken,
      maxPolls: maxPolls,
      pollInterval: pollInterval,
    );

Future<bool> dispatchHermesTurn({
  required HermesTurnStarter startTurn,
  required Iterable<String> sensitiveValues,
  HermesResponseRecoverer? recoverResponse,
  required HermesRunRegistry registry,
  required String assistantMessageId,
  HermesRunKey? runKey,
  HermesRunKey Function()? currentRunKey,
  CancelToken? cancelToken,
  int maxRecoveryPolls = 120,
  Duration recoveryPollInterval = const Duration(seconds: 1),
  FutureOr<void> Function(String? sessionId)? onSessionEstablished,
  FutureOr<void> Function()? onCompletedSuccessfully,
  void Function(String code)? onSessionRefused,
  required void Function(String content) appendContent,
  void Function(String content)? replaceContent,
  required void Function(ChatStatusUpdate update) appendStatus,
  void Function(String text)? prefillComposer,
  required void Function(ChatMessage Function(ChatMessage) updater)
  updateMessage,
  required void Function() finishStreaming,
  required void Function() completeStreamingUi,
}) async {
  final sensitiveProviderValues = _boundedHermesSensitiveValues(
    sensitiveValues,
  );
  final statusAccumulator = _HermesStatusAccumulator(
    sensitiveValues: sensitiveProviderValues,
    appendStatus: appendStatus,
  );
  HermesRunKey registryKey() =>
      currentRunKey?.call() ?? runKey ?? legacyHermesRunKey(assistantMessageId);
  final responseCancelToken = cancelToken ?? CancelToken();
  final completer = Completer<void>();

  if (responseCancelToken.isCancelled) {
    finishStreaming();
    completeStreamingUi();
    return false;
  }
  registry.registerPending(
    registryKey(),
    cancelToken: responseCancelToken,
    onCancelled: () {
      if (!completer.isCompleted) completer.complete();
      if (!registry.hasReplacement(
        registryKey(),
        cancelToken: responseCancelToken,
      )) {
        finishStreaming();
        completeStreamingUi();
      }
    },
  );

  HermesResponseStream responseStream;
  try {
    responseStream = await startTurn(responseCancelToken);
  } catch (error) {
    final owned = registry.complete(
      registryKey(),
      cancelToken: responseCancelToken,
    );
    if (!owned) return false;
    if (!responseCancelToken.isCancelled) {
      DebugLogger.error(
        'create-response-stream-failed',
        scope: 'hermes/transport',
        data: {'errorType': error.runtimeType.toString()},
      );
      _reportHermesStartFailure(
        error,
        appendStatus: appendStatus,
        updateMessage: updateMessage,
        onSessionRefused: onSessionRefused,
      );
    }
    finishStreaming();
    completeStreamingUi();
    return false;
  }

  if (responseCancelToken.isCancelled) {
    final owned = registry.complete(
      registryKey(),
      cancelToken: responseCancelToken,
    );
    if (owned) {
      finishStreaming();
      completeStreamingUi();
    }
    return false;
  }
  try {
    await onSessionEstablished?.call(
      _validatedHermesOpaqueIdentifier(
        responseStream.sessionId,
        sensitiveValues: sensitiveProviderValues,
      ),
    );
  } catch (_) {
    _signalHermesTransportCancellation(responseCancelToken);
    final owned = registry.complete(
      registryKey(),
      cancelToken: responseCancelToken,
    );
    if (owned) {
      updateMessage(
        (message) => message.copyWith(
          error: const ChatMessageError(
            content: 'Hermes could not safely initialize this session.',
          ),
        ),
      );
      finishStreaming();
      completeStreamingUi();
    }
    return false;
  }
  if (responseCancelToken.isCancelled) {
    final owned = registry.complete(
      registryKey(),
      cancelToken: responseCancelToken,
    );
    if (owned) {
      finishStreaming();
      completeStreamingUi();
    }
    return false;
  }
  updateMessage((message) {
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
    metadata['transport'] = kHermesTransport;
    metadata['hermesTransportMode'] = kHermesResponsesMode;
    return message.copyWith(metadata: metadata);
  });

  var sawTerminal = false;
  var completedSuccessfully = false;
  var gotContent = false;
  // Reasoning streamed as deltas, bounded: a terminal response repeats it.
  final streamedReasoning = StringBuffer();
  var streamedReasoningOverflowed = false;
  final streamedText = StringBuffer();
  String? finalOutput;
  String? responseId;
  Object? streamError;

  late final StreamSubscription<HermesRunEvent> subscription;
  subscription = responseStream.events.listen(
    (event) {
      // A queued server cancellation frame may race Conduit's own Stop. Once
      // the owner has cancelled this token, transport teardown is silent and
      // no later provider event may turn that user action into a message error.
      if (sawTerminal || responseCancelToken.isCancelled) return;
      // A terminal response repeats its reasoning items: only what the
      // deltas did not already show is added.
      if (event is HermesReasoningDelta) {
        if (!event.terminal) {
          if (streamedReasoning.length + event.content.length >
              _kMaxReconciledHermesReasoning) {
            streamedReasoningOverflowed = true;
          } else {
            streamedReasoning.write(event.content);
          }
        } else if (streamedReasoningOverflowed) {
          return;
        } else if (streamedReasoning.isNotEmpty) {
          final rest = hermesUnstreamedReasoning(
            streamedReasoning.toString(),
            event.content,
          );
          if (rest == null || rest.trim().isEmpty) return;
          event = HermesReasoningDelta(rest);
        }
      }
      switch (event) {
        case HermesTokenDelta(:final content):
          gotContent = true;
          streamedText.write(content);
        case HermesFinalOutput(:final text):
          finalOutput = text;
        case HermesComposerPrefill(:final text):
          prefillComposer?.call(text);
        case HermesResponseCreated(:final responseId):
          final announcedId = _validatedHermesOpaqueIdentifier(
            responseId,
            sensitiveValues: sensitiveProviderValues,
          );
          if (announcedId != null) {
            updateMessage((message) {
              final metadata = Map<String, dynamic>.from(
                message.metadata ?? const {},
              );
              metadata['hermesResponseId'] = announcedId;
              return message.copyWith(metadata: metadata);
            });
          }
        case HermesRunDone():
          sawTerminal = true;
          completedSuccessfully = true;
          if (!completer.isCompleted) completer.complete();
        case HermesRunError():
          sawTerminal = true;
          if (!completer.isCompleted) completer.complete();
        default:
          break;
      }
      if (event is HermesResponseCreated) {
        responseId = _validatedHermesOpaqueIdentifier(
          event.responseId,
          sensitiveValues: sensitiveProviderValues,
        );
      }
      var eventRunId = responseId;
      if (event case HermesApprovalRequested(:final raw)) {
        final rawRunId = raw.containsKey('run_id') ? raw['run_id'] : responseId;
        eventRunId = _validatedHermesOpaqueIdentifier(
          rawRunId is String ? rawRunId : null,
          sensitiveValues: sensitiveProviderValues,
        );
        if (eventRunId != null &&
            !registry.bindRunId(
              registryKey(),
              cancelToken: responseCancelToken,
              runId: eventRunId,
            )) {
          eventRunId = null;
        }
      }
      _handleEvent(
        event,
        runId: eventRunId,
        storedSessionId: responseStream.sessionId,
        sensitiveValues: sensitiveProviderValues,
        appendContent: appendContent,
        appendStatus: statusAccumulator.appendStatus,
        appendReasoning: statusAccumulator.appendReasoning,
        updateMessage: updateMessage,
      );
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!responseCancelToken.isCancelled ||
          _isActiveHermesProtocolFailure(error, responseCancelToken)) {
        streamError = error;
      }
      if (!completer.isCompleted) completer.complete();
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete();
    },
    cancelOnError: true,
  );

  final attached = registry.attachStream(
    registryKey(),
    cancelToken: responseCancelToken,
    subscription: subscription,
  );
  if (!attached) {
    // attachStream already starts detached cancellation for a stale owner.
    return false;
  }

  try {
    await completer.future;
    if (sawTerminal && finalOutput != null && finalOutput!.isNotEmpty) {
      _appendAuthoritativeOutput(
        finalOutput!,
        streamedText: streamedText.toString(),
        gotContent: gotContent,
        appendContent: appendContent,
        replaceContent: replaceContent,
      );
    }

    if (!sawTerminal &&
        (!responseCancelToken.isCancelled ||
            _isActiveHermesProtocolFailure(streamError, responseCancelToken))) {
      try {
        final guardedError = streamError;
        if (_isHermesProtocolFailure(guardedError)) throw guardedError!;
        if (responseId == null) {
          throw streamError ??
              StateError('Hermes Responses stream ended before it started.');
        }
        if (recoverResponse == null) {
          throw streamError ??
              StateError(
                'Hermes Desktop stream ended without a terminal event.',
              );
        }
        final recovered = await recoverResponse(
          responseId!,
          responseCancelToken,
          maxRecoveryPolls,
          recoveryPollInterval,
        );
        if (recovered == null) return false;
        if (recovered.text.isNotEmpty) {
          _appendAuthoritativeOutput(
            recovered.text,
            streamedText: streamedText.toString(),
            gotContent: gotContent,
            appendContent: appendContent,
            replaceContent: replaceContent,
          );
        }
        // Hermes marks a turn that stopped short as incomplete; its text is
        // still the answer, shown with a note rather than as a failure.
        final incomplete = recovered.status == 'incomplete';
        completedSuccessfully = recovered.status == 'completed' || incomplete;
        if (incomplete) {
          statusAccumulator.appendStatus(
            const ChatStatusUpdate(
              action: kHermesRunNoticeAction,
              description: kHermesIncompleteNotice,
              done: true,
            ),
          );
        } else if (!completedSuccessfully) {
          updateMessage(
            (message) => message.copyWith(
              error: const ChatMessageError(content: 'Hermes response failed.'),
            ),
          );
        }
      } catch (error) {
        final failure = _isHermesProtocolFailure(error)
            ? error
            : (streamError ?? error);
        if (responseCancelToken.isCancelled &&
            !_isActiveHermesProtocolFailure(failure, responseCancelToken)) {
          return false;
        }
        DebugLogger.error('response-stream-error', scope: 'hermes/transport');
        updateMessage(
          (message) => message.copyWith(
            error: ChatMessageError(content: _friendlyError(failure)),
          ),
        );
      }
    }
    if (completedSuccessfully && !responseCancelToken.isCancelled) {
      await onCompletedSuccessfully?.call();
      if (responseCancelToken.isCancelled) completedSuccessfully = false;
    }
  } finally {
    _signalHermesTransportCancellation(responseCancelToken);
    _cancelHermesTransportSubscription(
      subscription,
      message: 'response-subscription-cleanup-failed',
    );
    final owned = registry.complete(
      registryKey(),
      cancelToken: responseCancelToken,
    );
    if (owned) {
      finishStreaming();
      completeStreamingUi();
    }
  }
  return completedSuccessfully;
}

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
  HermesRunKey? runKey,
  HermesRunKey Function()? currentRunKey,
  required String input,
  String? sessionId,
  String? previousResponseId,
  List<Map<String, dynamic>>? conversationHistory,
  String? reasoningEffort,
  CancelToken? cancelToken,
  Duration remoteStopTimeout = const Duration(seconds: 5),
  int maxRecoveryPolls = 120,
  Duration recoveryPollInterval = const Duration(seconds: 1),
  int maxQueuedPolls = 180,
  Duration queuedPollInterval = const Duration(seconds: 10),
  int maxStreamResumes = 3,
  Duration streamResumeDelay = const Duration(seconds: 1),
  int maxExtendedRecoveryPolls = 300,
  Duration extendedRecoveryPollInterval = const Duration(seconds: 5),
  required void Function(String content) appendContent,
  void Function(String content)? replaceContent,
  required void Function(ChatStatusUpdate update) appendStatus,
  required void Function(ChatMessage Function(ChatMessage) updater)
  updateMessage,
  void Function(ChatMessageError error)? reportStopError,
  void Function(String code)? onSessionRefused,
  required void Function() finishStreaming,
  required void Function() completeStreamingUi,
}) async {
  final sensitiveProviderValues = _hermesSensitiveValues(service);
  final statusAccumulator = _HermesStatusAccumulator(
    sensitiveValues: sensitiveProviderValues,
    appendStatus: appendStatus,
  );
  HermesRunKey registryKey() =>
      currentRunKey?.call() ?? runKey ?? legacyHermesRunKey(assistantMessageId);
  final runCancelToken = cancelToken ?? CancelToken();
  final completer = Completer<void>();
  void reportStopFailure() {
    const error = ChatMessageError(
      content:
          'Could not confirm that Hermes stopped this run. It may still '
          'be running on the server.',
    );
    final report = reportStopError;
    if (report != null) {
      report(error);
    } else {
      updateMessage((message) => message.copyWith(error: error));
    }
  }

  if (runCancelToken.isCancelled) {
    finishStreaming();
    completeStreamingUi();
    return;
  }
  registry.registerPending(
    registryKey(),
    cancelToken: runCancelToken,
    onCancelled: () {
      if (!completer.isCompleted) completer.complete();
      if (!registry.hasReplacement(
        registryKey(),
        cancelToken: runCancelToken,
      )) {
        finishStreaming();
        completeStreamingUi();
      }
    },
  );

  String runId;
  try {
    final announcedRunId = await service.createRunWithReasoning(
      input: input,
      sessionId: sessionId,
      previousResponseId: previousResponseId,
      conversationHistory: conversationHistory,
      reasoningEffort: reasoningEffort,
      cancelToken: runCancelToken,
    );
    runId =
        _validatedHermesOpaqueIdentifier(
          announcedRunId,
          sensitiveValues: sensitiveProviderValues,
        ) ??
        (throw const FormatException('Hermes returned an invalid run id'));
  } catch (e) {
    final owned = registry.complete(registryKey(), cancelToken: runCancelToken);
    if (!owned) return;
    if (runCancelToken.isCancelled &&
        !_isActiveHermesProtocolFailure(e, runCancelToken)) {
      finishStreaming();
      completeStreamingUi();
      return;
    }
    DebugLogger.error('create-run-failed', scope: 'hermes/transport');
    _reportHermesStartFailure(
      e,
      appendStatus: appendStatus,
      updateMessage: updateMessage,
      onSessionRefused: onSessionRefused,
    );
    finishStreaming();
    completeStreamingUi();
    return;
  }

  // A Stop/New Chat can race a server that commits the run just before Dio
  // observes cancellation. Stop the newly-known remote id before subscribing.
  if (runCancelToken.isCancelled) {
    if (!registry.hasReplacement(registryKey(), cancelToken: runCancelToken)) {
      finishStreaming();
      completeStreamingUi();
    }
    await _bestEffortStopRemote(
      service,
      runId,
      timeout: remoteStopTimeout,
      onFailure: reportStopFailure,
    );
    registry.complete(registryKey(), cancelToken: runCancelToken);
    return;
  }

  // The event request has narrower ownership than the durable run. A local
  // SSE guard must be able to tear down its socket without poisoning the
  // caller-owned token that also cancels bounded checkpoint recovery.
  final eventCancelToken = CancelToken();
  unawaited(
    runCancelToken.whenCancel.then<void>((_) {
      if (!eventCancelToken.isCancelled) {
        eventCancelToken.cancel('Hermes run stopped');
      }
    }),
  );

  // Record transport metadata so the stop path can find this run.
  updateMessage((m) {
    final meta = Map<String, dynamic>.from(m.metadata ?? const {});
    meta['transport'] = kHermesTransport;
    meta['hermesRunId'] = runId;
    return m.copyWith(metadata: meta);
  });

  var sawTerminal = false;
  var gotContent = false;
  // Hermes v0.23 sends `run.queued` and closes the stream when it restarts
  // before the run starts; the input is saved and runs once it is back.
  var queuedForRestart = false;
  final streamedText = StringBuffer();
  String? finalOutput;
  Object? streamError;

  late final StreamSubscription<HermesRunEvent> sub;
  sub =
      _resumableHermesRunEvents(
        service,
        runId,
        sessionId: sessionId,
        cancelToken: eventCancelToken,
        maxResumes: maxStreamResumes,
        resumeDelay: streamResumeDelay,
      ).listen(
        (event) {
          // A queued run.cancelled/run.stopped frame may race Conduit's own
          // Stop. The cancelled owner is authoritative, so discard all later
          // provider events while ordinary remote cancellation (with a live
          // token) still surfaces as a terminal error.
          if (sawTerminal || runCancelToken.isCancelled) return;
          if (event is HermesTokenDelta) {
            gotContent = true;
            streamedText.write(event.content);
          }
          if (event is HermesFinalOutput) finalOutput = event.text;
          if (event is HermesLifecycle) {
            queuedForRestart = event.status == 'queued';
          }
          if (event is HermesRunDone || event is HermesRunError) {
            sawTerminal = true;
            if (!completer.isCompleted) completer.complete();
          }
          _handleEvent(
            event,
            runId: runId,
            storedSessionId: null,
            sensitiveValues: sensitiveProviderValues,
            appendContent: appendContent,
            appendStatus: statusAccumulator.appendStatus,
            appendReasoning: statusAccumulator.appendReasoning,
            updateMessage: updateMessage,
          );
        },
        onError: (Object e, StackTrace st) {
          if (!runCancelToken.isCancelled ||
              _isActiveHermesProtocolFailure(e, runCancelToken)) {
            streamError = e;
          }
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: true,
      );

  final attached = registry.attachRun(
    registryKey(),
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
    // attachRun already starts detached cancellation for a stale owner.
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
        streamedText: streamedText.toString(),
        gotContent: gotContent,
        appendContent: appendContent,
        replaceContent: replaceContent,
      );
    }

    // The events stream ended without a terminal event and the user didn't
    // stop. Ordinary drops use bounded polling; a semantic idle timeout gets
    // one authoritative checkpoint lookup before its error is shown.
    if (!sawTerminal &&
        (!runCancelToken.isCancelled ||
            _isActiveHermesProtocolFailure(streamError, runCancelToken))) {
      try {
        final guardedError = streamError;
        final allowsCheckpointRecovery = _allowsHermesCheckpointRecovery(
          guardedError,
        );
        if (_isHermesProtocolFailure(guardedError) &&
            !allowsCheckpointRecovery) {
          throw guardedError!;
        }
        final waitingForRestart = queuedForRestart && guardedError == null;
        void showQueued({required bool done}) {
          statusAccumulator.appendStatus(
            ChatStatusUpdate(
              action: _hermesRunQueuedAction,
              description: kHermesRunQueuedMessage,
              done: done,
            ),
          );
        }

        // A run saved during a restart cannot resume its stream, and a
        // stream can drop for good: the poll lists what is still open. A
        // reply holds one approval card and one question card; the first of
        // each kind is shown, and a shown one that is no longer listed
        // (answered here or elsewhere, timed out, withdrawn, or the run
        // ended) is closed, which makes room for the next. None is shown
        // twice.
        final shownControls = <String, String>{};
        final closedControls = <String>{};
        void handle(HermesRunEvent event) => _handleEvent(
          event,
          runId: runId,
          storedSessionId: null,
          sensitiveValues: sensitiveProviderValues,
          appendContent: appendContent,
          appendStatus: statusAccumulator.appendStatus,
          appendReasoning: statusAccumulator.appendReasoning,
          updateMessage: updateMessage,
        );
        ({String kind, String id})? control(HermesRunEvent event) =>
            switch (event) {
              HermesApprovalRequested(:final approvalId) => (
                kind: 'approval',
                id: approvalId,
              ),
              HermesDecisionRequested(:final requestId) => (
                kind: 'clarify',
                id: requestId,
              ),
              _ => null,
            };
        void showPendingControls(List<HermesRunEvent> events) {
          if (runCancelToken.isCancelled) return;
          final listed = {for (final event in events) ?control(event)?.id};
          for (final MapEntry(key: kind, value: id) in [
            ...shownControls.entries,
          ]) {
            if (listed.contains(id)) continue;
            shownControls.remove(kind);
            closedControls.add(id);
            handle(HermesPromptSettled(promptId: id, kind: kind));
          }
          for (final event in events) {
            final open = control(event);
            if (open == null ||
                closedControls.contains(open.id) ||
                shownControls.containsKey(open.kind)) {
              continue;
            }
            shownControls[open.kind] = open.id;
            handle(event);
          }
        }

        ({String text, String status})? recovered;
        if (waitingForRestart) {
          // Not an error: poll slowly, tolerating the restart's outage. If
          // Hermes stays away, the saved input still runs once it is back.
          showQueued(done: false);
          try {
            recovered = await _recoverRunOutput(
              service,
              runId,
              cancelToken: runCancelToken,
              maxPolls: maxQueuedPolls,
              pollInterval: queuedPollInterval,
              maxConsecutiveErrors: maxQueuedPolls,
              onPendingControls: showPendingControls,
            );
          } catch (error) {
            if (_isHermesProtocolFailure(error)) rethrow;
            recovered = null;
          }
          if (!runCancelToken.isCancelled) showQueued(done: true);
        } else {
          recovered = await _recoverRunOutput(
            service,
            runId,
            cancelToken: runCancelToken,
            maxPolls: allowsCheckpointRecovery ? 1 : maxRecoveryPolls,
            pollInterval: allowsCheckpointRecovery
                ? Duration.zero
                : recoveryPollInterval,
            // A long tool-heavy run can outlive the quick polling budget;
            // keep checking, more slowly, while Hermes says it is active.
            maxExtendedPolls: allowsCheckpointRecovery
                ? 0
                : maxExtendedRecoveryPolls,
            extendedPollInterval: extendedRecoveryPollInterval,
            onPendingControls: showPendingControls,
          );
        }
        if (recovered == null) {
          // Still saved for after the restart: the reply keeps its run, and
          // reopening the chat asks for the answer again.
          if (waitingForRestart && !runCancelToken.isCancelled) {
            updateMessage((m) {
              final metadata = Map<String, dynamic>.from(
                m.metadata ?? const {},
              );
              metadata[kHermesRunAwaitingAnswerKey] = true;
              return m.copyWith(metadata: metadata);
            });
            statusAccumulator.appendStatus(
              const ChatStatusUpdate(
                action: kHermesRunAwaitingAction,
                description: kHermesRunAwaitingNotice,
                done: true,
              ),
            );
          }
          return;
        }
        if (runCancelToken.isCancelled) return;
        if (recovered.text.isNotEmpty) {
          _appendAuthoritativeOutput(
            recovered.text,
            streamedText: streamedText.toString(),
            gotContent: gotContent,
            appendContent: appendContent,
            replaceContent: replaceContent,
          );
        }
        // A wrap-up or a stopped-short answer is still the answer: shown with
        // a note, as its stream would have.
        final notice = hermesRecoveredRunNotice(recovered.status);
        final errorMessage = hermesRecoveredRunError(recovered.status);
        if (notice != null) {
          statusAccumulator.appendStatus(
            ChatStatusUpdate(
              action: kHermesRunNoticeAction,
              description: notice,
              done: true,
            ),
          );
        } else if (errorMessage != null) {
          updateMessage(
            (m) => m.copyWith(error: ChatMessageError(content: errorMessage)),
          );
        }
      } catch (recoveryError) {
        final error = _isHermesProtocolFailure(recoveryError)
            ? recoveryError
            : (streamError ?? recoveryError);
        if (runCancelToken.isCancelled &&
            !_isActiveHermesProtocolFailure(error, runCancelToken)) {
          return;
        }
        DebugLogger.error('run-stream-error', scope: 'hermes/transport');
        updateMessage(
          (m) => m.copyWith(
            error: ChatMessageError(content: _friendlyError(error)),
          ),
        );
      }
    }
  } finally {
    _signalHermesTransportCancellation(eventCancelToken);
    _signalHermesTransportCancellation(runCancelToken);
    _cancelHermesTransportSubscription(
      sub,
      message: 'run-subscription-cleanup-failed',
    );
    final owned = registry.complete(registryKey(), cancelToken: runCancelToken);
    if (owned) {
      finishStreaming();
      completeStreamingUi();
    }
  }
}

/// Shows why Hermes refused to start a turn. A saved-and-queued input is not
/// an error: it runs once Hermes is back and must not be resent.
void _reportHermesStartFailure(
  Object error, {
  required void Function(ChatStatusUpdate update) appendStatus,
  required void Function(ChatMessage Function(ChatMessage) updater)
  updateMessage,
  void Function(String code)? onSessionRefused,
}) {
  if (error is HermesApiException &&
      error.code == HermesApiErrorCode.admissionQueued) {
    appendStatus(
      ChatStatusUpdate(
        action: _hermesRunQueuedAction,
        description: hermesApiRefusalMessage(error),
        done: true,
      ),
    );
    return;
  }
  updateMessage(
    (m) => m.copyWith(error: ChatMessageError(content: _friendlyError(error))),
  );
  final code = error is HermesApiException ? error.code : null;
  if (code == HermesApiErrorCode.permissionDenied ||
      code == HermesApiErrorCode.notFound) {
    try {
      onSessionRefused?.call(code!);
    } catch (_) {
      DebugLogger.error(
        'session-refusal-callback-failed',
        scope: 'hermes/transport',
      );
    }
  }
}

void _signalHermesTransportCancellation(CancelToken cancelToken) {
  if (!cancelToken.isCancelled) {
    cancelToken.cancel('Hermes transport finished');
  }
}

void _cancelHermesTransportSubscription<T>(
  StreamSubscription<T> subscription, {
  required String message,
}) {
  void logFailure() {
    // The provider owns both the rejection object and its stack. Keep
    // diagnostics fixed so reflected credentials never enter local logs.
    DebugLogger.error(message, scope: 'hermes/transport');
  }

  try {
    unawaited(
      subscription.cancel().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) => logFailure(),
      ),
    );
  } catch (_) {
    logFailure();
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
  } catch (_) {
    // Remote cleanup failures and stacks are provider-controlled and can
    // reflect credentials. Record only the fixed cleanup site.
    DebugLogger.error('stop-run-cleanup-failed', scope: 'hermes/transport');
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
    // An authoritative output that is a strict prefix of the streamed text is
    // a lagging aggregate (multi-item runs, incomplete recovery) — replacing
    // with it would truncate content the user already received. Keep the
    // longer streamed text in that case.
    if (isStaleServerPrefix(localBody: streamedText, serverBody: output)) {
      return;
    }
    // Terminal/recovered output is authoritative even when the server corrected
    // or normalized an earlier delta instead of merely extending it.
    replaceContent?.call(output);
  }
}

/// Reconciles a durable Hermes checkpoint after the process-local transport
/// registry has been lost. Identifiers are validated against the active
/// connection's secrets before they can reach a provider URL.
Future<({String text, String status})?> recoverHermesCheckpoint({
  required HermesApiService service,
  String? runId,
  String? responseId,
  String? transportMode,
  required CancelToken cancelToken,
  int maxPolls = 120,
  Duration pollInterval = const Duration(seconds: 1),
}) {
  final sensitiveValues = _hermesSensitiveValues(service);
  final safeRunId = _validatedHermesOpaqueIdentifier(
    runId,
    sensitiveValues: sensitiveValues,
  );
  final safeResponseId = _validatedHermesOpaqueIdentifier(
    responseId,
    sensitiveValues: sensitiveValues,
  );
  if (runId != null && safeRunId == null) {
    throw StateError('Hermes checkpoint contains an invalid run identifier.');
  }
  if (responseId != null && safeResponseId == null) {
    throw StateError(
      'Hermes checkpoint contains an invalid response identifier.',
    );
  }
  if (transportMode == kHermesResponsesMode) {
    if (safeResponseId == null) {
      return Future.value(null);
    }
    return _recoverResponseOutput(
      service,
      safeResponseId,
      cancelToken: cancelToken,
      maxPolls: maxPolls,
      pollInterval: pollInterval,
    );
  }
  if (safeRunId == null) {
    return Future.value(null);
  }
  return _recoverRunOutput(
    service,
    safeRunId,
    cancelToken: cancelToken,
    maxPolls: maxPolls,
    pollInterval: pollInterval,
  );
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
  required int maxPolls,
  required Duration pollInterval,
  int maxConsecutiveErrors = 3,
  int maxExtendedPolls = 0,
  Duration extendedPollInterval = const Duration(seconds: 5),
  void Function(List<HermesRunEvent> events)? onPendingControls,
}) async {
  if (maxPolls <= 0) {
    throw ArgumentError.value(maxPolls, 'maxPolls', 'Must be positive');
  }
  var consecutiveErrors = 0;
  var resolveErrors = 0;
  var malformedResponses = 0;
  var polls = 0;
  var pollBudget = maxPolls;
  var resolvedUnknown = false;
  var lastStatusActive = false;
  while (!cancelToken.isCancelled) {
    if (polls >= pollBudget &&
        (!lastStatusActive || polls >= pollBudget + maxExtendedPolls)) {
      throw TimeoutException(
        'Hermes run did not reach a terminal state after $polls polls',
      );
    }
    polls++;
    Map<String, dynamic> run;
    try {
      run = await service.getRun(runId, cancelToken: cancelToken);
      if (cancelToken.isCancelled) return null;
      consecutiveErrors = 0;
    } catch (error) {
      // Recovery decoding deliberately cancels the shared token when a peer
      // exceeds a resource limit or sends malformed data. Preserve that local
      // protocol failure instead of mistaking it for an external Stop action.
      if (_isHermesProtocolFailure(error)) rethrow;
      if (cancelToken.isCancelled) return null;
      consecutiveErrors++;
      if (consecutiveErrors >= maxConsecutiveErrors) rethrow;
      await Future<void>.delayed(pollInterval);
      continue;
    }
    final status = _hermesRecoveryStatus(run['status']);
    final text = _extractBoundedHermesRecoveryOutput(
      run['output'] ?? run['response'] ?? run['message'],
      maxCharacters: service.streamLimits.maxCharacters,
    );
    final terminal =
        status == 'completed' ||
        status == 'failed' ||
        status == 'cancelled' ||
        status == 'canceled' ||
        status == 'stopped' ||
        status == 'incomplete' ||
        status == 'interrupted';
    if (terminal) {
      // A finished run asks nothing more: the cards still open close.
      onPendingControls?.call(const <HermesRunEvent>[]);
      // A turn that ran out of steps is `failed` with its wrap-up answer and
      // no error, as its stream's `run.failed` is: a note, not a failure.
      if (status == 'failed' && hermesRunEndedOnBudget(run)) {
        return (text: text, status: kHermesWrappedUpStatus);
      }
      return (text: text, status: status!);
    }
    // Approvals and questions asked while no stream was attached.
    onPendingControls?.call(
      hermesPendingControlEvents(run['pending_controls']),
    );
    if (status == 'unknown' && !resolvedUnknown) {
      // An unclean Hermes restart left this run's outcome unknown, and the
      // session's later turns wait behind it until a client acknowledges it.
      final Map<String, dynamic>? receipt;
      try {
        receipt = await _resolveUnknownHermesRun(
          service,
          runId,
          run,
          cancelToken: cancelToken,
        );
      } catch (error) {
        if (_isHermesProtocolFailure(error)) rethrow;
        if (cancelToken.isCancelled) return null;
        // Hermes replays the receipt to an exact retry, so a dropped
        // acknowledgement is retried on the next poll that still sees it.
        resolveErrors++;
        if (resolveErrors >= maxConsecutiveErrors || polls >= pollBudget) {
          rethrow;
        }
        await Future<void>.delayed(pollInterval);
        continue;
      }
      if (cancelToken.isCancelled) return null;
      if (receipt != null) {
        resolvedUnknown = true;
        // A turn that finished before the restart commits its own answer;
        // the next poll reads it, even past the last one. Anything else was
        // interrupted.
        if (receipt['outcome'] != 'completed') {
          return (text: text, status: 'interrupted');
        }
        if (polls >= pollBudget) pollBudget = polls + 1;
        continue;
      }
    }
    const nonTerminalStatuses = {
      'created',
      'queued',
      'pending',
      'started',
      'running',
      'in_progress',
      'requires_action',
      'waiting',
      'waiting_for_approval',
      'stopping',
      'unknown',
    };
    if (status == null || !nonTerminalStatuses.contains(status)) {
      malformedResponses++;
      lastStatusActive = false;
      if (malformedResponses >= 3) {
        throw StateError(
          'Hermes getRun returned an unknown status: ${status ?? '(missing)'}',
        );
      }
    } else {
      malformedResponses = 0;
      lastStatusActive = status != 'unknown';
    }
    if (polls < pollBudget) {
      await Future<void>.delayed(pollInterval);
    } else if (lastStatusActive && polls < pollBudget + maxExtendedPolls) {
      await Future<void>.delayed(
        extendedPollInterval > pollInterval
            ? extendedPollInterval
            : pollInterval,
      );
    }
  }
  return null;
}

/// Follows a run's event stream across drops.
///
/// Hermes v0.21.7+ numbers run events (`seq`) and detaches a slow subscriber
/// by simply ending its stream. When a stream ends early, or a connection
/// error cuts it, this reconnects with `Last-Event-ID` and Hermes replays the
/// missed events. Servers without `seq`, a run Hermes no longer streams
/// (404), a run saved during a restart (`run.queued`), and [maxResumes]
/// attempts without new events all end the stream so the caller polls.
Stream<HermesRunEvent> _resumableHermesRunEvents(
  HermesApiService service,
  String runId, {
  required String? sessionId,
  required CancelToken cancelToken,
  required int maxResumes,
  required Duration resumeDelay,
}) {
  // A controller rather than `await for`: cancelling the returned stream must
  // reach the live connection at once (Stop, account revocation), not at the
  // connection's next event.
  late final StreamController<HermesRunEvent> controller;
  StreamSubscription<HermesRunEvent>? connection;
  int? lastSeq;
  var attemptsWithoutProgress = 0;
  var totalResumes = 0;
  var closed = false;

  void close() {
    if (closed) return;
    closed = true;
    unawaited(controller.close());
  }

  late void Function() connect;

  void connectionEnded({
    required int? resumeFrom,
    required HermesRunEvent? lastEvent,
    Object? error,
    StackTrace? stackTrace,
  }) {
    connection = null;
    if (closed) return;
    if (error != null) {
      // Hermes forgets a run's stream a while after it ends (404); polling
      // still reads the run.
      final gone = error is DioException && error.response?.statusCode == 404;
      final protocolFailure = _isHermesProtocolFailure(error);
      final resumable =
          !gone &&
          !protocolFailure &&
          !cancelToken.isCancelled &&
          lastSeq != null;
      if (!resumable) {
        // A failed resume falls back to polling; the first connection's own
        // failure keeps its existing handling.
        if (resumeFrom == null || protocolFailure) {
          controller.addError(error, stackTrace);
        }
        close();
        return;
      }
    }
    final seq = lastSeq;
    if (cancelToken.isCancelled ||
        seq == null ||
        (lastEvent is HermesLifecycle && lastEvent.status == 'queued')) {
      close();
      return;
    }
    attemptsWithoutProgress = seq == resumeFrom
        ? attemptsWithoutProgress + 1
        : 0;
    totalResumes++;
    if (attemptsWithoutProgress >= maxResumes ||
        totalResumes > _maxHermesRunStreamResumes) {
      close();
      return;
    }
    unawaited(
      Future<void>.delayed(resumeDelay).then((_) {
        if (closed || cancelToken.isCancelled) {
          close();
        } else {
          connect();
        }
      }),
    );
  }

  connect = () {
    final resumeFrom = lastSeq;
    HermesRunEvent? lastEvent;
    try {
      connection = service
          .runEvents(
            runId,
            sessionId: sessionId,
            cancelToken: cancelToken,
            lastEventId: resumeFrom,
            onSequence: (seq) {
              final current = lastSeq;
              if (current == null || seq > current) lastSeq = seq;
            },
          )
          .listen(
            (event) {
              if (closed) return;
              lastEvent = event;
              controller.add(event);
              if (event is HermesRunDone || event is HermesRunError) {
                final finished = connection;
                connection = null;
                if (finished != null) {
                  _cancelHermesTransportSubscription(
                    finished,
                    message: 'run-subscription-cleanup-failed',
                  );
                }
                close();
              }
            },
            onError: (Object error, StackTrace stackTrace) => connectionEnded(
              resumeFrom: resumeFrom,
              lastEvent: lastEvent,
              error: error,
              stackTrace: stackTrace,
            ),
            onDone: () =>
                connectionEnded(resumeFrom: resumeFrom, lastEvent: lastEvent),
            cancelOnError: true,
          );
      if (controller.isPaused) connection?.pause();
    } catch (error, stackTrace) {
      connectionEnded(
        resumeFrom: resumeFrom,
        lastEvent: lastEvent,
        error: error,
        stackTrace: stackTrace,
      );
    }
  };

  controller = StreamController<HermesRunEvent>(
    onListen: () => connect(),
    onPause: () => connection?.pause(),
    onResume: () => connection?.resume(),
    onCancel: () {
      closed = true;
      final live = connection;
      connection = null;
      return live?.cancel();
    },
  );
  return controller.stream;
}

const int _maxHermesRunStreamResumes = 50;

/// Sends `resolve-unknown` for [run] when it reports the exact admission
/// identity Hermes requires. Returns the receipt, or null when [run] does not
/// carry that identity (older servers never report `unknown`).
Future<Map<String, dynamic>?> _resolveUnknownHermesRun(
  HermesApiService service,
  String runId,
  Map<String, dynamic> run, {
  required CancelToken cancelToken,
}) async {
  final admissionId = validateHermesOpaqueIdentifier(
    run['admission_id'],
    sensitiveValues: _hermesSensitiveValues(service),
  );
  final generation = run['execution_generation'];
  if (admissionId == null || generation is! int || generation < 0) {
    return null;
  }
  return service.resolveUnknownRun(
    runId,
    admissionId: admissionId,
    executionGeneration: generation,
    cancelToken: cancelToken,
  );
}

/// Before a new turn joins a session, acknowledges the session's previous
/// run when a Hermes restart left its outcome unknown. Hermes v0.22.1+ holds
/// every later turn in that session until this is done.
///
/// Best effort: returns whether a run was acknowledged and never throws.
Future<bool> settleUnknownHermesRun(
  HermesApiService service,
  String runId, {
  CancelToken? cancelToken,
}) async {
  final safeRunId = _validatedHermesOpaqueIdentifier(
    runId,
    sensitiveValues: _hermesSensitiveValues(service),
  );
  if (safeRunId == null) return false;
  // getRun shares a recovery deadline per token; keep this check's own.
  final checkToken = CancelToken();
  void cancelCheck(Object? _) {
    if (!checkToken.isCancelled) checkToken.cancel('Hermes turn cancelled');
  }

  unawaited(cancelToken?.whenCancel.then<void>(cancelCheck));
  try {
    final run = await service.getRun(safeRunId, cancelToken: checkToken);
    if (_hermesRecoveryStatus(run['status']) != 'unknown') return false;
    final receipt = await _resolveUnknownHermesRun(
      service,
      safeRunId,
      run,
      cancelToken: checkToken,
    );
    return receipt != null;
  } catch (_) {
    DebugLogger.warning('settle-unknown-run-failed', scope: 'hermes/transport');
    return false;
  } finally {
    _signalHermesTransportCancellation(checkToken);
  }
}

Future<({String text, String status})?> _recoverResponseOutput(
  HermesApiService service,
  String responseId, {
  required CancelToken cancelToken,
  required int maxPolls,
  required Duration pollInterval,
}) async {
  if (maxPolls <= 0) {
    throw ArgumentError.value(maxPolls, 'maxPolls', 'Must be positive');
  }
  var consecutiveErrors = 0;
  var polls = 0;
  while (!cancelToken.isCancelled) {
    if (polls >= maxPolls) {
      throw TimeoutException(
        'Hermes response remained pending after $maxPolls polls',
      );
    }
    polls++;
    Map<String, dynamic> response;
    try {
      response = await service.getResponse(
        responseId,
        cancelToken: cancelToken,
      );
      if (cancelToken.isCancelled) return null;
      consecutiveErrors = 0;
    } catch (error) {
      if (_isHermesProtocolFailure(error)) rethrow;
      if (cancelToken.isCancelled) return null;
      consecutiveErrors++;
      if (consecutiveErrors >= 3) rethrow;
      await Future<void>.delayed(pollInterval);
      continue;
    }
    String status;
    String text;
    try {
      final decoded = OpenAiResponsesCodec.decodeResponse(
        withoutHermesCommentary(response),
      );
      status = decoded.status.toJson();
      text = _requireHermesRecoveryTextWithinLimit(
        OpenAiResponsesCodec.content(decoded).text,
        maxCharacters: service.streamLimits.maxCharacters,
      );
    } on HermesStreamGuardException {
      rethrow;
    } catch (_) {
      // Stored responses from older Hermes releases can omit OpenAI-required
      // item metadata. Keep recovery compatible without making the direct
      // provider adapter's standard Responses decoding permissive.
      status = _hermesRecoveryStatus(response['status']) ?? 'unknown';
      text = _extractBoundedHermesRecoveryOutput(
        response['output'],
        maxCharacters: service.streamLimits.maxCharacters,
      );
    }
    if (status != 'queued' && status != 'in_progress') {
      return (text: text, status: status);
    }
    await Future<void>.delayed(pollInterval);
  }
  return null;
}

String? _hermesRecoveryStatus(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > _maxHermesRecoveryStatusCharacters) {
    return null;
  }
  return value.toLowerCase();
}

@visibleForTesting
String? hermesRecoveryStatusForTest(Object? value) =>
    _hermesRecoveryStatus(value);

/// Applies [event] to [message] the way a live run does.
@visibleForTesting
ChatMessage applyHermesRunEventForTest(
  ChatMessage message,
  HermesRunEvent event, {
  String? runId,
  Iterable<String> sensitiveValues = const <String>[],
}) {
  var current = message;
  _handleEvent(
    event,
    runId: runId,
    storedSessionId: null,
    sensitiveValues: sensitiveValues,
    appendContent: (text) =>
        current = current.copyWith(content: current.content + text),
    appendStatus: (status) => current = current.copyWith(
      statusHistory: [...current.statusHistory, status],
    ),
    appendReasoning: (_) {},
    updateMessage: (update) => current = update(current),
  );
  return current;
}

String _extractBoundedHermesRecoveryOutput(
  Object? output, {
  required int maxCharacters,
}) {
  try {
    return extractHermesOutputText(
      output,
      maxCharacters: maxCharacters,
      maxDepth: kMaxHermesRecoveryJsonDepth,
      maxNodes: kMaxHermesRecoveryJsonNodes,
    );
  } on FormatException {
    throw const HermesStreamGuardException(
      'The Hermes recovery output exceeded Conduit\'s size or shape limit.',
    );
  }
}

String _requireHermesRecoveryTextWithinLimit(
  String text, {
  required int maxCharacters,
}) {
  var characters = 0;
  for (final _ in text.runes) {
    characters++;
    if (characters > maxCharacters) {
      throw const HermesStreamGuardException(
        'The Hermes recovery output exceeded Conduit\'s size limit.',
      );
    }
  }
  return text;
}

/// Bounds all status rows introduced by one Hermes transport.
///
/// Tool invocations are admitted until the fixed row budget is exhausted.
/// Once admitted, their in-flight updates and terminal event still reach the
/// notifier. New invocations beyond the budget collapse into one already-done
/// summary so an omitted provider event can never leave a permanent shimmer.
final class _HermesStatusAccumulator {
  _HermesStatusAccumulator({
    required Iterable<String> sensitiveValues,
    required void Function(ChatStatusUpdate) appendStatus,
  }) : _appendStatus = appendStatus {
    _reasoning = _HermesReasoningStatusAccumulator(
      sensitiveValues: sensitiveValues,
      appendStatus: _appendStatus,
    );
  }

  static const int _maxToolRows = kMaxHermesStatusRowsPerTurn - 2;
  static const String _overflowAction = 'hermes_tools_omitted';

  final void Function(ChatStatusUpdate) _appendStatus;
  late final _HermesReasoningStatusAccumulator _reasoning;
  final Map<String, ChatStatusUpdate> _pendingTools = {};
  final Map<String, ChatStatusUpdate> _lastCompletedTools = {};

  int _toolRows = 0;
  bool _reportedOverflow = false;

  void appendReasoning(String content) => _reasoning.append(content);

  void appendStatus(ChatStatusUpdate update) {
    final action = update.action;
    if (action == null || !action.startsWith('hermes_tool_')) {
      _appendStatus(update);
      return;
    }

    final pending = _pendingTools[action];
    if (pending != null) {
      if (_toolUpdatesEquivalent(pending, update)) return;
      _appendStatus(update);
      if (update.done == true) {
        _pendingTools.remove(action);
        _lastCompletedTools[action] = update;
      } else {
        _pendingTools[action] = update;
      }
      return;
    }

    // Providers sometimes retransmit a terminal frame. Suppress only an exact
    // retransmission: the same named tool can be invoked repeatedly, and a
    // later terminal-only failure may carry a distinct result or error.
    final lastCompleted = _lastCompletedTools[action];
    if (update.done == true &&
        lastCompleted != null &&
        _toolUpdatesEquivalent(lastCompleted, update)) {
      return;
    }

    if (_toolRows >= _maxToolRows) {
      _reportOverflow();
      return;
    }

    _toolRows++;
    _appendStatus(update);
    if (update.done == true) {
      _lastCompletedTools[action] = update;
    } else {
      _pendingTools[action] = update;
    }
  }

  void _reportOverflow() {
    if (_reportedOverflow) return;
    _reportedOverflow = true;
    _appendStatus(
      const ChatStatusUpdate(
        action: _overflowAction,
        description: 'Additional Hermes tool activity omitted',
        done: true,
      ),
    );
  }

  bool _toolUpdatesEquivalent(
    ChatStatusUpdate previous,
    ChatStatusUpdate next,
  ) => previous == next;
}

/// Coalesces provider reasoning fragments into one bounded status description.
///
/// Hermes can emit a reasoning event per token. Letting every fragment become
/// a distinct status row makes the notifier repeatedly copy an ever-growing
/// history. Keeping only a bounded raw prefix also means hostile streams stop
/// causing UI mutations once the visible detail cannot change anymore.
final class _HermesReasoningStatusAccumulator {
  _HermesReasoningStatusAccumulator({
    required Iterable<String> sensitiveValues,
    required void Function(ChatStatusUpdate) appendStatus,
  }) : _sensitiveValues = sensitiveValues
           .where((value) => value.isNotEmpty)
           .toList(growable: false),
       _appendStatus = appendStatus;

  final List<String> _sensitiveValues;
  final void Function(ChatStatusUpdate) _appendStatus;
  final StringBuffer _rawDetail = StringBuffer();

  int _rawCharacters = 0;
  bool _sealed = false;
  String? _lastDescription;

  void append(String content) {
    if (_sealed || content.isEmpty) return;

    var changed = false;
    for (final rune in content.runes) {
      if (_rawCharacters >= kMaxHermesStatusDetailCharacters) {
        _sealed = true;
        break;
      }
      _rawDetail.writeCharCode(rune);
      _rawCharacters++;
      changed = true;
    }
    if (_rawCharacters >= kMaxHermesStatusDetailCharacters) {
      _sealed = true;
    }
    if (!changed) return;

    // Do not expose a trailing fragment that could still become a configured
    // credential when the next provider delta arrives. Once the full value is
    // present, the normal sanitizer replaces it atomically.
    final visibleRaw = _withoutTrailingSensitivePrefix(_rawDetail.toString());
    final safeReasoning = _sanitizeHermesStatusDetail(
      visibleRaw,
      sensitiveValues: _sensitiveValues,
    );
    final description = safeReasoning == null
        ? 'Thinking…'
        : 'Thinking… $safeReasoning';
    if (description == _lastDescription) return;

    _lastDescription = description;
    _appendStatus(
      ChatStatusUpdate(
        action: 'reasoning',
        description: description,
        done: false,
      ),
    );
  }

  String _withoutTrailingSensitivePrefix(String raw) {
    var withheldCodeUnits = 0;
    for (final secret in _sensitiveValues) {
      final maxPrefixLength = min(secret.length - 1, raw.length);
      for (var length = maxPrefixLength; length > withheldCodeUnits; length--) {
        if (raw.endsWith(secret.substring(0, length))) {
          withheldCodeUnits = length;
          break;
        }
      }
    }
    return withheldCodeUnits == 0
        ? raw
        : raw.substring(0, raw.length - withheldCodeUnits);
  }
}

void _handleEvent(
  HermesRunEvent event, {
  required String? runId,
  required String? storedSessionId,
  required Iterable<String> sensitiveValues,
  required void Function(String) appendContent,
  required void Function(ChatStatusUpdate) appendStatus,
  required void Function(String) appendReasoning,
  required void Function(ChatMessage Function(ChatMessage)) updateMessage,
}) {
  switch (event) {
    case HermesResponseCreated():
      break;

    case HermesTokenDelta(:final content):
      appendContent(content);

    case HermesReasoningDelta(:final content):
      appendReasoning(content);

    case HermesToolProgress(
      :final toolName,
      :final detail,
      :final arguments,
      :final result,
      :final inlineDiff,
      :final subagent,
      :final done,
      :final failed,
    ):
      // The stable action lets the notifier replace and finish the in-flight
      // tool row. A failed terminal event gets a distinct description so its
      // scoped error remains visible instead of resembling a success.
      final safeToolName = _sanitizeHermesToolName(
        toolName,
        sensitiveValues: sensitiveValues,
      );
      final failureDetail = detail?.trim();
      final safeFailureDetail = failureDetail == null
          ? null
          : sanitizeHermesProviderErrorMessage(
              failureDetail,
              sensitiveValues: sensitiveValues,
            );
      final safeDetail = failed
          ? safeFailureDetail
          : _sanitizeHermesStatusDetail(
              detail ?? '',
              sensitiveValues: sensitiveValues,
            );
      final details = <ChatStatusItem>[
        ?hermesToolDetailItem(
          'Arguments',
          arguments,
          sanitize: (raw) => sanitizeHermesProviderErrorMessage(
            raw,
            sensitiveValues: sensitiveValues,
            maxCharacters: 2048,
          ),
        ),
        ?hermesToolDetailItem(
          failed ? 'Error' : 'Result',
          result,
          sanitize: (raw) => sanitizeHermesProviderErrorMessage(
            raw,
            sensitiveValues: sensitiveValues,
            maxCharacters: 2048,
          ),
        ),
        // Kept line by line, so the reply can show it as a diff card.
        if (inlineDiff == null
            ? null
            : sanitizeHermesInlineDiff(
                inlineDiff,
                sensitiveValues: sensitiveValues,
              )
            case final String diff)
          hermesInlineDiffItem(diff),
      ];
      appendStatus(
        ChatStatusUpdate(
          action: _hermesToolActionId(toolName, safeToolName),
          description: failed
              ? safeFailureDetail != null && safeFailureDetail.isNotEmpty
                    ? '$safeToolName failed: $safeFailureDetail'
                    : '$safeToolName failed'
              : safeDetail == null || safeDetail.isEmpty
              ? safeToolName
              : '$safeToolName · $safeDetail',
          done: done,
          items: details,
          query: subagent ? 'Subagent' : null,
        ),
      );

    case HermesApprovalRequested(
      :final approvalId,
      :final summary,
      :final choices,
      :final executionGeneration,
      :final raw,
    ):
      final safeApprovalId = _validatedHermesOpaqueIdentifier(
        approvalId,
        sensitiveValues: sensitiveValues,
      );
      final safeRunId = _validatedHermesOpaqueIdentifier(
        runId,
        sensitiveValues: sensitiveValues,
      );
      final safeStoredSessionId = _validatedHermesOpaqueIdentifier(
        storedSessionId,
        sensitiveValues: sensitiveValues,
      );
      if (safeApprovalId == null || safeRunId == null) {
        updateMessage(
          (m) => m.copyWith(
            error: const ChatMessageError(
              content: 'Hermes returned an invalid approval request.',
            ),
          ),
        );
        break;
      }
      final safeSummary = summary == null
          ? null
          : _sanitizeHermesApprovalSummary(
              summary,
              sensitiveValues: sensitiveValues,
            );
      final safeChoices = _boundedHermesDecisionChoices(
        choices.isEmpty ? raw['choices'] : choices,
      );
      updateMessage((m) {
        final meta = Map<String, dynamic>.from(m.metadata ?? const {});
        meta[kHermesApprovalMeta] = {
          'state': 'pending',
          'approvalId': safeApprovalId,
          'runId': safeRunId,
          'storedSessionId': ?safeStoredSessionId,
          'summary': ?safeSummary,
          if (safeChoices.isNotEmpty) 'choices': safeChoices,
          'executionGeneration': ?executionGeneration,
        };
        return m.copyWith(metadata: meta);
      });

    case HermesPromptSettled(:final promptId):
      // The prompt was answered (here or elsewhere), timed out, or was
      // withdrawn. Close its card for good; an answer already recorded as
      // approved/denied keeps that outcome.
      updateMessage((m) {
        final meta = m.metadata;
        if (meta == null) return m;
        final approval = meta[kHermesApprovalMeta];
        final decision = meta[kHermesDecisionMeta];
        final settlesApproval =
            approval is Map &&
            approval['approvalId'] == promptId &&
            const {null, 'pending', 'resolving'}.contains(approval['state']);
        final settlesDecision =
            decision is Map &&
            decision['requestId'] == promptId &&
            decision['state'] == 'pending';
        if (!settlesApproval && !settlesDecision) return m;
        final next = Map<String, dynamic>.from(meta);
        if (settlesApproval) {
          next[kHermesApprovalMeta] = <String, dynamic>{
            ...approval.cast<String, dynamic>(),
            'state': 'settled',
          };
        }
        if (settlesDecision) {
          next[kHermesDecisionMeta] = <String, dynamic>{
            ...decision.cast<String, dynamic>(),
            'state': 'resolved',
          };
        }
        return m.copyWith(metadata: next);
      });

    case HermesDecisionRequested(
      :final kind,
      :final requestId,
      :final prompt,
      :final raw,
    ):
      if (runId == null) break;
      final safeRequestId = _validatedHermesOpaqueIdentifier(
        requestId,
        sensitiveValues: sensitiveValues,
      );
      final safeRuntimeId = _validatedHermesOpaqueIdentifier(
        runId,
        sensitiveValues: sensitiveValues,
      );
      if (safeRequestId == null || safeRuntimeId == null) {
        updateMessage(
          (message) => message.copyWith(
            error: const ChatMessageError(
              content: 'Hermes sent an invalid decision request.',
            ),
          ),
        );
        break;
      }
      final safePrompt = prompt == null
          ? null
          : _sanitizeHermesApprovalSummary(
              prompt,
              sensitiveValues: sensitiveValues,
            );
      updateMessage((message) {
        final metadata = Map<String, dynamic>.from(
          message.metadata ?? const {},
        );
        metadata[kHermesDecisionMeta] = <String, dynamic>{
          'state': 'pending',
          'kind': kind.name,
          'requestId': safeRequestId,
          'runtimeId': safeRuntimeId,
          'prompt': ?safePrompt,
          if (kind == HermesDecisionKind.clarification) ...{
            if (raw['choices'] is List)
              'choices': _boundedHermesDecisionChoices(raw['choices']),
            if (raw['multi_select'] == true) 'multiSelect': true,
            'questions': _safeHermesClarifyQuestions(
              raw,
              sensitiveValues: sensitiveValues,
            ),
            // A REST run's question names the generation its answer echoes.
            if (raw['execution_generation'] case final int generation)
              'executionGeneration': generation,
          },
          if (kind == HermesDecisionKind.mcpSetup) ...{
            'mcpServer': validateHermesBoundedString(
              raw['server'],
              maxCharacters: 128,
            ),
            'mcpAction': switch (raw['action']) {
              'authorize' || 'enable' || 'install' => raw['action'],
              _ => null,
            },
          },
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 24))
              .toUtc()
              .toIso8601String(),
        };
        return message.copyWith(metadata: metadata);
      });

    case HermesFinalOutput():
      // Captured in the stream listener (appended only if no deltas streamed).
      break;

    case HermesComposerPrefill():
      break;

    case HermesLifecycle():
      // Lifecycle transitions are advisory; terminal ones also emit RunDone.
      break;

    case HermesRunError(:final message):
      updateMessage(
        (m) => m.copyWith(
          error: ChatMessageError(
            content: sanitizeHermesProviderErrorMessage(
              message,
              sensitiveValues: sensitiveValues,
            ),
          ),
        ),
      );

    case HermesRunNotice(:final message):
      appendStatus(
        ChatStatusUpdate(
          action: kHermesRunNoticeAction,
          description: sanitizeHermesProviderErrorMessage(
            message,
            sensitiveValues: sensitiveValues,
          ),
          done: true,
        ),
      );

    case HermesRunDone():
      break;
  }
}

List<String> _hermesSensitiveValues(HermesBackendService service) {
  return _boundedHermesSensitiveValues(service.config.sensitiveValues);
}

List<String> _boundedHermesSensitiveValues(Iterable<String> source) {
  final values = <String>[];
  for (final raw in source) {
    if (raw.isEmpty) continue;
    // Return the original reference without trimming when it is oversized.
    // The sanitizer sees the length and fails closed before hashing/copying it.
    if (raw.length > kMaxProviderErrorSecretCharacters) return [raw];
    values.add(raw);
    final trimmed = raw.trim();
    if (trimmed.isNotEmpty && trimmed != raw) values.add(trimmed);
  }
  return values;
}

String? _validatedHermesOpaqueIdentifier(
  String? raw, {
  required Iterable<String> sensitiveValues,
}) => validateHermesOpaqueIdentifier(raw, sensitiveValues: sensitiveValues);

String? _sanitizeHermesStatusDetail(
  String raw, {
  required Iterable<String> sensitiveValues,
}) {
  final safe = sanitizeHermesProviderErrorMessage(
    raw,
    sensitiveValues: sensitiveValues,
    maxCharacters: kMaxHermesStatusDetailCharacters,
  );
  if (safe == 'Hermes run failed.' || safe == '[REDACTED]') return null;
  return safe;
}

String? _sanitizeHermesApprovalSummary(
  String raw, {
  required Iterable<String> sensitiveValues,
}) {
  final safe = sanitizeHermesProviderErrorMessage(
    raw,
    sensitiveValues: sensitiveValues,
    maxCharacters: kMaxHermesApprovalSummaryCharacters,
  );
  if (safe == 'Hermes run failed.' || safe == '[REDACTED]') return null;
  return safe;
}

/// A clarify payload's questions, stored as [HermesClarifyQuestion.toJson]
/// with sensitive values redacted from what the card shows.
List<Map<String, Object?>> _safeHermesClarifyQuestions(
  Map<String, dynamic> raw, {
  required Iterable<String> sensitiveValues,
}) {
  String? safe(String? text) => text == null
      ? null
      : _sanitizeHermesApprovalSummary(text, sensitiveValues: sensitiveValues);
  return [
    for (final question in hermesClarifyQuestionsFromPayload(raw))
      if (safe(question.text) case final String text)
        HermesClarifyQuestion(
          id: question.id,
          text: text,
          choices: [for (final choice in question.choices) ?safe(choice)],
          multiSelect: question.multiSelect,
          locked: question.locked,
          lockedAnswer: safe(question.lockedAnswer),
        ).toJson(),
  ];
}

List<String> _boundedHermesDecisionChoices(Object? value) {
  if (value is! Iterable) return const <String>[];
  return [
    for (final item in value.take(8))
      ?validateHermesBoundedString(item, maxCharacters: 80),
  ];
}

String _sanitizeHermesToolName(
  String raw, {
  required Iterable<String> sensitiveValues,
}) {
  final safe = sanitizeHermesProviderErrorMessage(
    raw,
    sensitiveValues: sensitiveValues,
    maxCharacters: kMaxHermesToolNameCharacters,
  );
  // Error-message fallback wording is misleading as a tool label, and a name
  // made entirely from a credential should reveal neither the value nor that
  // credential's redaction marker in persisted status history.
  if (safe == 'Hermes run failed.' || safe == '[REDACTED]') {
    return 'Hermes tool';
  }
  return safe;
}

String _hermesToolActionId(String raw, String safeDisplayName) {
  if (raw.length <= 64) {
    final trimmed = raw.trim();
    final canPreserveReadableIdentity =
        trimmed == safeDisplayName &&
        RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]*$').hasMatch(trimmed);
    if (canPreserveReadableIdentity) return 'hermes_tool_$trimmed';
  }

  // Action ids are persisted and used to replace an in-progress row. Never put
  // provider text in that control field. A process-private keyed digest keeps
  // matching start/finish events stable and distinct without exposing a
  // dictionary-searchable hash of a reflected credential.
  final digest = _hermesToolActionHmac
      .convert(utf8.encode(raw))
      .toString()
      .substring(0, 16);
  return 'hermes_tool_opaque_$digest';
}

final Hmac _hermesToolActionHmac = Hmac(sha256, _newHermesToolActionKey());

List<int> _newHermesToolActionKey() {
  final random = Random.secure();
  return List<int>.generate(32, (_) => random.nextInt(256), growable: false);
}

String sanitizeHermesProviderErrorMessage(
  String raw, {
  Iterable<String> sensitiveValues = const <String>[],
  int maxCharacters = kMaxHermesProviderErrorCharacters,
}) => sanitizeProviderErrorMessage(
  raw,
  fallback: 'Hermes run failed.',
  sensitiveValues: sensitiveValues,
  maxCharacters: maxCharacters,
);

String _friendlyError(Object e) {
  if (e is HermesStreamGuardException) return e.message;
  if (e is HermesModelSwitchHeld) return e.message;
  if (e is HermesDesktopGatewayStartingException) return e.message;
  if (e is FormatException) return 'Hermes returned an invalid response.';
  if (e is HermesApiException) {
    final refusal = hermesApiRefusalMessage(e);
    if (refusal != null) return refusal;
  }
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code != null) return 'Hermes request failed (HTTP $code).';
    return 'Could not reach the Hermes agent. Check the server URL and that it is reachable.';
  }
  return 'Hermes run failed.';
}

/// The chat-facing explanation for a coded Hermes refusal, or null when the
/// code is not one Conduit can explain better than the HTTP status.
String? hermesApiRefusalMessage(HermesApiException error) {
  switch (error.code) {
    case HermesApiErrorCode.permissionDenied:
      return 'This chat belongs to another Hermes app, so Conduit can only '
          'read it. Continue in a copy to keep chatting.';
    case HermesApiErrorCode.notFound:
      return 'This Hermes session was deleted. Start a new chat to continue.';
    case HermesApiErrorCode.admissionConflict:
    case HermesApiErrorCode.idempotencyKeyConflict:
      return 'Hermes refused this message because it conflicts with another '
          'request for this chat.';
    case HermesApiErrorCode.staleGeneration:
    case HermesApiErrorCode.approvalNotPending:
      return 'This Hermes request was already answered or has expired.';
    case HermesApiErrorCode.unknownExecution:
      return 'Hermes cannot tell whether its last run finished.';
    case HermesApiErrorCode.admissionQueued:
      return 'Hermes saved your message and will run it when it is back. '
          'Don\'t send it again.';
    case 'runtime_draining':
    case 'gateway_draining':
    case 'storage_unavailable':
    case 'chain_moved':
      return 'Hermes is restarting or busy. Try again in a moment.';
  }
  if (error.statusCode == 429) {
    return 'Hermes is handling too many requests. Try again in a moment.';
  }
  return null;
}

bool _isHermesProtocolFailure(Object? error) =>
    error is HermesStreamGuardException || error is FormatException;

bool _allowsHermesCheckpointRecovery(Object? error) =>
    error is HermesStreamGuardException && error.allowsCheckpointRecovery;

bool _isActiveHermesProtocolFailure(Object? error, CancelToken cancelToken) =>
    _isHermesProtocolFailure(error) &&
    (!cancelToken.isCancelled || hermesCancellationWasInternal(cancelToken));
