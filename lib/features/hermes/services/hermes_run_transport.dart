import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/models/chat_message.dart';
import '../../../core/services/openai_responses_codec.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/semantic_details.dart';
import '../../../core/utils/unicode_prefix.dart';
import '../models/hermes_run_event.dart';
import '../providers/hermes_providers.dart';
import 'hermes_api_service.dart';
import 'hermes_backend_service.dart';
import 'hermes_identifier.dart';
import 'hermes_message_mapper.dart';
import 'hermes_stream_parser.dart';

export 'hermes_identifier.dart' show kMaxHermesOpaqueIdentifierCharacters;

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
const int _maxHermesProviderSecretCharacters = 8 * 1024;
const int kMaxHermesToolNameCharacters = 80;
const int kMaxHermesStatusDetailCharacters = 120;
const int kMaxHermesApprovalSummaryCharacters = 512;
const int _maxHermesRecoveryStatusCharacters = 64;

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
      updateMessage(
        (message) => message.copyWith(
          error: ChatMessageError(content: _friendlyError(error)),
        ),
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
        completedSuccessfully = recovered.status == 'completed';
        if (!completedSuccessfully) {
          updateMessage(
            (message) => message.copyWith(
              error: ChatMessageError(
                content: recovered.status == 'incomplete'
                    ? 'Hermes stopped this response before it completed.'
                    : 'Hermes response failed.',
              ),
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
  required void Function(String content) appendContent,
  void Function(String content)? replaceContent,
  required void Function(ChatStatusUpdate update) appendStatus,
  required void Function(ChatMessage Function(ChatMessage) updater)
  updateMessage,
  void Function(ChatMessageError error)? reportStopError,
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
  final streamedText = StringBuffer();
  String? finalOutput;
  Object? streamError;

  late final StreamSubscription<HermesRunEvent> sub;
  sub = service
      .runEvents(runId, sessionId: sessionId, cancelToken: eventCancelToken)
      .listen(
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
        final recovered = await _recoverRunOutput(
          service,
          runId,
          cancelToken: runCancelToken,
          maxPolls: allowsCheckpointRecovery ? 1 : maxRecoveryPolls,
          pollInterval: allowsCheckpointRecovery
              ? Duration.zero
              : recoveryPollInterval,
        );
        if (recovered == null) return;
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
        if (recovered.status != 'completed') {
          final errorMessage = switch (recovered.status) {
            'cancelled' || 'canceled' => 'Hermes run was cancelled.',
            'stopped' => 'Hermes run was stopped.',
            'incomplete' => 'Hermes stopped this response before it completed.',
            _ => 'Hermes run failed.',
          };
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
}) async {
  if (maxPolls <= 0) {
    throw ArgumentError.value(maxPolls, 'maxPolls', 'Must be positive');
  }
  var consecutiveErrors = 0;
  var malformedResponses = 0;
  var polls = 0;
  while (!cancelToken.isCancelled) {
    if (polls >= maxPolls) {
      throw TimeoutException(
        'Hermes run did not reach a terminal state after $maxPolls polls',
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
      if (consecutiveErrors >= 3) rethrow;
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
        status == 'incomplete';
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
    await Future<void>.delayed(pollInterval);
  }
  return null;
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
      final decoded = OpenAiResponsesCodec.decodeResponse(response);
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
        ?hermesToolDetailItem(
          'Inline diff',
          inlineDiff,
          sanitize: (raw) => sanitizeHermesProviderErrorMessage(
            raw,
            sensitiveValues: sensitiveValues,
            maxCharacters: 2048,
          ),
        ),
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
        };
        return m.copyWith(metadata: meta);
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
    if (raw.length > _maxHermesProviderSecretCharacters) return [raw];
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
}) {
  if (maxCharacters <= 0) {
    throw RangeError.value(maxCharacters, 'maxCharacters');
  }

  const fallback = 'Hermes run failed.';
  const redacted = '[REDACTED]';
  final secrets = <String>{};
  for (final value in sensitiveValues) {
    if (value.isEmpty) continue;
    if (value.length > _maxHermesProviderSecretCharacters) return fallback;
    secrets.add(value);
  }
  final orderedSecrets = secrets.toList(growable: false)
    ..sort((a, b) => b.length.compareTo(a.length));
  // Keep enough Unicode scalars to include any configured secret that starts
  // inside the eventual visible prefix. A UTF-16 substring can cut inside a
  // secret after supplementary characters, preventing exact redaction and
  // exposing the surviving fragment.
  var safe = redactSensitiveValuesInUnicodePrefix(
    raw,
    sensitiveValues: orderedSecrets,
    maxVisibleScalars: maxCharacters,
  );

  safe = safe.replaceAllMapped(
    RegExp(
      r'\b(authorization|proxy-authorization)\b\s*[:=]\s*[^\r\n]*',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}: $redacted',
  );
  safe = safe.replaceAllMapped(
    RegExp(
      r'\b(api[-_ ]?key|access[-_ ]?token|password|secret|session[-_ ]?key)\b\s*[:=]\s*(?:bearer\s+)?[^\s,;]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}: $redacted',
  );
  safe = safe.replaceAllMapped(
    RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    (_) => 'Bearer $redacted',
  );
  safe = safe
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (safe.isEmpty) return fallback;

  final iterator = safe.runes.iterator;
  final prefix = <int>[];
  while (prefix.length < maxCharacters && iterator.moveNext()) {
    prefix.add(iterator.current);
  }
  if (!iterator.moveNext()) return String.fromCharCodes(prefix);
  if (maxCharacters == 1) return '…';
  return '${String.fromCharCodes(prefix.take(maxCharacters - 1))}…';
}

String _friendlyError(Object e) {
  if (e is HermesStreamGuardException) return e.message;
  if (e is FormatException) return 'Hermes returned an invalid response.';
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code != null) return 'Hermes request failed (HTTP $code).';
    return 'Could not reach the Hermes agent. Check the server URL and that it is reachable.';
  }
  return 'Hermes run failed.';
}

bool _isHermesProtocolFailure(Object? error) =>
    error is HermesStreamGuardException || error is FormatException;

bool _allowsHermesCheckpointRecovery(Object? error) =>
    error is HermesStreamGuardException && error.allowsCheckpointRecovery;

bool _isActiveHermesProtocolFailure(Object? error, CancelToken cancelToken) =>
    _isHermesProtocolFailure(error) &&
    (!cancelToken.isCancelled || hermesCancellationWasInternal(cancelToken));
