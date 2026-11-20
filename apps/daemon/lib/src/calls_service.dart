import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/realtime_call/realtime_call_availability.dart'
    show RealtimeCallBlock;
import 'package:conduit_core/features/chat/realtime_call/realtime_call_ports.dart';
import 'package:conduit_core/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeConversationProvider, selectedModelProvider;
import 'package:conduit_core/services/settings_service.dart'
    show VoiceCallMode, appSettingsProvider;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'event_bus.dart';
import 'speech_service.dart';
import 'turns_service.dart';

/// `calls.*`: voice calls.
///
/// The call runs here, in the core's voice-mode controller, as it runs on
/// the phone: when to listen, when to send, when the answer has been said,
/// barge-in, pause and mute, and a realtime voice when the backend offers
/// one. It runs in the scope of the chat it is in ([TurnsService]), so its
/// turns stream into that chat like typed ones.
///
/// The window is the call's microphone and speaker: it listens as dictation
/// does when asked (`calls.command` `listen`, answered with `calls.report`),
/// speaks the answers through the read-aloud engine ([SpeechService]'s
/// bridge), and for a realtime voice runs one echo-cancelled audio engine
/// over `WS /calls/{handle}` ([CallAudioLink]), or, for Hermes GPT-Live, a
/// WebRTC peer driven over the same route ([CallPeerLink]).
///
/// One call at a time, app-wide: the Mac has one microphone.
final class CallsService {
  CallsService(
    this._container, {
    required EventBus events,
    required TurnsService turns,
    required CallPorts ports,
    SpeechService? speech,
    Duration commandTimeout = const Duration(seconds: 20),
  }) : _events = events,
       _turns = turns,
       _ports = ports,
       _speech = speech,
       _commandTimeout = commandTimeout {
    ports._attach(this);
  }

  final ProviderContainer _container;
  final EventBus _events;
  final TurnsService _turns;
  final CallPorts _ports;
  final SpeechService? _speech;
  final Duration _commandTimeout;

  CallState _state = const CallState();
  int _call = 0;
  CallScopeHold? _hold;
  ChatVoiceModeController? _controller;
  final List<ProviderSubscription<Object?>> _watches =
      <ProviderSubscription<Object?>>[];
  CallAudioLink? _audio;
  CallPeerLink? _peer;
  bool _disposed = false;

  int _nextCommand = 0;
  final Map<int, Completer<CallReport>> _pending =
      <int, Completer<CallReport>>{};

  /// The call now.
  CallState get() => _state;

  bool get _active => switch (_state.phase) {
    CallPhase.idle || CallPhase.ended || CallPhase.error => false,
    _ => true,
  };

