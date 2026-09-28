import 'dart:async';
import 'dart:collection';

import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'rpc/chat_providers.dart';
import 'rpc/voice_providers.dart';
import 'voice_port.dart';

/// Voice in the window: reading answers aloud, dictation, and calls.
///
/// The audio itself is behind [VoicePort]; this file is the logic, so a
/// test drives it with a microphone that reports whatever levels it is told
/// to. The phone app's call machine is Flutter through and through, so the
/// desktop has its own here -- the same phases, over the same daemon.

/// How loud counts as speech, as the RMS [VoicePort] reports.
const double speechLevel = 0.03;

/// Decides when someone has finished speaking: they said something, then
/// were quiet for [silence].
class UtteranceDetector {
  UtteranceDetector({
    required this.silence,
    this.threshold = speechLevel,
    this.onsetTimeout = const Duration(seconds: 12),
    this.limit = const Duration(minutes: 2),
  });

  final Duration silence;
  final double threshold;

  /// How long to wait for anything at all before giving up.
  final Duration onsetTimeout;

  /// The longest an utterance runs.
  final Duration limit;

  Duration? _lastLoud;

  /// Whether anything louder than [threshold] has been heard.
  bool get heard => _lastLoud != null;

  /// Adds the level read at [at]; true when the utterance is over.
  bool add(double level, Duration at) {
    if (level >= threshold) _lastLoud = at;
    if (at >= limit) return true;
    final last = _lastLoud;
    if (last == null) return at >= onsetTimeout;
    return at - last >= silence;
  }
}

/// Whether speech can be transcribed now: on this computer when that is
/// chosen and a model is ready, by the server otherwise.
bool canTranscribe(VoiceSettings settings) =>
    transcribesLocally(settings) || settings.serverStt;

/// Whether this computer does the transcribing, which wants WAV.
bool transcribesLocally(VoiceSettings settings) =>
    settings.sttEngine == 'local' && settings.localReady;

Future<VoiceSettings> _voiceSettings(Ref ref) async {
  try {
    return await ref.read(voiceSettingsProvider.future);
  } on Object {
    // The daemon could not say; the defaults speak with the system voice.
    return const VoiceSettings();
  }
}

// -- Reading aloud ------------------------------------------------------------

/// What is being read aloud: the id of the message, or null.
class SpeechState {
  const SpeechState({this.id});

  final String? id;

  bool get speaking => id != null;
}

final speechPlayerProvider = NotifierProvider<SpeechPlayer, SpeechState>(
  SpeechPlayer.new,
);

/// Says an answer a sentence at a time, the way Open WebUI splits it, with
/// the saved engine and voice. An answer still arriving is fed in as it
/// grows, and only what is new is said.
class SpeechPlayer extends Notifier<SpeechState> {
  final Queue<String> _queue = Queue<String>();
  int _session = 0;
  int? _pumping;
  bool _finalized = false;
  int _fed = 0;
  String _spoken = '';
  VoiceSettings? _settings;
  Completer<void>? _done;
  Future<void> _feeds = Future<void>.value();

  @override
  SpeechState build() {
    ref.onDispose(() {
      _session++;
      _queue.clear();
    });
    return const SpeechState();
  }

  /// Reads [text] aloud as [id], or stops if [id] is what is being read.
  void toggle(String id, String text) {
    if (state.id == id) {
      stop();
      return;
    }
    begin(id);
    feed(text, finalized: true);
  }

  /// Starts a reading of [id], replacing any other; [feed] gives it text.
  void begin(String id) {
    _halt();
    _session++;
    _finalized = false;
    _fed = 0;
    _spoken = '';
    _settings = null;
    _done = Completer<void>();
    state = SpeechState(id: id);
  }

  /// Completes when the current reading ends, however it ends.
  Future<void> get done => _done?.future ?? Future<void>.value();

