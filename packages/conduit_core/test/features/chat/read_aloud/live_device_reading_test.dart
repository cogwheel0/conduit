import 'dart:async';

import 'package:conduit_core/features/chat/read_aloud/device_speech_engine.dart';
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_controller.dart';
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_service.dart';
import 'package:conduit_core/features/chat/read_aloud/tts_manager.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  final manager = TtsManager.instance;
  late _Engine engine;
  final events = <TtsEvent>[];
  late StreamSubscription<TtsEvent> sub;

  setUp(() async {
    engine = _Engine();
    events.clear();
    sub = manager.events.listen(events.add);
    manager.setServerSpeech(null);
    await manager.debugSetNativeTtsService(engine);
    await manager.initialize(
      config: const TtsConfig(splitOn: TtsManager.splitOnParagraphs),
    );
  });

  tearDown(() async {
    await manager.reset();
    await sub.cancel();
  });

  const text = 'A red kite.\n\nTwo green frogs.\n\nThree tall pines.';

  test('a live reading moves to a sentence without ending', () async {
    await manager.speak(text);
    expect(engine.spoken, ['A red kite.']);
    expect(manager.canSeekChunks, isTrue);

    expect(await manager.seekToChunk(2), 2);
    expect(engine.spoken.last, 'Three tall pines.');
    expect(manager.currentChunkIndex, 2);
    expect(events.whereType<TtsChunkStarted>().map((e) => e.chunkIndex), [
      0,
      2,
    ]);
    expect(events.whereType<TtsCancelled>(), isEmpty);
    expect(manager.isPlaying, isTrue);

    // The last sentence ends the reading.
    engine.emit('complete');
    await pumpEventQueue();
    expect(events.last, isA<TtsCompleted>());
  });

  test(
    'moving while paused stays paused, and resuming says it from there',
    () async {
      await manager.speak(text);
      await manager.pause();
      engine.emit('pause');
      await pumpEventQueue();

      expect(await manager.seekToChunk(1), 1);
      // Nothing new is said while paused.
      expect(engine.spoken, ['A red kite.']);
      expect(manager.currentChunkIndex, 1);

      await manager.resume();
      await pumpEventQueue();
      expect(engine.spoken.last, 'Two green frogs.');
      expect(engine.resumes, 0);
      expect(events.last, isA<TtsResumed>());
    },
  );

  test('a pause the voice never reports still pauses the reading', () async {
    await manager.speak(text);
    events.clear();

    // The engine pauses and answers, but sends no `pause` of its own.
    await manager.pause();
    await pumpEventQueue();
    expect(events.whereType<TtsPaused>(), hasLength(1));

    await manager.resume();
    await pumpEventQueue();
    expect(engine.resumes, 1);
    expect(events.last, isA<TtsResumed>());
  });

  test(
    'a sentence that ends while a pause is on its way holds the next one',
    () async {
      await manager.speak(text);
      // The first sentence ends just as the engine is asked to pause.
      engine.duringPause = () async {
        engine.emit('complete');
        await pumpEventQueue();
      };
      await manager.pause();
      await pumpEventQueue();

      expect(engine.spoken, ['A red kite.'], reason: 'nothing more is said');
      expect(manager.currentChunkIndex, 1);
      expect(events.last, isA<TtsPaused>());

      await manager.resume();
      await pumpEventQueue();
      expect(engine.spoken.last, 'Two green frogs.');
      expect(events.last, isA<TtsResumed>());
    },
  );

  test('a late pause report does not pause a reading resumed since', () async {
    await manager.speak(text);
    await manager.pause();
    await manager.resume();
    await pumpEventQueue();

    engine.emit('pause');
    await pumpEventQueue();
    expect(events.last, isA<TtsResumed>());
  });

  test(
    'a new speed says the rest of the sentence from the word reached',
    () async {
      await manager.speak(text);
      // "Two" in the second sentence is being said.
      expect(await manager.seekToChunk(1), 1);
      engine.emitProgress(4, 9); // "green"
      await pumpEventQueue();

      await manager.updateConfig(manager.config.copyWith(speed: 1.5));
      expect(engine.spoken.last, 'green frogs.');
      expect(engine.rates.last, closeTo(0.75, 1e-9));

      // Words of the rest still count from the sentence's start.
      engine.emitProgress(6, 11); // "frogs" in "green frogs."
      await pumpEventQueue();
      final word = events.whereType<TtsWordProgress>().last;
      expect((word.start, word.end), (10, 15));
      expect('Two green frogs.'.substring(word.start, word.end), 'frogs');
    },
  );

  test('an engine that cannot replace what it says cannot move', () async {
    engine.replaces = false;
    await manager.speak(text);
    expect(manager.canSeekChunks, isFalse);
    expect(await manager.seekToChunk(1), isNull);
    expect(engine.spoken, ['A red kite.']);
  });

  group('controller', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(const AppSettings()),
          readAloudLiveDeviceSpeechProvider.overrideWithValue(true),
          textToSpeechServiceProvider.overrideWith(
            (ref) => TextToSpeechService(),
          ),
        ],
      );
    });
    tearDown(() => container.dispose());

    test('reads live, names the chat, and skips by sentence', () async {
      final controller = container.read(
        textToSpeechControllerProvider.notifier,
      );
      TextToSpeechState state() =>
          container.read(textToSpeechControllerProvider);

      await controller.readAloud(
        messageId: 'answer-1',
        chatId: 'chat-7',
        text: text,
      );
      engine.emit('start');
      await pumpEventQueue();
      expect(state().activeChatId, 'chat-7');
      expect(state().activeMessageId, 'answer-1');
      expect(state().sentences, hasLength(3));
      expect(state().canSeekSentences, isTrue);
      // Live: the device engine said the first sentence, no clip rendered.
      expect(engine.spoken, ['A red kite.']);
      expect(engine.rendered, isEmpty);

      await controller.skipSentences(1);
      expect(state().activeSentenceIndex, 1);
      expect(engine.spoken.last, 'Two green frogs.');
      await controller.skipSentences(5);
      expect(state().activeSentenceIndex, 1, reason: 'past the end: no move');
      await controller.skipSentences(-4);
      expect(state().activeSentenceIndex, 0);
      await controller.seekToSentence(2);
      expect(state().activeSentenceIndex, 2);

      await controller.stop();
      expect(state().activeChatId, isNull);
      expect(state().activeMessageId, isNull);
    });
  });

  test('read-aloud text leaves out folded sections and markup', () {
    const raw =
        '<details type="reasoning"><summary>Thought</summary>Hidden.</details>\n'
        'The **lake** is [cold](https://example.com) today.';
    expect(readAloudTextOf(raw), 'The lake is cold today.');
    expect(readAloudTextOf('   '), '');
  });
}