  /// Starts a call in [request]'s chat, or in a new one. Answers at once,
  /// starting; `calls.changed` follows it.
  Future<CallState> start(CallStart request) async {
    if (_disposed) {
      throw const RpcError(
        code: ConduitErrorCodes.shuttingDown,
        debugMessage: 'the daemon is stopping',
      );
    }
    if (_active) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'a call is already on',
      );
    }
    // The call owns the speaker: a reading stops.
    try {
      await _speech?.stop();
    } on Object catch (error) {
      DebugLogger.warning(
        'call-reading-stop-failed',
        scope: 'daemon/calls',
        data: {'error': error.toString()},
      );
    }
    final call = ++_call;
    _publish(
      CallState(
        phase: CallPhase.starting,
        call: call,
        chatId: request.chatId,
        startedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final CallScopeHold hold;
    try {
      hold = await _turns.holdForCall(
        chatId: request.chatId,
        model: request.model,
        folderId: request.folderId,
        temporary: request.temporary,
      );
    } on Object {
      if (_call == call) _publish(CallState(call: call));
      rethrow;
    }
    if (_call != call || _state.phase != CallPhase.starting) {
      // Ended while the chat opened.
      hold.release();
      return _state;
    }
    _hold = hold;
    final scope = hold.scope.container;
    final controller = scope.read(chatVoiceModeControllerProvider.notifier);
    _controller = controller;
    _watches
      ..add(
        scope.listen<ChatVoiceModeSnapshot>(
          chatVoiceModeControllerProvider,
          (_, next) => _follow(call, next),
        ),
      )
      ..add(
        scope.listen<Object?>(
          activeConversationProvider,
          (_, _) => _follow(call, scope.read(chatVoiceModeControllerProvider)),
        ),
      );
    unawaited(
      controller
          .start(startNewConversation: request.chatId == null)
          .then(
            (result) => _started(call, result),
            onError: (Object error, StackTrace stackTrace) {
              DebugLogger.error(
                'call-start-failed',
                scope: 'daemon/calls',
                error: error,
                stackTrace: stackTrace,
              );
              _ended(call, error: error.toString());
            },
          ),
    );
    return _state;
  }

  void _started(int call, ChatVoiceModeStartResult result) {
    if (call != _call) return;
    final controller = _controller;
    if (controller == null) return;
    switch (result) {
      case ChatVoiceModeStartResult.started:
      case ChatVoiceModeStartResult.alreadyActive:
        _follow(call, _snapshot ?? const ChatVoiceModeSnapshot());
      case ChatVoiceModeStartResult.cancelled:
      case ChatVoiceModeStartResult.failed:
        _ended(call);
    }
  }

  ChatVoiceModeSnapshot? get _snapshot {
    final hold = _hold;
    if (hold == null || hold.scope.isDisposed) return null;
    return hold.scope.container.read(chatVoiceModeControllerProvider);
  }

  /// Ends the call.
  Future<CallState> end() async {
    final controller = _controller;
    final call = _call;
    if (controller == null) {
      if (_active) _publish(_state.copyWith(phase: CallPhase.ended));
      return _state;
    }
    try {
      await controller.stop();
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'call-end-failed',
        scope: 'daemon/calls',
        error: error,
        stackTrace: stackTrace,
      );
    }
    _ended(call);
    return _state;
  }

  Future<CallState> pause() => _act((c) => c.pause());
  Future<CallState> resume() => _act((c) => c.resume());
  Future<CallState> mute() => _act((c) => c.toggleMute());
  Future<CallState> skip() => _act((c) => c.cancelSpeaking());

  Future<CallState> _act(
    Future<void> Function(ChatVoiceModeController controller) action,
  ) async {
    final controller = _controller;
    if (controller == null || !_active) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'there is no call',
      );
    }
    await action(controller);
    return _state;
  }

  /// The window answered a `calls.command`, or says what a listen did.
  void report(CallReport report) {
    if (report.kind != null) _ports.input._report(report);
    if (report.id case final id?) {
      final waiting = _pending[id];
      if (waiting != null && !waiting.isCompleted) waiting.complete(report);
    }
  }

  /// Sends [build]'s command to the window and waits for its answer.
  Future<CallReport> _command(
    CallCommand Function(int id) build, {
    Duration? timeout,
  }) async {
    final id = ++_nextCommand;
    final completer = Completer<CallReport>();
    _pending[id] = completer;
    final command = build(id);
    try {
      final reached = _events.emit(ConduitEventSpecs.callsCommand, command);
      if (reached == 0) {
        throw StateError('no window for ${command.kind.name}');
      }
      return await completer.future.timeout(timeout ?? _commandTimeout);
    } on TimeoutException {
      throw StateError('the window did not answer ${command.kind.name}');
    } finally {
      _pending.remove(id);
    }
  }

  /// Sends a command without waiting for its answer.
  void _tell(CallCommand Function(int id) build) {
    final id = ++_nextCommand;
    _events.emit(ConduitEventSpecs.callsCommand, build(id));
  }

  /// What the window's realtime audio connects to, for the call under way.
  CallAudioLink? _newAudio() {
    if (_disposed) return null;
    final previous = _audio;
    if (previous != null) unawaited(previous.stop());
    final audio = _audio = CallAudioLink._(this, _token());
    return audio;
  }

  /// What the window's WebRTC peer connects to, for the call under way.
  CallPeerLink? _newPeer() {
    if (_disposed) return null;
    final previous = _peer;
    if (previous != null) unawaited(previous.close());
    return _peer = CallPeerLink._(this, _token());
  }

  /// `WS /calls/{handle}`: the window's realtime audio or WebRTC peer for
  /// the call (a WebSocket; any channel of its frames in a test).
  Future<void> tunnel(String handle, StreamChannel<dynamic> window) async {
    final audio = _audio;
    if (audio != null && audio.handle == handle && !audio._stopped) {
      await audio._attach(window);
      return;
    }
    final peer = _peer;
    if (peer != null && peer.handle == handle && !peer._stopped) {
      await peer._attach(window);
      return;
    }
    await _refuse(window, 4404, 'no such call');
  }

  /// Whether [handle] is the call's realtime audio or WebRTC peer now.
  bool knowsAudio(String handle) =>
      _audio?.handle == handle || _peer?.handle == handle;

  void _follow(int call, ChatVoiceModeSnapshot snapshot) {
    if (call != _call || _hold == null) return;
    final controller = _controller;
    final hold = _hold!;
    final scope = hold.scope.isDisposed ? null : hold.scope.container;
    final model = scope?.read(selectedModelProvider);
    final realtime = controller?.isRealtimeCall ?? false;
    final settingsRealtime =
        _container.read(appSettingsProvider).voiceCallMode ==
        VoiceCallMode.auto;
    final phase = _phaseOf(snapshot.phase);
    _publish(
      CallState(
        phase: phase,
        call: call,
        mode: switch (phase) {
          CallPhase.starting when !realtime => null,
          _ => realtime ? CallMode.realtime : CallMode.standard,
        },
        chatId: hold.chatId ?? _state.chatId,
        modelId: model?.id,
        modelName: model?.name,
        transcript: snapshot.transcript,
        // What is being said: the sentence the voice says now (as the
        // speech splitter left it, without markdown), or the realtime
        // voice's caption.
        reply: snapshot.spokenResponse.trim().isNotEmpty
            ? snapshot.spokenResponse
            : snapshot.assistantPreview,
        level: (snapshot.intensity / 10).clamp(0, 1).toDouble(),
        muted: snapshot.isMuted,
        canPause: snapshot.canPause,
        canResume: snapshot.canResume,
        startedAtMs:
            snapshot.startedAt?.millisecondsSinceEpoch ?? _state.startedAtMs,
        errorKind: _errorKindOf(snapshot.errorKind),
        error: snapshot.errorMessage,
        notice: _noticeOf(snapshot.notice),
        noticeCount: snapshot.noticeCount,
        refusal: switch (snapshot.refusal) {
          null => null,
          VoiceCallRefusal.modelRequired => CallRefusal.modelRequired,
          VoiceCallRefusal.hermesLoading => CallRefusal.hermesLoading,
          VoiceCallRefusal.hermesUnavailable => CallRefusal.hermesUnavailable,
          VoiceCallRefusal.directUnavailable => CallRefusal.directUnavailable,
          VoiceCallRefusal.signInRequired => CallRefusal.signInRequired,
          VoiceCallRefusal.backendUnsupported => CallRefusal.backendUnsupported,
        },
        standardReason: realtime || !settingsRealtime
            ? null
            : controller?.realtimeAudioMissing ?? false
            ? CallStandardReason.noAudio
            : _reasonOf(controller?.realtimeBlock),
      ),
    );
    if (!snapshot.isActive &&
        snapshot.phase != ChatVoiceModePhase.idle &&
        phase != CallPhase.starting) {
      _ended(call, keep: true);
    }
  }

  /// The call is over: its chat is let go, and its last state stays for
  /// the window ([keep]: an error to show).
  void _ended(int call, {bool keep = false, String? error}) {
    if (call != _call) return;
    for (final watch in _watches) {
      watch.close();
    }
    _watches.clear();
    _controller = null;
    final hold = _hold;
    _hold = null;
    final chatId = hold?.chatId ?? _state.chatId;
    hold?.release();
    final audio = _audio;
    _audio = null;
    if (audio != null) unawaited(audio.stop());
    final peer = _peer;
    _peer = null;
    if (peer != null) unawaited(peer.close());
    _ports.input._end();
    if (keep && _state.phase == CallPhase.error) {
      _publish(_state.copyWith(chatId: chatId, level: 0));
      return;
    }
    if (error != null) {
      _publish(
        CallState(
          phase: CallPhase.error,
          call: call,
          chatId: chatId,
          errorKind: CallErrorKind.other,
          error: error,
        ),
      );
      return;
    }
    _publish(
      CallState(
        phase: _state.phase == CallPhase.error
            ? CallPhase.error
            : CallPhase.ended,
        call: call,
        chatId: chatId,
        mode: _state.mode,
        errorKind: _state.errorKind,
        error: _state.error,
      ),
    );
  }

  void _publish(CallState next) {
    if (next == _state) return;
    _state = next;
    _events.emit(ConduitEventSpecs.callsChanged, next);
  }

  /// Ends any call, and lets go of the window's audio.
  Future<void> dispose() async {
    _disposed = true;
    final controller = _controller;
    if (controller != null) {
      try {
        await controller.stop().timeout(const Duration(seconds: 5));
      } on Object {
        // Shutting down regardless.
      }
    }
    _ended(_call);
    for (final waiting in _pending.values) {
      if (!waiting.isCompleted) {
        waiting.completeError(StateError('the daemon is stopping'));
      }
    }
    _pending.clear();
  }

  static final Random _random = Random.secure();

  static String _token() => List<String>.generate(
    24,
    (_) => _random.nextInt(16).toRadixString(16),
  ).join();

  static CallPhase _phaseOf(ChatVoiceModePhase phase) => switch (phase) {
    ChatVoiceModePhase.idle => CallPhase.idle,
    ChatVoiceModePhase.starting => CallPhase.starting,
    ChatVoiceModePhase.listening => CallPhase.listening,
    ChatVoiceModePhase.sending => CallPhase.sending,
    ChatVoiceModePhase.speaking => CallPhase.speaking,
    ChatVoiceModePhase.paused => CallPhase.paused,
    ChatVoiceModePhase.muted => CallPhase.muted,
    ChatVoiceModePhase.ending => CallPhase.ending,
    ChatVoiceModePhase.ended => CallPhase.ended,
    ChatVoiceModePhase.error => CallPhase.error,
  };

  static CallErrorKind? _errorKindOf(ChatVoiceModeError? kind) =>
      switch (kind) {
        null => null,
        ChatVoiceModeError.microphoneDenied => CallErrorKind.microphoneDenied,
        ChatVoiceModeError.inputUnavailable => CallErrorKind.inputUnavailable,
        ChatVoiceModeError.timeout => CallErrorKind.timeout,
        ChatVoiceModeError.noSpeech => CallErrorKind.noSpeech,
        ChatVoiceModeError.message => CallErrorKind.message,
        ChatVoiceModeError.other => CallErrorKind.other,
      };

  static CallNotice? _noticeOf(ChatVoiceModeNotice? notice) => switch (notice) {
    null => null,
    ChatVoiceModeNotice.transcriptionFailed => CallNotice.transcriptionFailed,
    ChatVoiceModeNotice.replyIncomplete => CallNotice.replyIncomplete,
    ChatVoiceModeNotice.transcriptNotSaved => CallNotice.transcriptNotSaved,
  };

  static CallStandardReason? _reasonOf(
    RealtimeCallBlock? block,
  ) => switch (block) {
    null => null,
    RealtimeCallBlock.standardChosen => CallStandardReason.standardChosen,
    RealtimeCallBlock.temporaryChat => CallStandardReason.temporaryChat,
    RealtimeCallBlock.unsupportedBackend =>
      CallStandardReason.unsupportedBackend,
    RealtimeCallBlock.voiceProviderIncomplete =>
      CallStandardReason.voiceProviderIncomplete,
    RealtimeCallBlock.serverRealtimeOff => CallStandardReason.serverRealtimeOff,
    RealtimeCallBlock.callNotPermitted => CallStandardReason.callNotPermitted,
    RealtimeCallBlock.noSessionToken => CallStandardReason.noSessionToken,
    RealtimeCallBlock.hermesVoiceLiveOff =>
      CallStandardReason.hermesVoiceLiveOff,
  };
}