  /// The whole answer so far. Once [finalized], the reading ends when
  /// everything has been said.
  void feed(String accumulated, {required bool finalized}) {
    if (state.id == null) return;
    final session = _session;
    // In order: a later feed's sentences must not be queued before an
    // earlier one's.
    _feeds = _feeds
        .then((_) async {
          if (session != _session) return;
          final settings = _settings ??= await _voiceSettings(ref);
          if (session != _session) return;
          final advance = advanceStreamingChunks(
            chunks: getMessageContentParts(
              accumulated,
              splitOn: settings.splitOn,
            ),
            fedChunkCount: _fed,
            spokenText: _spoken,
            finalized: finalized,
          );
          _fed = advance.fedChunkCount;
          _spoken = advance.spokenText;
          _queue.addAll(advance.chunks);
          if (finalized) _finalized = true;
          unawaited(_pump(session));
        })
        .catchError((Object _) {});
  }

  Future<void> _pump(int session) async {
    if (_pumping == session) return;
    _pumping = session;
    try {
      while (_queue.isNotEmpty && session == _session) {
        await _say(session, _queue.removeFirst(), _settings!);
      }
    } finally {
      if (_pumping == session) _pumping = null;
    }
    if (session == _session && _finalized && _queue.isEmpty) {
      final done = _done;
      _done = null;
      state = const SpeechState();
      if (done != null && !done.isCompleted) done.complete();
    }
  }

  Future<void> _say(int session, String text, VoiceSettings settings) async {
    final port = ref.read(voicePortProvider);
    try {
      if (settings.ttsEngine == 'server' && settings.serverTts) {
        final job = await ref.read(voiceActionsProvider).speak(text);
        if (session != _session) return;
        await port.play(job.jobId, volume: settings.volume);
      } else {
        await port.speakDevice(
          text,
          voice: settings.deviceVoice,
          // The phone's scale has 0.5 as normal; Web Speech's has 1.
          rate: settings.rate * 2,
          pitch: settings.pitch,
          volume: settings.volume,
        );
      }
    } on Object {
      // A sentence that could not be said is skipped, not the answer.
    }
  }

  /// Stops reading.
  void stop() {
    _halt();
    state = const SpeechState();
  }

  void _halt() {
    _session++;
    _queue.clear();
    if (state.id != null) ref.read(voicePortProvider).stopSpeech();
    final done = _done;
    _done = null;
    if (done != null && !done.isCompleted) done.complete();
  }
}

// -- Dictation ----------------------------------------------------------------

enum DictationPhase { idle, listening, transcribing }

enum DictationProblem { unavailable, microphone, nothingHeard, failed }

class DictationState {
  const DictationState({
    this.phase = DictationPhase.idle,
    this.level = 0,
    this.problem,
  });

  final DictationPhase phase;

  /// How loud the microphone is, 0 to 1, while listening.
  final double level;
  final DictationProblem? problem;
}

final dictationProvider = NotifierProvider<Dictation, DictationState>(
  Dictation.new,
);

/// Speech into the composer: record until a pause (or until the key or
/// button is let go), then the server's transcription arrives on
/// [results].
class Dictation extends Notifier<DictationState> {
  final StreamController<String> _results =
      StreamController<String>.broadcast();
  UtteranceDetector? _detector;
  int _session = 0;
  bool _wav = false;

  /// What each dictation said, for the composer to insert.
  Stream<String> get results => _results.stream;

  @override
  DictationState build() {
    final port = ref.read(voicePortProvider);
    ref.onDispose(() {
      _session++;
      if (_detector != null) port.cancelCapture();
      unawaited(_results.close());
    });
    return const DictationState();
  }

  VoicePort get _port => ref.read(voicePortProvider);

  /// Starts dictation, or ends it if it is listening.
  Future<void> toggle() => switch (state.phase) {
    DictationPhase.idle => start(),
    DictationPhase.listening => finish(),
    DictationPhase.transcribing => Future<void>.value(),
  };

