import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/read_aloud/device_speech_engine.dart';
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_controller.dart';
import 'package:conduit_core/features/chat/read_aloud/tts_manager.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart'
    show serverSpeechProviderFor, serverSpeechProviderProvider;
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/ports/audio_playback_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart'
    show isLibreChatModel;
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart'
    show libreChatServerSpeechProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';
import 'voice_service.dart';

/// `speech.*`: read aloud.
///
/// The reading runs here, in the core's manager and controller, as it runs
/// on the phone: the sentences, the queue, the server's speech, the state
/// the window draws. The window is only its voice and its player: the
/// manager's device engine and audio player are [SpeechBridge]'s, which
/// put each step to the window as `speech.command` and hear back through
/// `speech.report`. Server speech reaches the window's player as
/// `GET /tts/{job}`.
final class SpeechService {
  SpeechService(
    this._container, {
    required EventBus events,
    required VoiceService voice,
    Future<({String content, String? model})> Function(
      String chatId,
      String messageId,
    )?
    answerFor,
    Future<ServerSpeechProvider?> Function(String? modelId)? speechFor,
  }) : _events = events,
       _answerFor = answerFor,
       _speechForModel = speechFor,
       bridge = SpeechBridge(events) {
    // The manager is made once, on first use, from these factories.
    bridge.attach();
    DeviceSpeechEngine.hostFactory = () => SpeechBridge.device;
    AudioPlaybackPort.hostFactory = () => SpeechBridge.player;
    TtsManager.clipStore = JobClipStore(voice);
    _subscription = _container.listen<TextToSpeechState>(
      textToSpeechControllerProvider,
      (previous, next) => _changed(next),
    );
  }

  final ProviderContainer _container;
  final EventBus _events;
  final Future<({String content, String? model})> Function(
    String chatId,
    String messageId,
  )?
  _answerFor;

  /// The speech of a model's backend (the core's rule unless a test says).
  final Future<ServerSpeechProvider?> Function(String? modelId)?
  _speechForModel;

  /// The window's speech engine, as the core's ports.
  final SpeechBridge bridge;
  ProviderSubscription<TextToSpeechState>? _subscription;

  /// The sentences the last reading had, and its number.
  List<String> _sentences = const <String>[];
  int _reading = 0;

  /// Moves on with every Read Aloud and Stop: a Read Aloud still looking up
  /// its answer starts nothing once a newer one or a Stop came.
  int _toggles = 0;

  TextToSpeechController get _controller =>
      _container.read(textToSpeechControllerProvider.notifier);

  TextToSpeechState get _state =>
      _container.read(textToSpeechControllerProvider);

  /// The reading now, with its sentences.
  SpeechState get() =>
      SpeechState(progress: _progress(_state), sentences: _state.sentences);