/// The window as the core's call ports, bound in the root container before
/// any call ([CallPorts.input], [CallPorts.newRealtimeAudio]) and pointed at
/// the calls service once it exists.
final class CallPorts {
  CallPorts();

  /// The call's microphone: the window listening as dictation does.
  final CallInputBridge input = CallInputBridge._();
  CallsService? _service;

  void _attach(CallsService service) {
    _service = service;
    input._service = service;
  }

  /// The window's realtime audio for a call, or null before the daemon can
  /// reach a window.
  RealtimePcmAudioPort? newRealtimeAudio() => _service?._newAudio();

  /// The window's WebRTC peer for a Hermes GPT-Live call, or null before
  /// the daemon can reach a window.
  RealtimeWebRtcMediaPort? newWebRtcMedia() => _service?._newPeer();
}

/// The window's listening as the core's [VoiceModeInput]: each listen is a
/// `calls.command` `listen`, and the window reports the words, the meter and
/// the end with `calls.report`.
///
/// With barge-in on, a listen goes on after each pause until it is stopped,
/// so the user can talk over the answer: the window's microphone runs on
/// the voice-processing unit, which keeps the answer out of what it hears.
final class CallInputBridge implements VoiceModeInput {
  CallInputBridge._();

  CallsService? _service;
  int _listen = 0;
  bool _listening = false;
  bool _continuous = false;
  bool _sendable = false;
  StreamController<VoiceTranscriptEvent>? _words;
  final StreamController<int> _intensity = StreamController<int>.broadcast();