  /// Starts listening. With [hold], a pause does not end it; [finish]
  /// does, when the button is let go.
  Future<void> start({bool hold = false}) async {
    if (state.phase != DictationPhase.idle) return;
    final session = ++_session;
    state = const DictationState(phase: DictationPhase.listening);
    final settings = await _voiceSettings(ref);
    if (session != _session || state.phase != DictationPhase.listening) {
      return;
    }
    if (!canTranscribe(settings)) {
      state = const DictationState(problem: DictationProblem.unavailable);
      return;
    }
    _wav = transcribesLocally(settings);
    // Its own voice must not be what it hears.
    ref.read(speechPlayerProvider.notifier).stop();
    final detector = _detector = hold
        ? UtteranceDetector(
            silence: const Duration(days: 1),
            onsetTimeout: const Duration(days: 1),
          )
        : UtteranceDetector(
            silence: Duration(milliseconds: settings.silenceMs),
          );
    final started = await _port.startCapture((level, at) {
      if (session != _session || state.phase != DictationPhase.listening) {
        return;
      }
      state = DictationState(phase: DictationPhase.listening, level: level);
      if (detector.add(level, at)) unawaited(finish());
    });
    if (session != _session) return;
    if (!started) {
      _detector = null;
      state = const DictationState(problem: DictationProblem.microphone);
    }
  }

  /// Stops listening and transcribes what was heard.
  Future<void> finish() async {
    if (state.phase != DictationPhase.listening) return;
    final session = _session;
    _detector = null;
    state = const DictationState(phase: DictationPhase.transcribing);
    final audio = await _port.stopCapture();
    if (session != _session) return;
    if (audio == null) {
      state = const DictationState();
      return;
    }
    try {
      final text = (await _port.transcribe(audio, wav: _wav)).trim();
      if (session != _session) return;
      if (text.isEmpty) {
        state = const DictationState(problem: DictationProblem.nothingHeard);
        return;
      }
      state = const DictationState();
      _results.add(text);
    } on Object {
      if (session != _session) return;
      state = const DictationState(problem: DictationProblem.failed);
    }
  }

  /// Stops listening and throws the recording away.
  void cancel() {
    _session++;
    if (_detector != null || state.phase == DictationPhase.listening) {
      _port.cancelCapture();
    }
    _detector = null;
    state = const DictationState();
  }
}

// -- Calls --------------------------------------------------------------------

enum CallPhase { off, listening, transcribing, thinking, speaking, paused }

enum CallProblem { unavailable, microphone, failed }

class CallState {
  const CallState({
    this.phase = CallPhase.off,
    this.muted = false,
    this.level = 0,
    this.heard,
    this.problem,
  });

  final CallPhase phase;
  final bool muted;
  final double level;

  /// What the user last said, as transcribed.
  final String? heard;
  final CallProblem? problem;

  bool get active => phase != CallPhase.off;

  CallState copyWith({
    CallPhase? phase,
    bool? muted,
    double? level,
    String? heard,
    CallProblem? problem,
  }) => CallState(
    phase: phase ?? this.phase,
    muted: muted ?? this.muted,
    level: level ?? this.level,
    heard: heard ?? this.heard,
    problem: problem,
  );
}

/// Watch it for as long as a call may run: Riverpod pauses a provider
/// nobody listens to, and with it the answer this follows.
final voiceCallProvider = NotifierProvider<VoiceCall, CallState>(VoiceCall.new);

/// A conversation by voice: listen until a pause, send what was said,
/// read the answer aloud as it arrives, and listen again. With barge-in,
/// speaking over the answer stops it and starts the next question.
class VoiceCall extends Notifier<CallState> {
  int _session = 0;
  bool _capturing = false;
  String? _answerId;
  VoiceSettings _settings = const VoiceSettings();
  UtteranceDetector? _detector;

  @override
  CallState build() {
    ref.listen<AsyncValue<LiveTurn?>>(
      liveTurnProvider,
      (_, next) => _onTurn(next.value),
    );
    final port = ref.read(voicePortProvider);
    ref.onDispose(() {
      _session++;
      if (_capturing) port.cancelCapture();
    });
    return const CallState();
  }

  VoicePort get _port => ref.read(voicePortProvider);
  SpeechPlayer get _player => ref.read(speechPlayerProvider.notifier);

  Future<void> start() async {
    if (state.active) return;
    final session = ++_session;
    state = const CallState(phase: CallPhase.listening);
    _settings = await _voiceSettings(ref);
    if (session != _session) return;
    if (!canTranscribe(_settings)) {
      state = const CallState(problem: CallProblem.unavailable);
      return;
    }
    ref.read(dictationProvider.notifier).cancel();
    await _listen();
  }

  /// Hangs up.
  void end() {
    _session++;
    _stopCapture();
    _answerId = null;
    _player.stop();
    state = const CallState();
  }

