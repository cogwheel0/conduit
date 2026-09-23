@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/voice_providers.dart';
import 'package:conduit_desktop_ui/src/voice.dart';
import 'package:conduit_desktop_ui/src/voice_port.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:test/test.dart';

class _FakeVoice extends VoiceActions {
  _FakeVoice(super.ref);

  final List<String> spoken = <String>[];

  @override
  Future<VoiceSpeech> speak(String text) async {
    spoken.add(text);
    return VoiceSpeech(jobId: 'job${spoken.length}');
  }
}

class _FakeChat extends ChatActions {
  _FakeChat(super.ref);

  final List<String> sent = <String>[];

  @override
  Future<SendTurnAccepted> send({
    required String text,
    String? model,
    List<String> fileIds = const <String>[],
    List<String> toolIds = const <String>[],
    List<KnowledgeSummary> knowledge = const <KnowledgeSummary>[],
    bool webSearch = false,
    bool imageGeneration = false,
  }) async {
    sent.add(text);
    return SendTurnAccepted(
      chatId: 'c1',
      userMessageId: 'u${sent.length}',
      assistantMessageId: 'a${sent.length}',
    );
  }
}

/// Lets queued microtasks and timers run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late RecordingVoice port;
  late StreamController<LiveTurn?> turns;
  late _FakeVoice actions;
  late _FakeChat chat;

  ProviderContainer make(VoiceSettings settings) {
    port = RecordingVoice();
    turns = StreamController<LiveTurn?>.broadcast();
    final container = ProviderContainer(
      overrides: [
        voicePortProvider.overrideWithValue(port),
        voiceSettingsProvider.overrideWith((ref) async => settings),
        voiceActionsProvider.overrideWith((ref) => actions = _FakeVoice(ref)),
        chatActionsProvider.overrideWith((ref) => chat = _FakeChat(ref)),
        liveTurnProvider.overrideWith((ref) => turns.stream),
      ],
    );
    // As the window does: the overlay and buttons watch these.
    container
      ..listen(voiceCallProvider, (_, _) {})
      ..listen(speechPlayerProvider, (_, _) {})
      ..listen(dictationProvider, (_, _) {});
    addTearDown(() async {
      container.dispose();
      await turns.close();
    });
    return container;
  }

  group('UtteranceDetector', () {
    test('ends after a pause that follows speech', () {
      final detector = UtteranceDetector(
        silence: const Duration(milliseconds: 500),
      );
      expect(detector.add(0, const Duration(seconds: 1)), isFalse);
      expect(detector.add(0.2, const Duration(milliseconds: 1100)), isFalse);
      expect(detector.add(0.01, const Duration(milliseconds: 1400)), isFalse);
      expect(detector.add(0.01, const Duration(milliseconds: 1600)), isTrue);
    });

    test('gives up when nothing is said', () {
      final detector = UtteranceDetector(
        silence: const Duration(milliseconds: 500),
        onsetTimeout: const Duration(seconds: 3),
      );
      expect(detector.add(0, const Duration(seconds: 2)), isFalse);
      expect(detector.add(0, const Duration(seconds: 3)), isTrue);
      expect(detector.heard, isFalse);
    });
  });

  group('SpeechPlayer', () {
    test(
      'reads an answer a sentence at a time with the system voice',
      () async {
        final container = make(
          const VoiceSettings(deviceVoice: 'Alex', rate: 0.75, volume: 0.5),
        );
        container
            .read(speechPlayerProvider.notifier)
            .toggle(
              'm1',
              'Here is a first sentence that is long enough to stand alone. '
                  '<details type="reasoning" done="true"><summary>x</summary>'
                  'hidden</details>And a second one follows it here, just as long.',
            );
        expect(container.read(speechPlayerProvider).id, 'm1');
        await container.read(speechPlayerProvider.notifier).done;
        expect(port.spoken, [
          'device:Here is a first sentence that is long enough to stand alone.',
          'device:And a second one follows it here, just as long.',
        ]);
        expect(port.deviceSettings.first.voice, 'Alex');
        expect(port.deviceSettings.first.rate, 1.5);
        expect(port.deviceSettings.first.volume, 0.5);
        expect(container.read(speechPlayerProvider).speaking, isFalse);
      },
    );

    test('asks the server for speech when that is the engine', () async {
      final container = make(
        const VoiceSettings(ttsEngine: 'server', serverTts: true),
      );
      final player = container.read(speechPlayerProvider.notifier);
      player.toggle('m1', 'One sentence for the server to say aloud.');
      await player.done;
      expect(actions.spoken, ['One sentence for the server to say aloud.']);
      expect(port.spoken, ['server:job1']);
    });

    test('says a streaming answer once, as it grows', () async {
      final container = make(const VoiceSettings());
      final player = container.read(speechPlayerProvider.notifier)..begin('m1');
      player.feed(
        'The first sentence is here now, long enough to be alone.',
        finalized: false,
      );
      await _settle();
      expect(port.spoken, isEmpty, reason: 'the last chunk is still growing');
      player.feed(
        'The first sentence is here now, long enough to be alone. The second one arrives',
        finalized: false,
      );
      await _settle();
      expect(port.spoken, [
        'device:The first sentence is here now, long enough to be alone.',
      ]);
      player.feed(
        'The first sentence is here now, long enough to be alone. The second one arrives later.',
        finalized: true,
      );
      await player.done;
      expect(port.spoken, [
        'device:The first sentence is here now, long enough to be alone.',
        'device:The second one arrives later.',
      ]);
    });

    test('pressing it again stops it', () async {
      final container = make(const VoiceSettings());
      port.instantSpeech = false;
      final player = container.read(speechPlayerProvider.notifier);
      player.toggle('m1', 'A sentence that is long enough to be said alone.');
      await _settle();
      await _settle();
      expect(port.spoken, hasLength(1));
      player.toggle('m1', 'ignored');
      expect(container.read(speechPlayerProvider).speaking, isFalse);
      expect(port.stops, 1);
    });
  });

  group('Dictation', () {
    test('listens until a pause, then hands over the transcript', () async {
      final container = make(
        const VoiceSettings(serverStt: true, silenceMs: 500),
      );
      final dictation = container.read(dictationProvider.notifier);
      final results = <String>[];
      final subscription = dictation.results.listen(results.add);
      addTearDown(subscription.cancel);
      await dictation.start();
      expect(container.read(dictationProvider).phase, DictationPhase.listening);
      port
        ..level(0.3, const Duration(milliseconds: 100))
        ..level(0.0, const Duration(milliseconds: 400));
      expect(container.read(dictationProvider).phase, DictationPhase.listening);
      port.level(0.0, const Duration(milliseconds: 700));
      await _settle();
      await _settle();
      expect(results, ['Hello from the microphone']);
      expect(container.read(dictationProvider).phase, DictationPhase.idle);
      expect(port.transcribed, ['v0']);
    });

    test('says so when the server does not transcribe', () async {
      final container = make(const VoiceSettings());
      await container.read(dictationProvider.notifier).start();
      expect(
        container.read(dictationProvider).problem,
        DictationProblem.unavailable,
      );
      expect(port.listening, isNull);
    });

    test('says so when there is no microphone', () async {
      final container = make(const VoiceSettings(serverStt: true));
      port.microphone = false;
      await container.read(dictationProvider.notifier).start();
      expect(
        container.read(dictationProvider).problem,
        DictationProblem.microphone,
      );
    });

    test('hold to talk ignores pauses until let go', () async {
      final container = make(
        const VoiceSettings(serverStt: true, silenceMs: 300),
      );
      final dictation = container.read(dictationProvider.notifier);
      await dictation.start(hold: true);
      port
        ..level(0.3, const Duration(milliseconds: 100))
        ..level(0, const Duration(seconds: 5));
      expect(container.read(dictationProvider).phase, DictationPhase.listening);
      await dictation.finish();
      expect(port.transcribed, ['v0']);
    });

    test('cancel throws the recording away', () async {
      final container = make(const VoiceSettings(serverStt: true));
      final dictation = container.read(dictationProvider.notifier);
      await dictation.start();
      dictation.cancel();
      expect(port.cancelled, 1);
      expect(port.transcribed, isEmpty);
      expect(container.read(dictationProvider).phase, DictationPhase.idle);
    });
  });

  group('VoiceCall', () {
    Future<void> speakAndPause(RecordingVoice port) async {
      port
        ..level(0.4, const Duration(milliseconds: 100))
        ..level(0, const Duration(milliseconds: 900));
      for (var i = 0; i < 4; i++) {
        await _settle();
      }
    }

    test('listens, sends, reads the answer, and listens again', () async {
      final container = make(
        const VoiceSettings(serverStt: true, silenceMs: 500),
      );
      final call = container.read(voiceCallProvider.notifier);
      await call.start();
      expect(container.read(voiceCallProvider).phase, CallPhase.listening);
      await speakAndPause(port);
      expect(chat.sent, ['Hello from the microphone']);
      expect(container.read(voiceCallProvider).phase, CallPhase.thinking);
      expect(
        container.read(voiceCallProvider).heard,
        'Hello from the microphone',
      );

      port.instantSpeech = false;
      turns.add(
        const LiveTurn(
          chatId: 'c1',
          messageId: 'a1',
          text: 'Hi there, this is the first part of the answer, said by itself. And',
        ),
      );
      await _settle();
      await _settle();
      expect(container.read(voiceCallProvider).phase, CallPhase.speaking);
      expect(port.spoken, [
        'device:Hi there, this is the first part of the answer, said by itself.',
      ]);
      turns.add(
        const LiveTurn(
          chatId: 'c1',
          messageId: 'a1',
          text: 'Hi there, this is the first part of the answer, said by itself. And more.',
          settled: true,
        ),
      );
      await _settle();
      port.finishSpeech();
      await _settle();
      await _settle();
      port.finishSpeech();
      for (var i = 0; i < 4; i++) {
        await _settle();
      }
      expect(port.spoken.last, 'device:And more.');
      expect(container.read(voiceCallProvider).phase, CallPhase.listening);
      expect(port.listening, isNotNull, reason: 'the microphone is open again');
    });

    test('barge-in stops the answer and hears the next question', () async {
      final container = make(
        const VoiceSettings(serverStt: true, silenceMs: 500, bargeIn: true),
      );
      final call = container.read(voiceCallProvider.notifier);
      await call.start();
      await speakAndPause(port);
      port.instantSpeech = false;
      turns.add(
        const LiveTurn(
          chatId: 'c1',
          messageId: 'a1',
          text: 'A long answer is being read out loud to you now. More',
        ),
      );
      await _settle();
      await _settle();
      expect(container.read(voiceCallProvider).phase, CallPhase.speaking);
      expect(port.listening, isNotNull, reason: 'listening for a barge-in');
      port.level(0.5, const Duration(milliseconds: 50));
      expect(container.read(voiceCallProvider).phase, CallPhase.listening);
      expect(container.read(speechPlayerProvider).speaking, isFalse);
      port.level(0, const Duration(milliseconds: 700));
      for (var i = 0; i < 4; i++) {
        await _settle();
      }
      expect(chat.sent, hasLength(2));
    });

    test('mute closes the microphone; pause and end stop everything', () async {
      final container = make(const VoiceSettings(serverStt: true));
      final call = container.read(voiceCallProvider.notifier);
      await call.start();
      await call.toggleMute();
      expect(container.read(voiceCallProvider).muted, isTrue);
      expect(port.listening, isNull);
      await call.toggleMute();
      expect(port.listening, isNotNull);
      call.pause();
      expect(container.read(voiceCallProvider).phase, CallPhase.paused);
      expect(port.listening, isNull);
      await call.resume();
      expect(container.read(voiceCallProvider).phase, CallPhase.listening);
      call.end();
      expect(container.read(voiceCallProvider).active, isFalse);
      expect(port.listening, isNull);
    });
  });
}