  bool get _bargeIn {
    final service = _service;
    if (service == null) return false;
    return service._container.read(appSettingsProvider).voiceBargeInEnabled;
  }

  String? get _modelId {
    final hold = _service?._hold;
    if (hold == null || hold.scope.isDisposed) return null;
    return hold.scope.container.read(selectedModelProvider)?.id;
  }

  @override
  bool get hasLocalStt => true;
  @override
  bool get hasServerStt => true;
  @override
  bool get prefersServerOnly => false;

  /// A listen that goes on through the answer, for barge-in.
  @override
  bool get willUseNativeLocalStt => _bargeIn;
  @override
  bool get isUsingNativeLocalStt => _listening && _continuous;
  @override
  bool get isListening => _listening;
  @override
  bool get isHoldingServerRecorderForResponse => false;
  @override
  bool get lastCompletedTranscriptSendable => _sendable;
  @override
  Stream<int> get intensityStream => _intensity.stream;
  @override
  Stream<Object> get responseCaptureFailures => const Stream<Object>.empty();

  @override
  Future<bool> initialize({bool forceLocalStt = false}) async =>
      _service != null;

  @override
  Future<bool> checkPermissions() async {
    final service = _service;
    if (service == null) return false;
    try {
      // The system's prompt can take the user a while.
      final report = await service._command(
        (id) => CallCommand(id: id, kind: CallCommandKind.permission),
        timeout: const Duration(minutes: 2),
      );
      return report.ok && (report.value ?? false);
    } on Object catch (error) {
      DebugLogger.warning(
        'call-permission-failed',
        scope: 'daemon/calls',
        data: {'error': error.toString()},
      );
      return false;
    }
  }

