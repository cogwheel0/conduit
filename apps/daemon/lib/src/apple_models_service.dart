import 'dart:async';

import 'package:conduit_core/features/direct_connections/providers/apple_pcc_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';

/// Whether Apple On-Device is offered as a Direct connection: the window's
/// engine last said this Mac's model can answer (macOS 26 or later, Apple
/// Intelligence on, the model ready).
///
/// The phone offers it wherever iOS might have it; the Mac only while it
/// answers, so a Mac without a ready model is not handed a Direct backend
/// that always fails (the core falls back to any usable Direct connection
/// when the last account signs out) and its picker lists no dead model.
/// Asked again when a window connects, when Settings shows it, and on
/// Check Again.
final appleOnDeviceAnswersProvider =
    NotifierProvider<AppleOnDeviceAnswers, bool>(AppleOnDeviceAnswers.new);

final class AppleOnDeviceAnswers extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool offered) {
    if (state != offered) state = offered;
  }
}

/// The core overrides that run Apple's models through the window: the
/// bridge as the adapter's host, the adapter registered, on-device offered
/// while the engine says it answers, and Private Cloud Compute never (this
/// build has no entitlement for it: FoundationModels traps without one).
List<Override> appleModelsOverrides(AppleModelsBridge bridge) => <Override>[
  applePccHostProvider.overrideWithValue(bridge),
  hostDirectProviderAdaptersProvider.overrideWith(
    (ref) => <DirectProviderAdapter>[ref.watch(applePccAdapterProvider)],
  ),
  applePccPlatformSupportedProvider.overrideWith(
    (ref) => ref.watch(appleOnDeviceAnswersProvider),
  ),
  applePrivateCloudComputeSupportedProvider.overrideWithValue(false),
];

/// `apple.*`: Apple's Foundation Models as a Direct backend.
///
/// The chat runs here, in the core's Direct engine and its Apple adapter,
/// as on the phone. Foundation Models is a Swift API, so the model runs in
/// the window: [AppleModelsBridge] is the adapter's host, which puts each
/// step to the window as `apple.command` and hears back through
/// `apple.report` (as read aloud's engine does).
final class AppleModelsService {
  AppleModelsService(this._container, {required this.bridge}) {
    bridge._onReady = _ready;
  }

  final ProviderContainer _container;
  final AppleModelsBridge bridge;

  /// Apple Intelligence as Settings shows it, asked of the engine now.
  Future<AppleModels> status() async =>
      AppleModels(models: <AppleModelStatus>[await _onDevice()]);

  /// Asks the Mac again (Check Again): [status], and a model that became
  /// able to answer is looked for again, so the model picker lists it.
  Future<AppleModels> refresh() async {
    final models = await status();
    if (models.models.first.availability == AppleAvailability.available) {
      unawaited(_rediscover());
    }
    return models;
  }

  /// The window's engine answered a command, or says what a run did.
  void report(AppleReport report) => bridge.report(report);

  /// The on-device model as the engine says it is now; what it says also
  /// decides whether the connection is offered.
  Future<AppleModelStatus> _onDevice() async {
    final said = bridge.supported;
    if (said != true) {
      // No window has said this Mac has Apple's models yet, or it said no.
      _offer(false);
      return AppleModelStatus(
        model: AppleModelKind.onDevice,
        availability: said == false
            ? AppleAvailability.unsupported
            : AppleAvailability.unavailable,
        reason: said == false
            ? AppleUnavailableReason.systemTooOld
            : AppleUnavailableReason.noEngine,
      );
    }
    PlatformPccStatus status;
    try {
      // The core's adapter, as the phone's Settings asks it (its timeout
      // and errors), straight to the host: not through the core's cached
      // status, which reads "unsupported" while the connection is not
      // offered.
      status = await _container
          .read(applePccAdapterProvider)
          .status(PlatformAppleModel.onDevice);
    } on Object {
      _offer(false);
      return const AppleModelStatus(
        model: AppleModelKind.onDevice,
        availability: AppleAvailability.unavailable,
        reason: AppleUnavailableReason.noEngine,
      );
    }
    final available = status.availability == PlatformPccAvailability.available;
    _offer(available);
    return AppleModelStatus(
      model: AppleModelKind.onDevice,
      availability: switch (status.availability) {
        PlatformPccAvailability.available => AppleAvailability.available,
        PlatformPccAvailability.unavailable => AppleAvailability.unavailable,
        PlatformPccAvailability.unsupported => AppleAvailability.unsupported,
      },
      reason: available
          ? null
          : (bridge.lastStatus?.reason ?? AppleUnavailableReason.noEngine),
      contextSize: reportedApplePccContextSize(status),
      supportsCurrentLocale: status.supportsCurrentLocale,
    );
  }