  /// Reads answer [request.messageId] aloud, or stops it (resumes it when
  /// paused). Answers at once: the reading starts behind it, and
  /// `speech.changed` follows it.
  Future<SpeechState> toggle(SpeechToggle request) async {
    final toggle = ++_toggles;
    final state = _state;
    final same = state.activeMessageId == request.messageId;
    if (same &&
        state.status != TtsPlaybackStatus.idle &&
        state.status != TtsPlaybackStatus.error) {
      // Stop, or resume when paused: what the controller does for it.
      await _controller.readAloud(
        messageId: request.messageId,
        text: '',
        chatId: request.chatId,
      );
      return get();
    }
    final lookup = _answerFor;
    if (lookup == null) {
      throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        debugMessage: 'the core is not up yet',
      );
    }
    final answer = await lookup(request.chatId, request.messageId);
    if (toggle != _toggles) return get();
    final text = readAloudTextOf(answer.content);
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'that answer has nothing to read',
      );
    }
    // Text is only spoken by the backend of the model that wrote it.
    final speechFor = await _speechFor(answer.model);
    if (toggle != _toggles) return get();
    TtsManager.instance.setServerSpeech(speechFor);
    unawaited(
      _controller.readAloud(
        messageId: request.messageId,
        text: text,
        chatId: request.chatId,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    return get();
  }

  Future<SpeechState> pause() async {
    await _controller.pause();
    return get();
  }

  Future<SpeechState> resume() async {
    await _controller.resume();
    return get();
  }

  Future<SpeechState> stop() async {
    _toggles++;
    await _controller.stop();
    return get();
  }

  Future<SpeechState> retry() async {
    unawaited(_controller.retry());
    await Future<void>.delayed(Duration.zero);
    return get();
  }

  /// Moves to a sentence, by some sentences, or to a time. Answers at once;
  /// server speech may still be getting there.
  Future<SpeechState> seek(SpeechSeek request) async {
    final Future<void> moving;
    if (request.sentence case final sentence?) {
      moving = _controller.seekToSentence(sentence);
    } else if (request.by case final by?) {
      moving = _controller.skipSentences(by);
    } else if (request.ms case final ms?) {
      moving = _controller.seekTo(Duration(milliseconds: ms));
    } else {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a sentence, a number of sentences, or a time',
      );
    }
    unawaited(moving);
    await Future<void>.delayed(Duration.zero);
    return get();
  }

  /// Settings' sample, in the chosen engine, voice and speed; again stops it.
  Future<SpeechState> preview(SpeechPreview request) async {
    final state = _state;
    if (state.isSpeaking || state.isBusy) {
      await _controller.stop();
      return get();
    }
    TtsManager.instance.setServerSpeech(
      _container.read(serverSpeechProviderProvider),
    );
    unawaited(
      _controller.toggleForMessage(
        messageId: previewMessageId,
        text: request.text,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    return get();
  }

  /// The window's engine answered a command, or says what it did.
  void report(SpeechReport report) => bridge.report(report);

  /// Stops what is reading, and lets go of the controller.
  Future<void> dispose() async {
    _subscription?.close();
    _subscription = null;
    await TtsManager.instance.stop();
  }

  /// The message id of Settings' preview, as the phone names it.
  static const String previewMessageId = 'tts_preview';

  Future<ServerSpeechProvider?> _speechFor(String? modelId) async {
    if (_speechForModel case final speechFor?) return speechFor(modelId);
    return speechForModel(_container, modelId);
  }

  /// Speech for model [modelId]'s backend, by the core's rule.
  static Future<ServerSpeechProvider?> speechForModel(
    ProviderContainer container,
    String? modelId,
  ) async {
    Model? model;
    if (modelId != null && modelId.isNotEmpty) {
      try {
        final models = await readSettled(container, modelsProvider.future);
        model = models.where((m) => m.id == modelId).firstOrNull;
      } on Object {
        model = null;
      }
    }
    // A LibreChat server's engines load once per account: wait for that
    // read, as dictation does, or the reading falls back to this Mac.
    if (model != null && isLibreChatModel(model)) {
      try {
        await readSettled(
          container,
          libreChatServerSpeechProvider.future,
        ).timeout(const Duration(seconds: 10));
      } on Object {
        return null;
      }
    }
    // A model no longer listed is the Open WebUI server's, as the core's
    // rule for an unknown model says.
    return serverSpeechProviderFor(container.read, model);
  }

  void _changed(TextToSpeechState next) {
    // Each reading splits its text anew: a new list is a new reading.
    if (!identical(next.sentences, _sentences)) {
      _reading++;
      _sentences = next.sentences;
    }
    _events.emit(ConduitEventSpecs.speechChanged, _progress(next));
  }

  SpeechProgress _progress(TextToSpeechState state) {
    final manager = TtsManager.instance;
    final server = manager.activeUsesServer;
    return SpeechProgress(
      status: switch (state.status) {
        TtsPlaybackStatus.idle => SpeechStatus.idle,
        TtsPlaybackStatus.initializing => SpeechStatus.initializing,
        TtsPlaybackStatus.loading => SpeechStatus.loading,
        TtsPlaybackStatus.speaking => SpeechStatus.speaking,
        TtsPlaybackStatus.paused => SpeechStatus.paused,
        TtsPlaybackStatus.error => SpeechStatus.error,
      },
      reading: _reading,
      chatId: state.activeChatId,
      messageId: state.activeMessageId,
      engine: switch (server) {
        null => null,
        true => SpeechEngine.server,
        false => SpeechEngine.device,
      },
      sentence: state.activeSentenceIndex,
      wordStart: state.wordStartInSentence,
      wordEnd: state.wordEndInSentence,
      wordsReported: server == false,
      elapsedMs: state.elapsed.inMilliseconds,
      durationMs: state.duration.inMilliseconds,
      canSeek: state.canSeek,
      canSeekSentences: state.canSeekSentences,
      seeking: state.seeking,
      error: state.errorMessage,
    );
  }
}

/// Server speech kept as `voice.speak`-style jobs, played by the window
/// from `GET /tts/{job}`.
final class JobClipStore implements TtsClipStore {
  JobClipStore(this._voice);

  final VoiceService _voice;

  @override
  Future<Uri> store(
    int sessionId,
    int index,
    Uint8List bytes,
    String mimeType,
  ) async => Uri(path: '/tts/${_voice.keep(bytes, mimeType)}');

  @override
  Future<void> release(Uri uri) async {
    if (uri.pathSegments.isNotEmpty) _voice.forget(uri.pathSegments.last);
  }
}

/// The window's speech engine as the core's [DeviceSpeechEngine] and
/// [AudioPlaybackPort]: each step goes out as `speech.command`, and the
/// window answers, and tells what happened, with `speech.report`.
final class SpeechBridge {
  SpeechBridge(this._events, {Duration timeout = const Duration(seconds: 20)})
    : _timeout = timeout;

  final EventBus _events;
  final Duration _timeout;
  int _nextId = 0;
  final Map<int, Completer<SpeechReport>> _pending =
      <int, Completer<SpeechReport>>{};

  /// The manager's device engine and player. One each for the process,
  /// as the manager is: a core started again points them at its bridge.
  static final RemoteDeviceSpeech device = RemoteDeviceSpeech._();
  static final RemoteAudioPlayback player = RemoteAudioPlayback._();

  /// Makes this bridge the one the manager's engine and player use.
  void attach() {
    device._bridge = this;
    player._bridge = this;
  }

  /// Sends a command and waits for its answer; throws when the window
  /// refuses it or none answers in time.
  Future<SpeechReport> command(
    SpeechCommand Function(int id) build, {
    Duration? timeout,
  }) async {
    final id = ++_nextId;
    final completer = Completer<SpeechReport>();
    _pending[id] = completer;
    final command = build(id);
    final reached = _events.emit(ConduitEventSpecs.speechCommand, command);
    try {
      if (reached == 0) {
        throw StateError('no window to speak ${command.kind.name}');
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

  /// What the window said: what happened first, then the answer, so the
  /// command's caller sees the state it left.
  void report(SpeechReport report) {
    switch (report.kind) {
      case null:
        break;
      case SpeechReportKind.player:
        if (identical(player._bridge, this)) player._apply(report);
      case final kind:
        if (identical(device._bridge, this)) device._apply(kind, report);
    }
    if (report.id case final id?) {
      final waiting = _pending[id];
      if (waiting != null && !waiting.isCompleted) waiting.complete(report);
    }
  }
}

/// The Mac's voices, in the window.
final class RemoteDeviceSpeech implements DeviceSpeechEngine {
  RemoteDeviceSpeech._();

  late SpeechBridge _bridge;
  final StreamController<NativeTtsEvent> _events =
      StreamController<NativeTtsEvent>.broadcast();

  /// The utterance being said; another's late events are dropped.
  int _utterance = 0;

  @override
  Stream<NativeTtsEvent> get events => _events.stream;

  @override
  String get engineName => 'AVSpeech';

  @override
  bool get replacesOnSpeak => true;

  void _apply(SpeechReportKind kind, SpeechReport report) {
    if (report.utterance != _utterance) return;
    final type = switch (kind) {
      SpeechReportKind.start => 'start',
      SpeechReportKind.progress => 'progress',
      SpeechReportKind.complete => 'complete',
      SpeechReportKind.cancel => 'cancel',
      SpeechReportKind.pause => 'pause',
      SpeechReportKind.resume => 'continue',
      SpeechReportKind.failed => 'error',
      SpeechReportKind.player => null,
    };
    if (type == null) return;
    _events.add(
      NativeTtsEvent(
        type: type,
        message: report.error,
        start: report.start,
        end: report.end,
      ),
    );
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final report = await _bridge.command(
        (id) => SpeechCommand(id: id, kind: SpeechCommandKind.deviceAvailable),
        timeout: const Duration(seconds: 5),
      );
      return report.value ?? false;
    } on Object catch (error) {
      DebugLogger.warning(
        'device-speech-unavailable',
        scope: 'daemon/speech',
        data: {'error': '$error'},
      );
      return false;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getVoices() async {
    final report = await _bridge.command(
      (id) => SpeechCommand(id: id, kind: SpeechCommandKind.deviceVoices),
    );
    return <Map<String, dynamic>>[
      for (final voice in report.voices)
        <String, dynamic>{
          'identifier': voice.id,
          'name': voice.name,
          'language': voice.language,
        },
    ];
  }

  @override
  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
    bool voiceCall = false,
  }) async {
    final utterance = ++_utterance;
    final report = await _bridge.command(
      (id) => SpeechCommand(
        id: id,
        kind: SpeechCommandKind.deviceSpeak,
        text: text,
        voice: voiceIdentifier,
        rate: rate,
        pitch: pitch,
        volume: volume,
        utterance: utterance,
      ),
    );
    return report.value ?? true;
  }

  @override
  Future<NativeTtsAudio> synthesize({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
  }) => throw UnsupportedError('the Mac reads aloud live');

  /// Nothing is ever rendered, so there is nothing to cancel.
  @override
  Future<bool> cancelSynthesis() async => true;

  @override
  Future<bool> stop() => _simple(SpeechCommandKind.deviceStop);

  @override
  Future<bool> pause() => _simple(SpeechCommandKind.devicePause);

  @override
  Future<bool> resume() => _simple(SpeechCommandKind.deviceResume);

  Future<bool> _simple(SpeechCommandKind kind) async {
    final report = await _bridge.command(
      (id) => SpeechCommand(id: id, kind: kind, utterance: _utterance),
    );
    return report.value ?? true;
  }
}

/// The window's player, for server speech.
final class RemoteAudioPlayback implements AudioPlaybackPort {
  RemoteAudioPlayback._();

  late SpeechBridge _bridge;
  final StreamController<AudioPlaybackState> _states =
      StreamController<AudioPlaybackState>.broadcast();
  final StreamController<int?> _indices = StreamController<int?>.broadcast();

  bool _playing = false;
  AudioProcessingState _state = AudioProcessingState.idle;
  int? _index;
  Duration _position = Duration.zero;
  final Stopwatch _since = Stopwatch();
  double _speed = 1;

  void _apply(SpeechReport report) {
    final playing = report.playing;
    final state = switch (report.state) {
      null => _state,
      SpeechPlayerState.idle => AudioProcessingState.idle,
      SpeechPlayerState.loading => AudioProcessingState.loading,
      SpeechPlayerState.buffering => AudioProcessingState.buffering,
      SpeechPlayerState.ready => AudioProcessingState.ready,
      SpeechPlayerState.completed => AudioProcessingState.completed,
    };
    if (report.positionMs case final ms?) {
      _position = Duration(milliseconds: ms);
      _since
        ..reset()
        ..start();
    }
    final index = report.index;
    final indexChanged = index != _index;
    final stateChanged = playing != _playing || state != _state;
    _index = index;
    _playing = playing;
    _state = state;
    if (indexChanged) _indices.add(index);
    if (stateChanged) {
      _states.add(AudioPlaybackState(playing: playing, processingState: state));
    }
  }

  @override
  Stream<AudioPlaybackState> get stateChanges => _states.stream;

  @override
  Stream<int?> get currentIndexChanges => _indices.stream;

  @override
  int? get currentIndex => _index;

  /// The last position the window reported, carried on by the time since
  /// while it plays.
  @override
  Duration get position {
    if (!_playing || _state != AudioProcessingState.ready) return _position;
    return _position + _since.elapsed * _speed;
  }

  @override
  AudioProcessingState get processingState => _state;

  @override
  Future<Duration?> durationOf(AudioClip clip) async {
    final report = await _bridge.command(
      (id) => SpeechCommand(
        id: id,
        kind: SpeechCommandKind.playerDuration,
        clips: <String>[clip.uri.toString()],
      ),
    );
    final ms = report.durationMs;
    return ms == null ? null : Duration(milliseconds: ms);
  }

  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) => _send(
    SpeechCommandKind.playerSet,
    clips: <String>[for (final clip in clips) clip.uri.toString()],
    index: initialIndex,
    positionMs: initialPosition.inMilliseconds,
  );

  @override
  Future<void> addClip(AudioClip clip) =>
      _send(SpeechCommandKind.playerAdd, clips: <String>[clip.uri.toString()]);

  @override
  Future<void> clearClips() => _send(SpeechCommandKind.playerClear);

  @override
  Future<void> play() => _send(SpeechCommandKind.playerPlay);

  @override
  Future<void> pause() => _send(SpeechCommandKind.playerPause);

  @override
  Future<void> stop() => _send(SpeechCommandKind.playerStop);

  @override
  Future<void> seek(Duration? position, {int? index}) => _send(
    SpeechCommandKind.playerSeek,
    index: index,
    positionMs: (position ?? Duration.zero).inMilliseconds,
  );

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    try {
      await _send(SpeechCommandKind.playerSpeed, speed: speed);
    } on StateError {
      // No window yet: the speed goes with the next clip it plays.
    }
  }

  @override
  Future<void> dispose() async {}

  Future<void> _send(
    SpeechCommandKind kind, {
    List<String> clips = const <String>[],
    int? index,
    int? positionMs,
    double? speed,
  }) async {
    await _bridge.command(
      (id) => SpeechCommand(
        id: id,
        kind: kind,
        clips: clips,
        index: index,
        positionMs: positionMs,
        speed: speed,
      ),
    );
  }
}