  @override
  Future<Stream<VoiceTranscriptEvent>> beginListeningEvents({
    bool iosAudioSessionManagedExternally = false,
  }) async {
    final service = _service;
    if (service == null) {
      throw StateError('no window to listen');
    }
    _end();
    final listen = ++_listen;
    _continuous = _bargeIn;
    _sendable = false;
    _listening = true;
    final words = _words = StreamController<VoiceTranscriptEvent>();
    service._tell(
      (id) => CallCommand(
        id: id,
        kind: CallCommandKind.listen,
        listen: listen,
        continuous: _continuous,
        modelId: _modelId,
      ),
    );
    return words.stream;
  }

  @override
  Future<bool> prepareResponseWaitHandoff() async {
    await stopListening();
    return false;
  }

  @override
  Future<void> stopListening() async {
    if (_listening) {
      final listen = _listen;
      _service?._tell(
        (id) => CallCommand(
          id: id,
          kind: CallCommandKind.stopListen,
          listen: listen,
        ),
      );
    }
    _end();
  }

  void _report(CallReport report) {
    if (report.listen != _listen || !_listening) return;
    final words = _words;
    switch (report.kind) {
      case CallReportKind.words:
        final text = report.text ?? '';
        if (report.done && text.trim().isNotEmpty) _sendable = true;
        words?.add(VoiceTranscriptEvent(text: text, isFinal: report.done));
      case CallReportKind.level:
        final level = report.level ?? 0;
        _intensity.add((level * 10).round().clamp(0, 10));
      case CallReportKind.ended:
        _end();
      case CallReportKind.failed:
        words?.addError(
          CallListenFailed(
            report.failure ?? CallListenFailure.microphoneDenied,
          ),
        );
        _end();
      case null:
        break;
    }
  }

  void _end() {
    _listening = false;
    final words = _words;
    _words = null;
    if (words != null && !words.isClosed) unawaited(words.close());
  }
}

/// A listen the window could not carry on.
final class CallListenFailed implements Exception {
  const CallListenFailed(this.failure);

  final CallListenFailure failure;

  @override
  String toString() => 'The microphone could not listen (${failure.name}).';
}

/// The window's realtime audio as the core's [RealtimePcmAudioPort]: the
/// microphone and the voice on one echo-cancelled engine in the window, over
/// `WS /calls/{handle}`.
///
/// Binary frames from the window are the microphone's PCM (24 kHz mono
/// 16-bit, 40 ms each); text frames are JSON: from the daemon `capture`,
/// `enqueue` (with the PCM in base64), `end`, `hold`, `clear` and `stop`;
/// from the window `started`, `report`, `cleared` and `failure`.
final class CallAudioLink implements RealtimePcmAudioPort {
  CallAudioLink._(this._service, this.handle);