  void _offer(bool offered) {
    _container.read(appleOnDeviceAnswersProvider.notifier).set(offered);
    // Settings and the picker read the status the engine gave last.
    _container.invalidate(appleOnDeviceStatusProvider);
  }

  /// A window connected and said whether this Mac has Apple's models: asks
  /// it whether the model answers now. A connection already offered (a
  /// window that came back) looks for the model again.
  void _ready(bool supported) {
    final was = _container.read(appleOnDeviceAnswersProvider);
    unawaited(() async {
      await _onDevice();
      if (was && _container.read(appleOnDeviceAnswersProvider)) {
        await _rediscover();
      }
    }());
  }

  Future<void> _rediscover() async {
    try {
      await _container.read(directModelDiscoveryProvider.notifier).refresh();
    } on Object catch (error) {
      DebugLogger.warning(
        'rediscover-failed',
        scope: 'daemon/apple',
        data: <String, Object?>{'error': error.runtimeType.toString()},
      );
    }
  }
}

/// The window's Foundation Models engine as the core's [ApplePccHost]: each
/// step goes out as `apple.command`, and the window answers it, and tells
/// what a run did, with `apple.report`.
///
/// Made before the core (its overrides name it); [bind] gives it the event
/// bus once the daemon's services exist. Unbound, or with no window to
/// answer, the on-device model says it has no engine.
final class AppleModelsBridge implements ApplePccHost {
  AppleModelsBridge({
    Duration timeout = const Duration(seconds: 10),
    Duration startTimeout = const Duration(seconds: 20),
  }) : _timeout = timeout,
       _startTimeout = startTimeout;

  final Duration _timeout;
  final Duration _startTimeout;
  EventBus? _events;
  ApplePccHostListener? _listener;
  void Function(bool supported)? _onReady;
  int _nextId = 0;
  final Map<int, Completer<AppleReport>> _pending =
      <int, Completer<AppleReport>>{};

  /// The runs the window is running, so a window that comes back without
  /// them ends them here.
  final Set<String> _runs = <String>{};

  /// What the engine last said of the on-device model (for its reason).
  AppleEngineStatus? lastStatus;

  /// What the last window said: whether this Mac has Apple's models; null
  /// before any said.
  bool? supported;

  void bind(EventBus events) => _events = events;

  @override
  void attach(ApplePccHostListener listener) => _listener = listener;

  @override
  Future<PlatformPccStatus> getStatus(PlatformAppleModel model) async {
    if (model == PlatformAppleModel.privateCloudCompute) {
      return PlatformPccStatus(
        availability: PlatformPccAvailability.unsupported,
        quotaStatus: PlatformPccQuotaStatus.unknown,
        quotaLimitReached: false,
        canIncreaseQuota: false,
        message: kApplePccNotOfferedMessage,
      );
    }
    AppleEngineStatus status;
    try {
      final report = await _command(
        (id) => AppleCommand(
          id: id,
          kind: AppleCommandKind.status,
          model: AppleModelKind.onDevice,
        ),
      );
      status =
          report.status ??
          const AppleEngineStatus(
            availability: AppleAvailability.unavailable,
            reason: AppleUnavailableReason.other,
          );
    } on StateError {
      status = const AppleEngineStatus(
        availability: AppleAvailability.unavailable,
        reason: AppleUnavailableReason.noEngine,
      );
    }
    lastStatus = status;
    final available = status.availability == AppleAvailability.available;
    return PlatformPccStatus(
      availability: switch (status.availability) {
        AppleAvailability.available => PlatformPccAvailability.available,
        AppleAvailability.unavailable => PlatformPccAvailability.unavailable,
        AppleAvailability.unsupported => PlatformPccAvailability.unsupported,
      },
      quotaStatus: PlatformPccQuotaStatus.unknown,
      quotaLimitReached: false,
      canIncreaseQuota: false,
      message: available ? null : appleUnavailableMessage(status.reason),
      contextSize: status.contextSize,
      supportsCurrentLocale: status.supportsCurrentLocale,
    );
  }

