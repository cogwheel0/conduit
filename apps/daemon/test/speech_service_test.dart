@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/read_aloud/text_to_speech_controller.dart';
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_service.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Read aloud runs in the daemon; a window speaks and plays it. Here a fake
/// window answers `speech.command` as the desktop app's engine does.
void main() {
  late EventBus bus;
  late ProviderContainer container;
  late SpeechService speech;
  late VoiceService voice;
  late _Window window;

  // Each over 50 characters, so Open WebUI's split keeps them apart.
  const sentences = <String>[
    'The harbour lights come on one by one as the evening settles in.',
    'A small wooden boat drifts slowly past the green buoy near the pier.',
    'Gulls settle on the old stone wall and wait quietly for the tide.',
  ];
  final answer = '${sentences[0]} ${sentences[1]}\n\n${sentences[2]}';

  void start({
    required TtsEngine engine,
    Future<({String content, String? model})> Function(String, String)?
    answerFor,
  }) {
    bus = EventBus();
    container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(AppSettings(ttsEngine: engine)),
        readAloudLiveDeviceSpeechProvider.overrideWithValue(true),
        textToSpeechServiceProvider.overrideWith(
          (ref) => TextToSpeechService(),
        ),
      ],
    );
    voice = VoiceService(container);
    speech = SpeechService(
      container,
      events: bus,
      voice: voice,
      answerFor:
          answerFor ??
          (chatId, messageId) async => (content: answer, model: 'fake-model'),
      speechFor: (modelId) async => _Server(),
    );
    window = _Window(bus, speech);
  }

  tearDown(() async {
    await speech.stop();
    await speech.dispose();
    container.dispose();
  });

  test(
    'the Mac reads an answer live, word by word, and moves by sentence',
    () async {
      start(engine: TtsEngine.device);
      final state = await speech.toggle(
        const SpeechToggle(chatId: 'chat-harbour', messageId: 'answer-1'),
      );
      expect(state.sentences, sentences);
      await window.until(() => window.spoken.isNotEmpty);
      expect(window.spoken.single, sentences[0]);
      await window.until(() => window.last?.status == SpeechStatus.speaking);
      final speaking = window.last!;
      expect(speaking.chatId, 'chat-harbour');
      expect(speaking.engine, SpeechEngine.device);
      expect(speaking.wordsReported, isTrue);
      expect(speaking.canSeekSentences, isTrue);

      window.word(4, 11); // "harbour"
      await window.until(() => window.last?.wordStart == 4);
      expect(window.last!.wordEnd, 11);

      await speech.seek(const SpeechSeek(by: 1));
      await window.until(() => window.spoken.length == 2);
      expect(window.spoken.last, sentences[1]);
      await window.until(() => window.last?.sentence == 1);

      await speech.pause();
      await window.until(() => window.last?.status == SpeechStatus.paused);
      await speech.seek(const SpeechSeek(sentence: 2));
      await window.until(() => window.last?.sentence == 2);
      expect(window.spoken, hasLength(2), reason: 'paused: nothing said yet');
      await speech.resume();
      await window.until(() => window.spoken.length == 3);
      expect(window.spoken.last, sentences[2]);

      // A word from the replaced utterance arrives late and is dropped.
      window.word(0, 1, utterance: 1);
      await window.until(() => window.last?.status == SpeechStatus.speaking);
      expect(window.last!.wordStart, isNot(0));

      await speech.stop();
      await window.until(() => window.last?.status == SpeechStatus.idle);
      expect(window.last!.messageId, isNull);
    },
  );

  test(
    'a reading stopped while its answer is looked up never starts',
    () async {
      final found = Completer<({String content, String? model})>();
      start(
        engine: TtsEngine.device,
        answerFor: (chatId, messageId) => found.future,
      );
      final toggled = speech.toggle(
        const SpeechToggle(chatId: 'chat-harbour', messageId: 'answer-1'),
      );
      await speech.stop();
      found.complete((content: answer, model: 'fake-model'));
      final state = await toggled;
      expect(state.progress.messageId, isNull, reason: 'it started after Stop');
      expect(speech.get().progress.status, SpeechStatus.idle);
    },
  );

  test('server speech reaches the window as /tts jobs', () async {
    start(engine: TtsEngine.server);
    await speech.toggle(
      const SpeechToggle(chatId: 'chat-harbour', messageId: 'answer-1'),
    );
    await window.until(() => window.playing);
    expect(window.clips, isNotEmpty);
    expect(window.clips.first, startsWith('/tts/tts-'));
    final audio = await voice.audio(window.clips.first.substring(5));
    expect(audio.contentType, 'audio/wav');
    expect(audio.bytes, isNotEmpty);
    await window.until(() => window.last?.status == SpeechStatus.speaking);
    expect(window.last!.engine, SpeechEngine.server);
    expect(window.last!.wordsReported, isFalse);

    // All three are queued with their lengths: the reading can seek.
    await window.until(() => window.clips.length == 3 && window.last!.canSeek);
    await speech.seek(const SpeechSeek(sentence: 2));
    await window.until(() => window.index == 2);
    await window.until(() => window.last?.sentence == 2);

    await speech.stop();
    await window.until(() => window.last?.status == SpeechStatus.idle);
    // The reading let go of its audio.
    await expectLater(
      voice.audio(window.clips.first.substring(5)),
      throwsA(isA<RpcError>()),
    );
  });
}