  final CallsService _service;
  final String handle;

  StreamChannel<dynamic>? _socket;
  StreamSubscription<Object?>? _socketSubscription;
  final Completer<void> _opened = Completer<void>();
  bool _stopped = false;
  Duration _latency = Duration.zero;
  final StreamController<Uint8List> _capture =
      StreamController<Uint8List>.broadcast();
  final StreamController<RealtimePlaybackReport> _reports =
      StreamController<RealtimePlaybackReport>.broadcast();
  final StreamController<String> _failures =
      StreamController<String>.broadcast();
  final Map<int, Completer<List<RealtimeRenderedItem>>> _clears =
      <int, Completer<List<RealtimeRenderedItem>>>{};

  String get path => '/calls/$handle';

  @override
  Future<void> start() async {
    if (_stopped) throw StateError('the call ended');
    final report = await _service._command(
      (id) => CallCommand(
        id: id,
        kind: CallCommandKind.audioStart,
        path: path,
        modelId: _service._ports.input._modelId,
      ),
      timeout: const Duration(minutes: 2),
    );
    if (!report.ok) {
      throw StateError(report.error ?? 'the audio did not start');
    }
    await _opened.future.timeout(const Duration(seconds: 10));
  }

  Future<void> _attach(StreamChannel<dynamic> socket) async {
    if (_socket != null) {
      await _refuse(socket, 4409, 'already connected');
      return;
    }
    _socket = socket;
    final done = Completer<void>();
    _socketSubscription = socket.stream.listen(
      _frame,
      onError: (Object _) => _lost(),
      onDone: () {
        _lost();
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future;
  }

  void _frame(Object? data) {
    if (data is List<int>) {
      if (!_capture.isClosed) {
        _capture.add(data is Uint8List ? data : Uint8List.fromList(data));
      }
      return;
    }
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    switch (decoded['type']) {
      case 'started':
        final latency = decoded['latencyMs'];
        if (latency is num) {
          _latency = Duration(milliseconds: latency.round());
        }
        if (!_opened.isCompleted) _opened.complete();
      case 'report':
        if (_reports.isClosed) return;
        _reports.add(
          RealtimePlaybackReport(
            clearId: _int(decoded['clearId']),
            playbackActive: decoded['playbackActive'] == true,
            queuedSamples: _int(decoded['queuedSamples']),
            receivedSamples: _int(decoded['receivedSamples']),
            inputLevel: _double(decoded['inputLevel']),
            outputLevel: _double(decoded['outputLevel']),
          ),
        );
      case 'cleared':
        final waiting = _clears.remove(_int(decoded['clearId']));
        if (waiting == null || waiting.isCompleted) return;
        final items = decoded['items'];
        waiting.complete(<RealtimeRenderedItem>[
          if (items is List)
            for (final item in items)
              if (item is Map)
                (
                  responseId: '${item['responseId'] ?? ''}',
                  itemId: '${item['itemId'] ?? ''}',
                  contentIndex: _int(item['contentIndex']),
                  samples: _int(item['samples']),
                ),
        ]);
      case 'failure':
        final message = decoded['message'];
        if (!_failures.isClosed) {
          _failures.add(
            message is String ? message : 'The microphone stopped working.',
          );
        }
    }
  }

  void _lost() {
    if (_stopped) return;
    if (!_failures.isClosed) _failures.add('The call audio stopped.');
  }

  void _send(Map<String, Object?> message) {
    if (_stopped) return;
    _socket?.sink.add(jsonEncode(message));
  }

  @override
  Stream<Uint8List> get captureFrames => _capture.stream;

  @override
  Stream<RealtimePlaybackReport> get reports => _reports.stream;

  @override
  Stream<String> get failures => _failures.stream;

  @override
  void setCaptureEnabled(bool enabled) =>
      _send(<String, Object?>{'type': 'capture', 'enabled': enabled});

  @override
  void enqueue({
    required String responseId,
    required String itemId,
    required int contentIndex,
    required Uint8List pcm,
  }) => _send(<String, Object?>{
    'type': 'enqueue',
    'responseId': responseId,
    'itemId': itemId,
    'contentIndex': contentIndex,
    'pcm': base64.encode(pcm),
  });

  @override
  void endResponse(String responseId) =>
      _send(<String, Object?>{'type': 'end', 'responseId': responseId});

  @override
  void setPlaybackPaused(bool paused) =>
      _send(<String, Object?>{'type': 'hold', 'paused': paused});

  @override
  Future<List<RealtimeRenderedItem>> clear(int clearId) async {
    if (_stopped || _socket == null) return const <RealtimeRenderedItem>[];
    final completer = Completer<List<RealtimeRenderedItem>>();
    _clears[clearId] = completer;
    _send(<String, Object?>{'type': 'clear', 'clearId': clearId});
    try {
      return await completer.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      return const <RealtimeRenderedItem>[];
    } finally {
      _clears.remove(clearId);
    }
  }

  @override
  Duration get outputLatency => _latency;

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _send(<String, Object?>{'type': 'stop'});
    _stopped = true;
    _service._tell(
      (id) => CallCommand(id: id, kind: CallCommandKind.audioStop, path: path),
    );
    await _socketSubscription?.cancel();
    await _socket?.sink.close();
    for (final waiting in _clears.values) {
      if (!waiting.isCompleted) {
        waiting.complete(const <RealtimeRenderedItem>[]);
      }
    }
    _clears.clear();
    await _capture.close();
    await _reports.close();
    await _failures.close();
  }

  static int _int(Object? value) => value is num ? value.toInt() : 0;
  static double _double(Object? value) => value is num ? value.toDouble() : 0.0;
}

/// The window's WebRTC peer as the core's [RealtimeWebRtcMediaPort], for a
/// Hermes GPT-Live call: a hidden web view in the window runs the
/// `RTCPeerConnection`, with the microphone (the system's echo cancellation
/// on) and the voice played, and the voice's data channel. The core's
/// GPT-Live engine signals through it; the gateway answers the offer.
///
/// Over `WS /calls/{handle}`, text frames of JSON: from the daemon `offer`
/// (`dataChannel`), `answer` (`sdp`), `send` (`text`), `mic` (`enabled`)
/// and `stop`; from the window `ready`, `offer` (`sdp`), `answered`,
/// `message` (`text`), `state` (`connecting`, `connected`, `failed`,
/// `closed`), `levels` (`input`, `output`, 0 to 1) and `failure`
/// (`reason`: `microphone` or another; `message` for the log).
final class CallPeerLink implements RealtimeWebRtcMediaPort {
  CallPeerLink._(this._service, this.handle);