  @override
  Future<bool> showQuotaIncreaseSuggestion() async => false;

  @override
  Future<void> start(PlatformPccCompletionRequest request) async {
    if (request.model != PlatformAppleModel.onDevice ||
        request.messages.any((message) => message.images.isNotEmpty) ||
        request.reasoningLevel != null) {
      // The adapter refuses these before here; never put them to the model.
      throw StateError('not an on-device request');
    }
    _runs.add(request.runId);
    try {
      await _command(
        (id) => AppleCommand(
          id: id,
          kind: AppleCommandKind.start,
          request: AppleGeneration(
            runId: request.runId,
            model: AppleModelKind.onDevice,
            messages: <AppleMessage>[
              for (final message in request.messages)
                AppleMessage(role: message.role, content: message.content),
            ],
            tools: <AppleToolDefinition>[
              for (final tool in request.tools)
                AppleToolDefinition(
                  name: tool.name,
                  description: tool.toolDescription,
                  inputSchemaJson: tool.inputSchemaJson,
                ),
            ],
            temperature: request.temperature,
            maximumResponseTokens: request.maximumResponseTokens,
            topP: request.topP,
            topK: request.topK,
            seed: request.seed,
            greedySampling: request.greedySampling,
            responseSchemaName: request.responseSchemaName,
            responseSchemaJson: request.responseSchemaJson,
          ),
        ),
        timeout: _startTimeout,
      );
    } on Object {
      _runs.remove(request.runId);
      rethrow;
    }
  }

  @override
  Future<void> cancel(String runId) async {
    if (!_runs.contains(runId)) return;
    await _command(
      (id) => AppleCommand(id: id, kind: AppleCommandKind.cancel, runId: runId),
    );
  }

  /// What the window said: what a run did first, then the answer, so a
  /// command's caller sees the state it left.
  void report(AppleReport report) {
    switch (report.kind) {
      case null:
        break;
      case AppleReportKind.ready:
        final supported = report.supported ?? false;
        this.supported = supported;
        // A socket that came back keeps the runs the engine still has; a
        // window without them (a new one) ends the rest here.
        final kept = report.runs.toSet();
        for (final runId in _runs.where((id) => !kept.contains(id)).toList()) {
          _runs.remove(runId);
          _event(
            PlatformPccStreamEvent(
              runId: runId,
              kind: PlatformPccEventKind.error,
              content: appleFailureMessage(AppleFailure.failed),
            ),
          );
        }
        _onReady?.call(supported);
      case AppleReportKind.content:
        _event(
          PlatformPccStreamEvent(
            runId: report.runId ?? '',
            kind: PlatformPccEventKind.content,
            content: report.content,
          ),
        );
      case AppleReportKind.usage:
        _event(
          PlatformPccStreamEvent(
            runId: report.runId ?? '',
            kind: PlatformPccEventKind.usage,
            inputTokenCount: report.inputTokens,
            outputTokenCount: report.outputTokens,
            reasoningTokenCount: report.reasoningTokens,
            totalTokenCount: report.totalTokens,
          ),
        );
      case AppleReportKind.failed:
        final runId = report.runId ?? '';
        _runs.remove(runId);
        _event(
          PlatformPccStreamEvent(
            runId: runId,
            kind: PlatformPccEventKind.error,
            content: report.failure == AppleFailure.unavailable
                ? appleUnavailableMessage(report.reason)
                : appleFailureMessage(report.failure ?? AppleFailure.failed),
          ),
        );
      case AppleReportKind.done:
        final runId = report.runId ?? '';
        _runs.remove(runId);
        _event(
          PlatformPccStreamEvent(runId: runId, kind: PlatformPccEventKind.done),
        );
      case AppleReportKind.toolCall:
        unawaited(_toolCall(report));
    }
    if (report.id case final id?) {
      final waiting = _pending[id];
      if (waiting != null && !waiting.isCompleted) waiting.complete(report);
    }
  }

  void _event(PlatformPccStreamEvent event) => _listener?.onEvent(event);