class _Engine implements DeviceSpeechEngine {
  final _events = StreamController<NativeTtsEvent>.broadcast();
  final spoken = <String>[];
  final rendered = <String>[];
  final rates = <double>[];
  bool replaces = true;
  int resumes = 0;

  /// Runs while a pause is being answered.
  Future<void> Function()? duringPause;

  void emit(String type) => _events.add(NativeTtsEvent(type: type));

  void emitProgress(int start, int end) =>
      _events.add(NativeTtsEvent(type: 'progress', start: start, end: end));

  @override
  Stream<NativeTtsEvent> get events => _events.stream;

  @override
  String get engineName => 'test';

  @override
  bool get replacesOnSpeak => replaces;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<Map<String, dynamic>>> getVoices() async => const [];

  @override
  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
    bool voiceCall = false,
  }) async {
    spoken.add(text);
    rates.add(rate);
    return true;
  }

  @override
  Future<NativeTtsAudio> synthesize({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
  }) async {
    rendered.add(text);
    throw StateError('not in this test');
  }

  @override
  Future<bool> cancelSynthesis() async => true;

  @override
  Future<bool> stop() async => true;

  @override
  Future<bool> pause() async {
    await duringPause?.call();
    return true;
  }

  @override
  Future<bool> resume() async {
    resumes++;
    return true;
  }
}
