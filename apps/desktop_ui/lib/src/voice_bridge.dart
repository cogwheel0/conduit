import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:web/web.dart' as web;

import 'shell_bridge.dart';
import 'voice_port.dart';

/// [VoicePort] in the browser (M8).
///
/// The microphone is `getUserMedia` into a `MediaRecorder`, with an
/// `AnalyserNode` beside it reporting how loud it is; the recording goes to
/// the daemon's `/transcribe` as the request body, never through Dart. The
/// system's voices are Web Speech Synthesis, and the server's are an
/// `<audio>` element on the daemon's `/tts/` route -- Electron adds the
/// token to that request, so the element carries no credential.
final class BrowserVoice implements VoicePort {
  BrowserVoice(this._bridge);

  final ShellBridge _bridge;

  web.MediaStream? _stream;
  web.MediaRecorder? _recorder;
  web.AudioContext? _audio;
  Timer? _meter;
  final List<web.Blob> _chunks = <web.Blob>[];
  final Map<String, web.Blob> _captured = <String, web.Blob>{};
  int _next = 0;

  web.HTMLAudioElement? _playing;
  Completer<void>? _speaking;

  @override
  Future<bool> startCapture(LevelListener onLevel) async {
    cancelCapture();
    try {
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(
              audio: <String, bool>{
                // So an answer read aloud is not heard as the user.
                'echoCancellation': true,
                'noiseSuppression': true,
              }.jsify()!,
            ),
          )
          .toDart;
      _stream = stream;
      _chunks.clear();
      final recorder = web.MediaRecorder(stream);
      recorder.ondataavailable = (web.BlobEvent event) {
        if (event.data.size > 0) _chunks.add(event.data);
      }.toJS;
      recorder.start();
      _recorder = recorder;

      final audio = web.AudioContext();
      _audio = audio;
      final analyser = audio.createAnalyser()..fftSize = 1024;
      audio.createMediaStreamSource(stream).connect(analyser);
      final samples = Float32List(analyser.fftSize);
      final clock = Stopwatch()..start();
      _meter = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final buffer = samples.toJS;
        analyser.getFloatTimeDomainData(buffer);
        final read = buffer.toDart;
        var sum = 0.0;
        for (final sample in read) {
          sum += sample * sample;
        }
        onLevel(math.sqrt(sum / read.length), clock.elapsed);
      });
      return true;
    } on Object {
      // No microphone, or permission refused.
      cancelCapture();
      return false;
    }
  }

  @override
  Future<CapturedAudio?> stopCapture() async {
    final recorder = _recorder;
    if (recorder == null) return null;
    final stopped = Completer<void>();
    recorder.onstop = (web.Event _) {
      if (!stopped.isCompleted) stopped.complete();
    }.toJS;
    recorder.stop();
    await stopped.future;
    final type = recorder.mimeType.isEmpty ? 'audio/webm' : recorder.mimeType;
    _release();
    if (_chunks.isEmpty) return null;
    final blob = web.Blob(_chunks.toJS, web.BlobPropertyBag(type: type));
    _chunks.clear();
    final handle = 'v${_next++}';
    _captured[handle] = blob;
    return CapturedAudio(handle: handle, contentType: type, size: blob.size);
  }

  @override
  void cancelCapture() {
    final recorder = _recorder;
    if (recorder != null && recorder.state != 'inactive') recorder.stop();
    _release();
    _chunks.clear();
  }

  /// Lets go of the microphone, so the system's indicator goes out.
  void _release() {
    _meter?.cancel();
    _meter = null;
    _recorder = null;
    unawaited(_audio?.close().toDart.catchError((Object _) => null));
    _audio = null;
    for (final track
        in _stream?.getTracks().toDart ?? const <web.MediaStreamTrack>[]) {
      track.stop();
    }
    _stream = null;
  }

  @override
  Future<String> transcribe(CapturedAudio audio) async {
    final blob = _captured.remove(audio.handle);
    if (blob == null) {
      throw StateError('no such recording: ${audio.handle}');
    }
    final headers = web.Headers()
      ..append('authorization', 'Bearer ${_bridge.token}')
      ..append('content-type', audio.contentType);
    final web.Response response;
    try {
      response = await web.window
          .fetch(
            '${_bridge.httpBase}${ConduitHttpRoutes.transcribe}'.toJS,
            web.RequestInit(method: 'POST', headers: headers, body: blob),
          )
          .toDart;
    } on Object {
      throw const RpcError(code: ConduitErrorCodes.connectionFailed);
    }
    final body = (await response.text().toDart).toDart;
    if (response.status != 200) {
      var code = ConduitErrorCodes.serverError;
      try {
        code = (jsonDecode(body) as Map<String, dynamic>)['code'] as String;
      } on Object {
        // Not the daemon's error shape; the status says enough.
      }
      throw RpcError(code: code, debugMessage: body);
    }
    return VoiceTranscript.fromJson(jsonDecode(body) as Map<String, dynamic>)
        .text;
  }

  @override
  Future<List<DeviceVoice>> deviceVoices() async {
    final synthesis = web.window.speechSynthesis;
    var voices = synthesis.getVoices().toDart;
    if (voices.isEmpty) {
      // The list loads after the page does; it says when.
      final loaded = Completer<void>();
      synthesis.onvoiceschanged = (web.Event _) {
        if (!loaded.isCompleted) loaded.complete();
      }.toJS;
      await loaded.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      voices = synthesis.getVoices().toDart;
    }
    return <DeviceVoice>[
      for (final voice in voices)
        DeviceVoice(
          name: voice.name,
          language: voice.lang,
          isDefault: voice.default_,
        ),
    ];
  }

  @override
  Future<void> speakDevice(
    String text, {
    String? voice,
    double rate = 1,
    double pitch = 1,
    double volume = 1,
  }) {
    final synthesis = web.window.speechSynthesis;
    final utterance = web.SpeechSynthesisUtterance(text)
      ..rate = rate
      ..pitch = pitch
      ..volume = volume;
    if (voice != null) {
      for (final candidate in synthesis.getVoices().toDart) {
        if (candidate.name == voice) {
          utterance.voice = candidate;
          break;
        }
      }
    }
    final done = _speaking = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    utterance
      ..onend = (web.Event _) {
        finish();
      }.toJS
      ..onerror = (web.Event _) {
        finish();
      }.toJS;
    // Some engines never report the end -- and one with no voices at all
    // reports nothing -- so a sentence is given up on after far longer than
    // it could take to say.
    Timer(
      Duration(milliseconds: 4000 + (text.length * 150 / rate).round()),
      finish,
    );
    synthesis.speak(utterance);
    return done.future;
  }

  @override
  Future<void> play(String jobId, {double volume = 1}) {
    final element = web.HTMLAudioElement()
      ..src = '${_bridge.httpBase}${ConduitHttpRoutes.tts(jobId)}'
      ..volume = volume.clamp(0, 1).toDouble();
    _playing = element;
    final done = _speaking = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    element
      ..onended = (web.Event _) {
        finish();
      }.toJS
      ..onerror = (web.Event _) {
        finish();
      }.toJS;
    unawaited(
      element.play().toDart.then<void>((_) {}, onError: (Object _) => finish()),
    );
    return done.future;
  }

  @override
  void stopSpeech() {
    web.window.speechSynthesis.cancel();
    _playing?.pause();
    _playing = null;
    final speaking = _speaking;
    _speaking = null;
    if (speaking != null && !speaking.isCompleted) speaking.complete();
  }
}