  void pause() {
    if (!state.active || state.phase == CallPhase.paused) return;
    _session++;
    _stopCapture();
    _answerId = null;
    _player.stop();
    state = state.copyWith(phase: CallPhase.paused, level: 0);
  }

  Future<void> resume() async {
    if (state.phase != CallPhase.paused) return;
    _session++;
    await _listen();
  }

  Future<void> toggleMute() async {
    if (!state.active) return;
    final muted = !state.muted;
    state = state.copyWith(muted: muted, level: 0);
    if (state.phase != CallPhase.listening) return;
    _session++;
    if (muted) {
      _stopCapture();
    } else {
      await _listen();
    }
  }

  void _stopCapture() {
    if (_capturing) _port.cancelCapture();
    _capturing = false;
    _detector = null;
  }

  Future<void> _listen() async {
    _stopCapture();
    final session = _session;
    state = state.copyWith(phase: CallPhase.listening, level: 0);
    if (state.muted) return;
    await _capture(session);
  }

  /// Opens the microphone for the next question -- while listening, or
  /// while the answer is said when barge-in is on.
  Future<void> _capture(int session) async {
    _detector = UtteranceDetector(
      silence: Duration(milliseconds: _settings.silenceMs),
      // In a call, silence is the user thinking, not the end of it.
      onsetTimeout: const Duration(days: 1),
    );
    _capturing = true;
    final started = await _port.startCapture(
      (level, at) => _onLevel(session, level, at),
    );
    if (session != _session) return;
    if (!started) {
      _capturing = false;
      _player.stop();
      state = const CallState(problem: CallProblem.microphone);
    }
  }

  void _onLevel(int session, double level, Duration at) {
    if (session != _session) return;
    final detector = _detector;
    if (detector == null) return;
    if (state.phase == CallPhase.speaking) {
      if (level < speechLevel) return;
      // Barge-in: the user talks over the answer. It stops, and what they
      // are saying is the next question.
      _answerId = null;
      _player.stop();
      state = state.copyWith(phase: CallPhase.listening);
    }
    if (state.phase != CallPhase.listening) return;
    state = state.copyWith(level: level);
    if (detector.add(level, at)) unawaited(_heard(session));
  }

  Future<void> _heard(int session) async {
    _detector = null;
    _capturing = false;
    state = state.copyWith(phase: CallPhase.transcribing, level: 0);
    var text = '';
    try {
      final audio = await _port.stopCapture();
      if (audio != null) {
        text = (await _port.transcribe(
          audio,
          wav: transcribesLocally(_settings),
        )).trim();
      }
    } on Object {
      text = '';
    }
    if (session != _session) return;
    if (text.isEmpty) {
      await _listen();
      return;
    }
    state = state.copyWith(phase: CallPhase.thinking, heard: text);
    try {
      final accepted = await ref.read(chatActionsProvider).send(text: text);
      if (session != _session) return;
      _answerId = accepted.assistantMessageId;
      _player.begin('call:${accepted.assistantMessageId}');
      // The answer may have started, or even finished, before the send
      // came back.
      _onTurn(ref.read(liveTurnProvider).value);
    } on Object {
      if (session != _session) return;
      state = state.copyWith(problem: CallProblem.failed);
      await _listen();
    }
  }

  void _onTurn(LiveTurn? turn) {
    final answerId = _answerId;
    if (turn == null || answerId == null || turn.messageId != answerId) {
      return;
    }
    if (state.phase != CallPhase.thinking &&
        state.phase != CallPhase.speaking) {
      return;
    }
    _player.feed(turn.text, finalized: turn.settled);
    if (state.phase == CallPhase.thinking && turn.text.trim().isNotEmpty) {
      state = state.copyWith(phase: CallPhase.speaking);
      if (_settings.bargeIn && !state.muted) unawaited(_capture(_session));
    }
    if (turn.settled) {
      _answerId = null;
      final session = _session;
      unawaited(
        _player.done.then((_) async {
          if (session != _session) return;
          if (state.phase == CallPhase.speaking ||
              state.phase == CallPhase.thinking) {
            await _listen();
          }
        }),
      );
    }
  }
}
