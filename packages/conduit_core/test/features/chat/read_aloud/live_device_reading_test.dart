import 'package:checks/checks.dart';

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
    // The host's engine again, for the tests that share this isolate.
    await manager.debugSetNativeTtsService(null);
    await sub.cancel();
  });

  const text = 'A red kite.\n\nTwo green frogs.\n\nThree tall pines.';

  test('a live reading moves to a sentence without ending', () async {
    await manager.speak(text);
    check(engine.spoken).deepEquals(['A red kite.']);
    check(manager.canSeekChunks).isTrue();

    check(await manager.seekToChunk(2)).equals(2);
    check(engine.spoken.last).equals('Three tall pines.');
    check(manager.currentChunkIndex).equals(2);
    check(events.whereType<TtsChunkStarted>().map((e) => e.chunkIndex))
        .deepEquals([0, 2]);
    check(events.whereType<TtsCancelled>()).isEmpty();
    check(manager.isPlaying).isTrue();

    // The last sentence ends the reading.
    engine.emit('complete');
    await pumpEventQueue();
    check(events.last).isA<TtsCompleted>();
  });

  test(
    'moving while paused stays paused, and resuming says it from there',
    () async {
      await manager.speak(text);
      await manager.pause();
      engine.emit('pause');
      await pumpEventQueue();

      check(await manager.seekToChunk(1)).equals(1);
      // Nothing new is said while paused.
      check(engine.spoken).deepEquals(['A red kite.']);
      check(manager.currentChunkIndex).equals(1);

      await manager.resume();
      await pumpEventQueue();
      check(engine.spoken.last).equals('Two green frogs.');
      check(engine.resumes).equals(0);
      check(events.last).isA<TtsResumed>();
    },
  );

  test('a pause that ends after its reading was replaced leaves the new '
      'one playing', () async {
    await manager.speak(text);
    final pauseGate = Completer<void>();
    engine.pauseGate = pauseGate;
    final pausing = manager.pause();
    await manager.speak('One blue boat.\n\nTwo white gulls.');
    pauseGate.complete();
    await pausing;

    check(await manager.seekToChunk(1)).equals(1);
    check(engine.spoken.last).equals('Two white gulls.');
  });

  test('of two readings asked for while the last one stops, only the later '
      'plays', () async {
    await manager.speak(text);
    final stopGate = Completer<void>();
    engine.stopGate = stopGate;
    // A waits on the old reading's stop; B is asked for meanwhile.
    final a = manager.speak('Alpha only.');
    await pumpEventQueue();
    final b = await manager.speak('Bravo first.\n\nBravo second.');
    stopGate.complete();

    check(await a).isNull();
    await pumpEventQueue();
    check(engine.spoken).not((it) => it.contains('Alpha only.'));
    check(engine.spoken.last).equals('Bravo first.');
    check(b).isNotNull();
    check(manager.isPlaying).isTrue();
  });

  test('a stop that ends after a new reading began leaves it be', () async {
    await manager.speak(text);
    final stopGate = Completer<void>();
    engine.stopGate = stopGate;
    final stopping = manager.stop();
    await manager.speak('One blue boat.\n\nTwo white gulls.');
    events.clear();
    stopGate.complete();
    await stopping;
    await pumpEventQueue();

    check(events.whereType<TtsCancelled>()).isEmpty();
    check(await manager.seekToChunk(1)).equals(1);
    check(engine.spoken.last).equals('Two white gulls.');
  });

  test('a sentence of an old reading that fails to start is not the new '
      'reading\'s error', () async {
    await manager.speak(text);
    final speakGate = Completer<bool>();
    engine.speakGate = speakGate;
    final moving = manager.seekToChunk(1);
    await manager.speak('One blue boat.');
    events.clear();
    speakGate.complete(false);
    await moving;
    await pumpEventQueue();

    check(events.whereType<TtsError>()).isEmpty();
    check(manager.isPlaying).isTrue();
  });

  test('a pause the voice never reports still pauses the reading', () async {
    await manager.speak(text);
    events.clear();

    // The engine pauses and answers, but sends no `pause` of its own.
    await manager.pause();
    await pumpEventQueue();
    check(events.whereType<TtsPaused>()).length.equals(1);

    await manager.resume();
    await pumpEventQueue();
    check(engine.resumes).equals(1);
    check(events.last).isA<TtsResumed>();
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

      check(
        because: 'nothing more is said',
        engine.spoken,
      ).deepEquals(['A red kite.']);
      check(manager.currentChunkIndex).equals(1);
      check(events.last).isA<TtsPaused>();

      await manager.resume();
      await pumpEventQueue();
      check(engine.spoken.last).equals('Two green frogs.');
      check(events.last).isA<TtsResumed>();
    },
  );

  for (final refusal in ['refuses', 'fails']) {
    test('a pause the voice $refusal leaves the reading going on', () async {
      await manager.speak(text);
      events.clear();
      if (refusal == 'refuses') {
        engine.pauseAnswer = false;
      } else {
        engine.pauseError = StateError('voice busy');
      }
      // The first sentence ends while the engine is asked.
      engine.duringPause = () async {
        engine.emit('complete');
        await pumpEventQueue();
      };
      await manager.pause();
      await pumpEventQueue();

      check(events.whereType<TtsPaused>()).isEmpty();
      check(events.whereType<TtsError>()).length
          .equals(refusal == 'fails' ? 1 : 0);
      // Not held: the next sentence is said.
      check(engine.spoken.last).equals('Two green frogs.');
    });
  }

  test('an older pause refused after a newer one took leaves it paused',
      () async {
    await manager.speak(text);
    final first = Completer<bool>();
    engine.pauseTurns
      ..add(() => first.future)
      ..add(() async => true);
    final older = manager.pause();
    await manager.pause();
    first.complete(false);
    await older;
    await pumpEventQueue();

    // Still paused: moving says nothing until it resumes.
    final said = engine.spoken.length;
    check(await manager.seekToChunk(1)).equals(1);
    check(engine.spoken).length.equals(said);
  });

  test('an older resume refused after a newer one took leaves it going',
      () async {
    await manager.speak(text);
    await manager.pause();
    await pumpEventQueue();
    final first = Completer<bool>();
    engine.resumeTurns
      ..add(() => first.future)
      ..add(() async => true);
    final older = manager.resume();
    await manager.resume();
    first.complete(false);
    await older;

    // Not held: the next sentence is said when this one ends.
    engine.emit('complete');
    await pumpEventQueue();
    check(engine.spoken.last).equals('Two green frogs.');
  });

  test('a resume the voice refuses leaves the reading paused', () async {
    await manager.speak(text);
    await manager.pause();
    await pumpEventQueue();
    events.clear();

    engine.resumeAnswer = false;
    await manager.resume();
    await pumpEventQueue();
    check(events.whereType<TtsResumed>()).isEmpty();

    engine.resumeAnswer = true;
    await manager.resume();
    await pumpEventQueue();
    check(engine.resumes).equals(2);
    check(events.last).isA<TtsResumed>();
  });

  test('a sentence picked while a pause is on its way is where it resumes',
      () async {
    await manager.speak(text);
    // While the engine is asked to pause, the second sentence is picked,
    // and then the first one ends.
    engine.duringPause = () async {
      await manager.seekToChunk(1);
      engine.emit('complete');
      await pumpEventQueue();
    };
    await manager.pause();
    await pumpEventQueue();

    await manager.resume();
    await pumpEventQueue();
    check(engine.spoken.last).equals('Two green frogs.');
  });

  test('a late pause report does not pause a reading resumed since', () async {
    await manager.speak(text);
    await manager.pause();
    await manager.resume();
    await pumpEventQueue();

    engine.emit('pause');
    await pumpEventQueue();
    check(events.last).isA<TtsResumed>();
  });

  test(
    'a new speed says the rest of the sentence from the word reached',
    () async {
      await manager.speak(text);
      // "Two" in the second sentence is being said.
      check(await manager.seekToChunk(1)).equals(1);
      engine.emitProgress(4, 9); // "green"
      await pumpEventQueue();

      await manager.updateConfig(manager.config.copyWith(speed: 1.5));
      check(engine.spoken.last).equals('green frogs.');
      check(engine.rates.last).isCloseTo(0.75, 1e-9);

      // Words of the rest still count from the sentence's start.
      engine.emitProgress(6, 11); // "frogs" in "green frogs."
      await pumpEventQueue();
      final word = events.whereType<TtsWordProgress>().last;
      check((word.start, word.end)).equals((10, 15));
      check('Two green frogs.'.substring(word.start, word.end)).equals('frogs');
    },
  );

  test('an engine that cannot replace what it says cannot move', () async {
    engine.replaces = false;
    await manager.speak(text);
    check(manager.canSeekChunks).isFalse();
    check(await manager.seekToChunk(1)).isNull();
    check(engine.spoken).deepEquals(['A red kite.']);
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
      check(state().activeChatId).equals('chat-7');
      check(state().activeMessageId).equals('answer-1');
      check(state().sentences).length.equals(3);
      check(state().canSeekSentences).isTrue();
      // Live: the device engine said the first sentence, no clip rendered.
      check(engine.spoken).deepEquals(['A red kite.']);
      check(engine.rendered).isEmpty();

      await controller.skipSentences(1);
      check(state().activeSentenceIndex).equals(1);
      check(engine.spoken.last).equals('Two green frogs.');
      await controller.skipSentences(5);
      check(
        because: 'past the end: no move',
        state().activeSentenceIndex,
      ).equals(1);
      await controller.skipSentences(-4);
      check(state().activeSentenceIndex).equals(0);
      await controller.seekToSentence(2);
      check(state().activeSentenceIndex).equals(2);

      await controller.stop();
      check(state().activeChatId).isNull();
      check(state().activeMessageId).isNull();
    });
  });

  test('read-aloud text leaves out folded sections and markup', () {
    const raw =
        '<details type="reasoning"><summary>Thought</summary>Hidden.</details>\n'
        'The **lake** is [cold](https://example.com) today.';
    check(readAloudTextOf(raw)).equals('The lake is cold today.');
    check(readAloudTextOf('   ')).equals('');
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
    final gate = speakGate;
    speakGate = null;
    if (gate != null) return gate.future;
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

  /// Holds the next [stop] until completed.
  Completer<void>? stopGate;

  /// Answers the next [speak] when completed.
  Completer<bool>? speakGate;

  @override
  Future<bool> stop() async {
    final gate = stopGate;
    stopGate = null;
    await gate?.future;
    return true;
  }

  /// Holds [pause] until completed.
  Completer<void>? pauseGate;

  /// What the next [pause] answers, or the error it fails with.
  bool pauseAnswer = true;
  Object? pauseError;

  /// What [resume] answers.
  bool resumeAnswer = true;

  /// Answers for the next calls, one per call, before the fields above.
  final pauseTurns = <Future<bool> Function()>[];
  final resumeTurns = <Future<bool> Function()>[];

  @override
  @override
  Future<bool> pause() async {
    if (pauseTurns.isNotEmpty) return pauseTurns.removeAt(0)();
    await pauseGate?.future;
    await duringPause?.call();
    final error = pauseError;
    pauseError = null;
    if (error != null) throw error;
    final answer = pauseAnswer;
    pauseAnswer = true;
    return answer;
  }

  @override
  Future<bool> resume() async {
    resumes++;
    if (resumeTurns.isNotEmpty) return resumeTurns.removeAt(0)();
    return resumeAnswer;
  }
}