  final CallsService _service;
  final String handle;

  StreamChannel<dynamic>? _socket;
  StreamSubscription<Object?>? _socketSubscription;
  final Completer<void> _ready = Completer<void>();
  Completer<String>? _offer;
  Completer<void>? _answered;
  bool _stopped = false;

  /// Completed by [close]: every wait of the link ends with it (the
  /// window's answer to `webRtcStart`, its `ready`, its socket).
  final Completer<void> _closing = Completer<void>();
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<RealtimeMediaState> _states =
      StreamController<RealtimeMediaState>.broadcast();
  final StreamController<RealtimeMediaLevels> _levels =
      StreamController<RealtimeMediaLevels>.broadcast();

  String get path => '/calls/$handle';

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<RealtimeMediaState> get states => _states.stream;

  @override
  Stream<RealtimeMediaLevels> get levels => _levels.stream;

  @override
  Future<String> createOffer({String dataChannel = 'oai-events'}) async {
    if (_stopped) throw StateError('The voice call ended.');
    final report = await _untilClosed(
      _service._command(
        (id) =>
            CallCommand(id: id, kind: CallCommandKind.webRtcStart, path: path),
        // The system may ask the user for the microphone first.
        timeout: const Duration(minutes: 2),
      ),
    );
    if (!report.ok) throw _PeerFailed(report.error ?? 'the peer did not start');
    await _untilClosed(_ready.future.timeout(const Duration(seconds: 10)));
    if (_stopped) throw StateError('The voice call ended.');
    final offer = _offer = Completer<String>();
    _send(<String, Object?>{'type': 'offer', 'dataChannel': dataChannel});
    // The page waits for every ICE candidate (at most 10 s) before it
    // answers, as the offer is sent once, whole.
    return offer.future.timeout(const Duration(seconds: 30));
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    if (_stopped) throw StateError('The voice call ended.');
    final answered = _answered = Completer<void>();
    _send(<String, Object?>{'type': 'answer', 'sdp': sdp});
    await answered.future.timeout(const Duration(seconds: 10));
  }