/// Every sentence lasts a second.
final class _Server implements ServerSpeechProvider {
  @override
  ServerSpeechSource get source => ServerSpeechSource.openWebUi;
  @override
  bool get canTranscribe => false;
  @override
  bool get canSynthesize => true;
  @override
  bool get offersVoiceChoice => true;
  @override
  Future<String> transcribe(
    Uint8List audio, {
    required String fileName,
    required String mimeType,
    String? language,
  }) async => '';
  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async => (bytes: Uint8List.fromList([1, 2, 3, 4]), mimeType: 'audio/wav');
}

/// The desktop app's speech engine, answering at once.
final class _Window {
  _Window(this.bus, this.speech) {
    bus.attach('window', _deliver);
  }

  final EventBus bus;
  final SpeechService speech;
  final spoken = <String>[];
  SpeechProgress? last;
  int utterance = 0;
  final clips = <String>[];
  int index = 0;
  bool playing = false;
  SpeechPlayerState state = SpeechPlayerState.idle;

  void _deliver(EventEnvelope envelope) {
    switch (envelope.event) {
      case ConduitEvents.speechChanged:
        last = SpeechProgress.fromJson(envelope.payload);
      case ConduitEvents.speechCommand:
        final command = SpeechCommand.fromJson(envelope.payload);
        scheduleMicrotask(() => _run(command));
    }
  }

  void _report(SpeechReport report) => speech.report(report);

  SpeechReport _player(int id) => SpeechReport(
    id: id,
    kind: SpeechReportKind.player,
    playing: playing,
    state: state,
    index: clips.isEmpty ? null : index,
    positionMs: 0,
  );

  void _run(SpeechCommand c) {
    switch (c.kind) {
      case SpeechCommandKind.deviceAvailable:
        _report(SpeechReport(id: c.id, value: true));
      case SpeechCommandKind.deviceVoices:
        _report(SpeechReport(id: c.id));
      case SpeechCommandKind.deviceSpeak:
        spoken.add(c.text!);
        utterance = c.utterance;
        _report(SpeechReport(id: c.id, value: true));
        _report(
          SpeechReport(kind: SpeechReportKind.start, utterance: utterance),
        );
      case SpeechCommandKind.devicePause:
        _report(SpeechReport(id: c.id, value: true));
        _report(
          SpeechReport(kind: SpeechReportKind.pause, utterance: utterance),
        );
      case SpeechCommandKind.deviceResume:
        _report(SpeechReport(id: c.id, value: true));
        _report(
          SpeechReport(kind: SpeechReportKind.resume, utterance: utterance),
        );
      case SpeechCommandKind.deviceStop:
        _report(SpeechReport(id: c.id, value: true));
        _report(
          SpeechReport(kind: SpeechReportKind.cancel, utterance: utterance),
        );
      case SpeechCommandKind.playerDuration:
        _report(SpeechReport(id: c.id, durationMs: 1000));
      case SpeechCommandKind.playerSet:
        clips
          ..clear()
          ..addAll(c.clips);
        index = c.index ?? 0;
        state = SpeechPlayerState.ready;
        _report(_player(c.id));
      case SpeechCommandKind.playerAdd:
        clips.addAll(c.clips);
        _report(_player(c.id));
      case SpeechCommandKind.playerClear:
        clips.clear();
        _report(_player(c.id));
      case SpeechCommandKind.playerPlay:
        playing = true;
        _report(_player(c.id));
      case SpeechCommandKind.playerPause:
        playing = false;
        _report(_player(c.id));
      case SpeechCommandKind.playerStop:
        playing = false;
        state = SpeechPlayerState.idle;
        _report(_player(c.id));
      case SpeechCommandKind.playerSeek:
        index = c.index ?? index;
        _report(_player(c.id));
      case SpeechCommandKind.playerSpeed:
        _report(_player(c.id));
    }
  }

  void word(int start, int end, {int? utterance}) => _report(
    SpeechReport(
      kind: SpeechReportKind.progress,
      utterance: utterance ?? this.utterance,
      start: start,
      end: end,
    ),
  );

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out; last: $last, spoken: $spoken, clips: $clips');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}