  Future<void> _toolCall(AppleReport report) async {
    final runId = report.runId ?? '';
    final callId = report.callId ?? '';
    final listener = _listener;
    PlatformPccToolResult result;
    if (listener == null) {
      result = PlatformPccToolResult(content: '', cancelled: true);
    } else {
      try {
        result = await listener.onToolCall(
          PlatformPccToolCall(
            runId: runId,
            callId: callId,
            name: report.toolName ?? '',
            argumentsJson: report.argumentsJson ?? '{}',
          ),
        );
      } on Object {
        result = PlatformPccToolResult(content: '', cancelled: true);
      }
    }
    try {
      await _command(
        (id) => AppleCommand(
          id: id,
          kind: AppleCommandKind.toolResult,
          runId: runId,
          callId: callId,
          toolContent: result.content,
          toolCancelled: result.cancelled,
        ),
      );
    } on StateError catch (error) {
      DebugLogger.warning(
        'tool-result-undelivered',
        scope: 'daemon/apple',
        data: <String, Object?>{'error': error.message},
      );
    }
  }

  /// Sends a command and waits for its answer; throws [StateError] when no
  /// window has the engine, it refuses, or none answers in time.
  Future<AppleReport> _command(
    AppleCommand Function(int id) build, {
    Duration? timeout,
  }) async {
    final events = _events;
    if (events == null) throw StateError('no engine yet');
    final id = ++_nextId;
    final completer = Completer<AppleReport>();
    _pending[id] = completer;
    final command = build(id);
    try {
      final reached = events.emit(ConduitEventSpecs.appleCommand, command);
      if (reached == 0) {
        throw StateError('no window to run ${command.kind.name}');
      }
      final report = await completer.future.timeout(timeout ?? _timeout);
      if (!report.ok) {
        throw StateError(report.error ?? '${command.kind.name} failed');
      }
      return report;
    } on TimeoutException {
      throw StateError('the window did not answer ${command.kind.name}');
    } finally {
      _pending.remove(id);
    }
  }
}

/// What the phone's bridge says when Private Cloud Compute is not built in.
const String kApplePccNotOfferedMessage =
    'Apple Private Cloud Compute is not enabled in this build of Conduit.';

/// Why the on-device model cannot answer, in the phone bridge's words (the
/// core puts it on the connection's discovery error and the chat's error).
String appleUnavailableMessage(AppleUnavailableReason? reason) =>
    switch (reason) {
      AppleUnavailableReason.systemTooOld =>
        'Apple On-Device requires macOS 26 and a Mac with Apple Intelligence.',
      AppleUnavailableReason.deviceNotEligible =>
        'This Mac does not support Apple Intelligence.',
      AppleUnavailableReason.appleIntelligenceNotEnabled =>
        'Turn on Apple Intelligence to use Apple On-Device.',
      AppleUnavailableReason.modelNotReady =>
        'The Apple on-device model is still downloading or not ready.',
      AppleUnavailableReason.notOffered => kApplePccNotOfferedMessage,
      AppleUnavailableReason.noEngine ||
      AppleUnavailableReason.other ||
      null => 'Apple On-Device is unavailable.',
    };

/// How a run failed, in the phone bridge's words.
String appleFailureMessage(AppleFailure failure) => switch (failure) {
  AppleFailure.contextExceeded =>
    'This conversation exceeds the Apple On-Device context limit.',
  AppleFailure.notReady => 'The Apple on-device model is not ready.',
  AppleFailure.guardrail =>
    'Apple On-Device blocked this request for safety reasons.',
  AppleFailure.refusal => 'Apple On-Device declined this request.',
  AppleFailure.unsupported => 'Apple On-Device cannot process this request.',
  AppleFailure.decoding => 'Apple On-Device returned an invalid response.',
  AppleFailure.busy => 'Apple On-Device is busy. Retry shortly.',
  AppleFailure.timedOut => 'Apple On-Device timed out.',
  AppleFailure.invalidRequest => 'Apple Foundation Models request is invalid.',
  AppleFailure.invalidSchema =>
    'Apple Foundation Models received an unsupported response schema.',
  AppleFailure.invalidToolSchema =>
    'Apple Foundation Models received an unsupported MCP tool schema.',
  AppleFailure.invalidStream =>
    'Apple On-Device returned an invalid response stream.',
  AppleFailure.unavailable => appleUnavailableMessage(null),
  AppleFailure.failed => 'Apple On-Device request failed.',
};
