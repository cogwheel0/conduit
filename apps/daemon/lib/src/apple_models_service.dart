import 'dart:async';

import 'package:conduit_core/features/direct_connections/providers/apple_pcc_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/apple_backend_choice.dart';
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
    bridge._onGone = _gone;
  }

  final ProviderContainer _container;
  final AppleModelsBridge bridge;

  /// Each ask of the on-device model's status is numbered: only the latest
  /// decides the offer, so an answer to an older ask (asked before the
  /// window said its Mac has no model, say) never brings it back.
  int _asked = 0;

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

  /// The first-run chooser's Apple On-Device row, as the phone's
  /// `_selectAppleModel`: the Mac is asked again, and a model the core
  /// says may be chosen ([appleModelChoosable]) becomes the preferred
  /// Direct backend ([chooseAppleModelBackend]). Answers with the model as
  /// it is now; anything but available chose nothing.
  Future<AppleModelStatus> choose() async {
    final model = await _onDevice();
    final status = _status;
    if (status == null || !appleModelChoosable(status)) return model;
    await chooseAppleModelBackend(_container.read, PlatformAppleModel.onDevice);
    unawaited(_rediscover());
    return model;
  }

  /// The window's engine answered a command, or says what a run did.
  void report(AppleReport report, {required String from}) =>
      bridge.report(report, from: from);

  /// A window's session closed: its engine runs nothing more.
  void forgetWindow(String session) => bridge.forgetWindow(session);

  /// What the core's adapter said of the on-device model last ([_onDevice]);
  /// null when it was not asked or could not answer.
  PlatformPccStatus? _status;

  /// The on-device model as the engine says it is now; what it says also
  /// decides whether the connection is offered, unless asked again since.
  Future<AppleModelStatus> _onDevice() async {
    final ask = ++_asked;
    _status = null;
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
      if (ask == _asked) _offer(false);
      return const AppleModelStatus(
        model: AppleModelKind.onDevice,
        availability: AppleAvailability.unavailable,
        reason: AppleUnavailableReason.noEngine,
      );
    }
    if (ask == _asked) _status = status;
    final available = status.availability == PlatformPccAvailability.available;
    if (ask == _asked) _offer(available);
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

  /// A window's engine went: the offer follows the engines left, and with
  /// none that has the model it is withdrawn at once.
  void _gone() => unawaited(_onDevice());

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
///
/// One window's engine runs each request: commands go to the window that
/// said `ready` last (one whose Mac has the models first), each run keeps
/// the window that started it, and only that window's reports count for
/// it. A run's reports are numbered: one lost on the way, a tool result
/// the window cannot be given, or the window's session ending ends the run
/// here ([_end]); a window still running a run this side no longer has is
/// told to stop it.
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
  void Function()? _onGone;
  int _nextId = 0;

  /// Commands not answered yet, with the window each went to: only that
  /// window's answer counts.
  final Map<int, ({Completer<AppleReport> answer, String window})> _pending =
      <int, ({Completer<AppleReport> answer, String window})>{};

  /// The windows whose engines said `ready`, in the order they last said
  /// it, with whether this Mac has Apple's models.
  final Map<String, bool> _engines = <String, bool>{};

  /// Each run not ended, and the window whose engine runs it.
  final Map<String, String> _owners = <String, String>{};

  /// The number of the last report taken from each run.
  final Map<String, int> _numbers = <String, int>{};

  /// What the engine last said of the on-device model (for its reason).
  AppleEngineStatus? lastStatus;

  /// What the window commands go to said: whether this Mac has Apple's
  /// models; null before any said.
  bool? get supported => switch (_engine) {
    final window? => _engines[window],
    null => null,
  };

  /// The window commands go to: the last to say `ready` among those whose
  /// Mac has the models, else the last to say it.
  String? get _engine {
    String? any;
    String? able;
    for (final MapEntry(key: window, value: has) in _engines.entries) {
      any = window;
      if (has) able = window;
    }
    return able ?? any;
  }

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
        to: _engine,
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
    final engine = _engine;
    if (engine != null) {
      _owners[request.runId] = engine;
      _numbers[request.runId] = 0;
    }
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
        to: engine,
        timeout: _startTimeout,
      );
    } on Object {
      // Never started, or not known to: an engine that did start it is
      // stopped, and its reports no longer count.
      if (_owners.remove(request.runId) case final owner?) {
        _numbers.remove(request.runId);
        _stopIn(owner, request.runId);
      }
      rethrow;
    }
  }

  @override
  Future<void> cancel(String runId) async {
    final owner = _owners[runId];
    if (owner == null) return;
    await _command(
      (id) => AppleCommand(id: id, kind: AppleCommandKind.cancel, runId: runId),
      to: owner,
    );
  }

  /// A window's session ended (closed, dropped or failed): it is no
  /// engine any more, what it was asked is not answered, and its runs end
  /// with it (nothing else would finish them; an engine that comes back
  /// still holding one is told to stop it). The offer then follows the
  /// engines left.
  void forgetWindow(String window) {
    final wasEngine = _engines.remove(window) != null;
    for (final pending in _pending.values.toList()) {
      if (pending.window == window && !pending.answer.isCompleted) {
        pending.answer.completeError(StateError('the window closed'));
      }
    }
    for (final MapEntry(key: runId, value: owner) in _owners.entries.toList()) {
      if (owner == window) _end(runId, stop: false);
    }
    if (wasEngine) _onGone?.call();
  }

  /// Ends [runId] here, failed, and stops it in the window running it: the
  /// one way out for a run whose words or tool results went astray. Once.
  void _end(String runId, {bool stop = true}) {
    final owner = _owners.remove(runId);
    _numbers.remove(runId);
    if (owner == null) return;
    _event(
      PlatformPccStreamEvent(
        runId: runId,
        kind: PlatformPccEventKind.error,
        content: appleFailureMessage(AppleFailure.failed),
      ),
    );
    if (stop) _stopIn(owner, runId);
  }

  /// Tells [window]'s engine to stop [runId], if it is still connected;
  /// nothing waits for its answer.
  void _stopIn(String window, String runId) {
    if (!_engines.containsKey(window)) return;
    unawaited(
      _command(
        (id) =>
            AppleCommand(id: id, kind: AppleCommandKind.cancel, runId: runId),
        to: window,
      ).then<void>((_) {}, onError: (Object _) {}),
    );
  }

  /// Whether [report], about a run, counts: from the window running it,
  /// and next in the run's numbering. A number skipped ends the run; one
  /// already taken is a repeat.
  bool _take(AppleReport report, String from) {
    final runId = report.runId ?? '';
    if (_owners[runId] != from) return false;
    final last = _numbers[runId] ?? 0;
    final seq = report.seq;
    if (seq == null) return true;
    if (seq <= last) return false;
    if (seq > last + 1) {
      DebugLogger.warning(
        'report-lost',
        scope: 'daemon/apple',
        data: <String, Object?>{'expected': last + 1, 'got': seq},
      );
      _end(runId);
      return false;
    }
    _numbers[runId] = seq;
    return true;
  }

  /// What window [from] said: what a run did first, then the answer, so a
  /// command's caller sees the state it left.
  void report(AppleReport report, {required String from}) {
    switch (report.kind) {
      case null:
        break;
      case AppleReportKind.ready:
        _ready(from, report);
      case AppleReportKind.content ||
              AppleReportKind.usage ||
              AppleReportKind.failed ||
              AppleReportKind.done ||
              AppleReportKind.toolCall
          when !_take(report, from):
        break;
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
        _owners.remove(runId);
        _numbers.remove(runId);
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
        _owners.remove(runId);
        _numbers.remove(runId);
        _event(
          PlatformPccStreamEvent(runId: runId, kind: PlatformPccEventKind.done),
        );
      case AppleReportKind.toolCall:
        unawaited(_toolCall(report));
    }
    if (report.id case final id?) {
      final waiting = _pending[id];
      if (waiting != null &&
          waiting.window == from &&
          !waiting.answer.isCompleted) {
        waiting.answer.complete(report);
      }
    }
  }

  /// Window [from] said `ready` (it connected, or said it again): it runs
  /// commands from now on. A run it has that is not its own here (one that
  /// ended with an earlier session, or another window's) is stopped there;
  /// a run of its own that it no longer has ends here.
  void _ready(String from, AppleReport report) {
    final supported = report.supported ?? false;
    _engines
      ..remove(from)
      ..[from] = supported;
    final kept = report.runs.toSet();
    for (final runId in kept) {
      if (_owners[runId] != from) _stopIn(from, runId);
    }
    for (final MapEntry(key: runId, value: owner) in _owners.entries.toList()) {
      if (owner == from && !kept.contains(runId)) _end(runId, stop: false);
    }
    _onReady?.call(supported);
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
    // Ended meanwhile: nothing waits for it.
    final owner = _owners[runId];
    if (owner == null) return;
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
        to: owner,
      );
    } on StateError catch (error) {
      // The engine would wait for it until stopped: the run ends instead.
      DebugLogger.warning(
        'tool-result-undelivered',
        scope: 'daemon/apple',
        data: <String, Object?>{'error': error.message},
      );
      _end(runId);
    }
  }

  /// Sends a command to window [to]'s engine and waits for its answer;
  /// throws [StateError] when that window has no engine (or none is
  /// given), refuses, closes, or does not answer in time.
  Future<AppleReport> _command(
    AppleCommand Function(int id) build, {
    required String? to,
    Duration? timeout,
  }) async {
    final events = _events;
    if (events == null) throw StateError('no engine yet');
    final id = ++_nextId;
    final command = build(id);
    if (to == null || !_engines.containsKey(to)) {
      throw StateError('no window to run ${command.kind.name}');
    }
    final completer = Completer<AppleReport>();
    _pending[id] = (answer: completer, window: to);
    try {
      events.emitTo(to, ConduitEventSpecs.appleCommand, command);
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