  Future<void> _attach(StreamChannel<dynamic> socket) async {
    if (_socket != null) {
      await _refuse(socket, 4409, 'already connected');
      return;
    }
    _socket = socket;
    final done = Completer<void>();
    _socketSubscription = socket.stream.listen(
      _frame,
      onError: (Object _) => _lost(),
      onDone: () {
        _lost();
        if (!done.isCompleted) done.complete();
      },
    );
    // Closed while the window's socket is open: the cancelled listener
    // hears no end of it, so the close ends this wait.
    await Future.any<void>(<Future<void>>[done.future, _closing.future]);
  }

  /// [wait], unless [close] comes first: then the call's end.
  Future<T> _untilClosed<T>(Future<T> wait) => Future.any<T>(<Future<T>>[
    wait,
    _closing.future.then<T>((_) => throw StateError('The voice call ended.')),
  ]);

  void _frame(Object? data) {
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    switch (decoded['type']) {
      case 'ready':
        if (!_ready.isCompleted) _ready.complete();
      case 'offer':
        final sdp = decoded['sdp'];
        final offer = _offer;
        if (offer == null || offer.isCompleted) return;
        if (sdp is String && sdp.trim().isNotEmpty) {
          offer.complete(sdp);
        } else {
          offer.completeError(StateError('Could not prepare the voice call.'));
        }
      case 'answered':
        final answered = _answered;
        if (answered != null && !answered.isCompleted) answered.complete();
      case 'message':
        final text = decoded['text'];
        if (text is String && !_messages.isClosed) _messages.add(text);
      case 'state':
        final state = switch (decoded['state']) {
          'connected' => RealtimeMediaState.connected,
          'failed' => RealtimeMediaState.failed,
          'closed' => RealtimeMediaState.closed,
          _ => RealtimeMediaState.connecting,
        };
        if (!_states.isClosed) _states.add(state);
      case 'levels':
        if (_levels.isClosed) return;
        _levels.add((
          input: CallAudioLink._double(decoded['input']).clamp(0.0, 1.0),
          output: CallAudioLink._double(decoded['output']).clamp(0.0, 1.0),
        ));
      case 'failure':
        _failed(
          decoded['reason'] == 'microphone'
              ? StateError('The microphone could not be opened.')
              : _PeerFailed('${decoded['message'] ?? 'the peer failed'}'),
        );
    }
  }

  /// What the window could not do: the step waiting for it fails, or, once
  /// the call is up, the call does.
  void _failed(Object error) {
    DebugLogger.warning(
      'call-peer-failed',
      scope: 'daemon/calls',
      data: {'error': error.toString()},
    );
    final offer = _offer;
    final answered = _answered;
    if (offer != null && !offer.isCompleted) {
      offer.completeError(error);
    } else if (answered != null && !answered.isCompleted) {
      answered.completeError(error);
    } else if (!_states.isClosed) {
      _states.add(RealtimeMediaState.failed);
    }
  }

  void _lost() {
    if (_stopped) return;
    _failed(_PeerFailed('the window closed the peer'));
  }

  void _send(Map<String, Object?> message) {
    if (_stopped) return;
    _socket?.sink.add(jsonEncode(message));
  }

  @override
  void send(String message) =>
      _send(<String, Object?>{'type': 'send', 'text': message});

  @override
  void setMicrophoneEnabled(bool enabled) =>
      _send(<String, Object?>{'type': 'mic', 'enabled': enabled});

  @override
  Future<void> close() async {
    if (_stopped) return;
    _send(<String, Object?>{'type': 'stop'});
    _stopped = true;
    _closing.complete();
    _service._tell(
      (id) => CallCommand(id: id, kind: CallCommandKind.audioStop, path: path),
    );
    final ended = StateError('The voice call ended.');
    final offer = _offer;
    if (offer != null && !offer.isCompleted) offer.completeError(ended);
    final answered = _answered;
    if (answered != null && !answered.isCompleted) {
      answered.completeError(ended);
    }
    await _socketSubscription?.cancel();
    await _socket?.sink.close();
    await _messages.close();
    await _states.close();
    await _levels.close();
  }
}

/// What the window's peer could not do, for the log; the call says only
/// that it could not start.
final class _PeerFailed implements Exception {
  const _PeerFailed(this.detail);

  final String detail;

  @override
  String toString() => 'The WebRTC peer failed: $detail';
}

/// Closes [channel], with [code] and [reason] when it is a WebSocket.
Future<void> _refuse(StreamChannel<dynamic> channel, int code, String reason) {
  final sink = channel.sink;
  return sink is WebSocketSink ? sink.close(code, reason) : sink.close();
}
