import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:conduit_core/features/chat/read_aloud/device_speech_engine.dart';
import 'package:conduit_core/features/chat/read_aloud/tts_manager.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech.dart';
import 'package:conduit_core/ports/audio_playback_port.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

/// A reading replaced, or ended, while it still has work under way: none of
/// the earlier reading's late work may reach the player, the clips or the
/// listeners of the one that replaced it. A device reading's renders ahead
/// join in order.
void main() {
  final player = _Player();
  final previousFactory = AudioPlaybackPort.hostFactory;
  // Before the manager is first made, so it plays through this player.
  AudioPlaybackPort.hostFactory = () => player;
  tearDownAll(() => AudioPlaybackPort.hostFactory = previousFactory);
  final manager = TtsManager.instance;
  final store = _ClipStore();
  final previousStore = TtsManager.clipStore;
  late _Engine engine;
  late Directory temp;
  final events = <TtsEvent>[];
  late StreamSubscription<TtsEvent> sub;

  setUpAll(() => TtsManager.clipStore = store);
  tearDownAll(() => TtsManager.clipStore = previousStore);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('replaced-reading');
    engine = _Engine(temp);
    player.reset();
    store.reset();
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
    await manager.debugSetNativeTtsService(null);
    manager.setServerSpeech(null);
    await sub.cancel();
    await temp.delete(recursive: true);
  });

  test('a stop still cancelling its synthesis leaves the next reading '
      'playing', () async {
    manager.setServerSpeech(_Server());
    await manager.speak('Old strip.', useServer: true, seekable: true);
    final cancelling = engine.cancelGate = Completer<void>();
    final stopping = manager.stop();
    await manager.speak('New strip.', useServer: true, seekable: true);
    final stopsBefore = player.stops;
    events.clear();

    cancelling.complete();
    await stopping;
    await pumpEventQueue();

    check(player.stops).equals(stopsBefore);
    check(player.playing).isTrue();
    check(events.whereType<TtsCancelled>()).isEmpty();
  });

  test('a stop still cancelling its synthesis reports nothing once a later '
      'reading has run and ended', () async {
    manager.setServerSpeech(_Server());
    await manager.speak('Old strip.', useServer: true, seekable: true);
    final cancelling = engine.cancelGate = Completer<void>();
    final stopping = manager.stop();
    await manager.speak('New strip.', useServer: true, seekable: true);
    await manager.stop();
    await pumpEventQueue();
    events.clear();

    cancelling.complete();
    await stopping;
    await pumpEventQueue();

    check(events).isEmpty();
  });

  test(
    'a clip an old reading was adding never joins the new reading',
    () async {
      await manager.speak('Old one.\n\nOld two.', seekable: true);
      // The second clip is on its way to the player.
      final adding = player.addGate = Completer<void>();
      await player.addWaiting.future;

      // Rendering takes no I/O wait here, so the new reading is as far as it
      // can get before the old clip's add ends.
      final replacing = manager.speak('New one.', seekable: true);
      await pumpEventQueue();
      adding.complete();
      await replacing;
      await pumpEventQueue();

      check(player.clips.map((clip) => clip.tag)).deepEquals([0]);
      check(engine.rendered.last).equals('New one.');
    },
  );

  test('a failed reading\'s slow stop does not stop the next reading',
      () async {
    manager.setServerSpeech(_Server());
    await manager.speak('Old strip.', useServer: true, seekable: true);
    // The reading fails while moving, and the player is slow to stop.
    final stopping = player.stopGate = Completer<void>();
    player.failSeek = true;
    final failed = manager.events.firstWhere((e) => e is TtsError);
    await manager.seekTo(const Duration(seconds: 1));
    await failed;
    player.failSeek = false;

    final replacing = manager.speak(
      'New strip.',
      useServer: true,
      seekable: true,
    );
    await pumpEventQueue();
    stopping.complete();
    await replacing;
    await pumpEventQueue();

    check(player.clips).length.equals(1);
    check(player.playing).isTrue();
  });

  test('an old reading whose second clip comes late leaves the new one '
      'playing', () async {
    final second = Completer<SynthesizedSpeech>();
    final asked = Completer<void>();
    manager.setServerSpeech(
      _Server()
        ..pending['Old two.'] = second
        ..asked['Old two.'] = asked,
    );
    final old = manager.speak(
      'Old one.\n\nOld two.',
      useServer: true,
      seekable: true,
    );
    // The old reading waits for its second clip before it plays.
    await asked.future;
    await manager.speak('New one.', useServer: true, seekable: true);
    final playing = List<AudioClip>.of(player.clips);
    second.complete(_audio);
    await old;
    await pumpEventQueue();

    check(player.clips).deepEquals(playing);
    check(player.playing).isTrue();
  });

  test('a missing clip an old reading could not recover is not the new '
      'reading\'s error', () async {
    final recovery = Completer<SynthesizedSpeech>();
    manager.setServerSpeech(
      _Server()
        ..turns['Old two.'] = [
          // Refused for the first play and again for its fetch (a 4xx is
          // not tried again, so neither waits); then the fetch that tries
          // once more when the first clip has ended.
          () => Future.error(_refused()),
          () => Future.error(_refused()),
          () => recovery.future,
        ],
    );
    final refusedOnce = manager.events.firstWhere((e) => e is TtsError);
    await manager.speak('Old one.\n\nOld two.', useServer: true);
    await refusedOnce;
    player.complete();
    await pumpEventQueue();
    await manager.speak('New one.', useServer: true);
    await pumpEventQueue();
    events.clear();

    recovery.completeError(_refused());
    await pumpEventQueue();

    check(events.whereType<TtsError>()).isEmpty();
    check(player.playing).isTrue();
  });

  test('a streaming reading whose first clip cannot be kept fails, and says '
      'so', () async {
    manager.setServerSpeech(_Server());
    store.failNext = true;
    await manager.startStreaming(useServer: true);
    final failed = manager.events.firstWhere((event) => event is TtsError);

    await manager.finishStreaming(finalText: 'Only line.');

    check(await failed).isA<TtsError>();
    check(manager.activeUsesServer).isNull();
  });

  test('cleaning up an old reading keeps the new one\'s clips', () async {
    final deleting = Completer<void>();
    final deleted = Completer<void>();
    // The old reading's speech file is deleted only once [deleting] ends.
    await IOOverrides.runZoned(
      () => manager.speak('Old strip.', seekable: true),
      createFile: (path) => path == engine.lastPath
          ? _GatedFile(path, deleting.future, deleted)
          : Zone.root.run(() => File(path)),
    );
    final oldFile = engine.lastPath!;

    manager.setServerSpeech(_Server());
    await manager.speak('New strip.', useServer: true, seekable: true);
    check(store.stored).length.equals(1);
    deleting.complete();
    await deleted.future;
    await pumpEventQueue();

    check(store.released).isEmpty();
    check(File(oldFile).existsSync()).isFalse();
  });

  test(
    'a device reading renders three chunks ahead and adds them in order',
    () async {
      engine.queueRenders = true;
      final reading = manager.speak(
        'A strip.\n\nB strip.\n\nC strip.\n\nD strip.\n\nE strip.',
        seekable: true,
      );
      await pumpEventQueue();
      engine.answerFirst();
      await reading;
      await pumpEventQueue();
      check(engine.waiting).deepEquals(['B strip.', 'C strip.', 'D strip.']);

      // A later chunk rendered first waits for the one before it.
      engine.answer('C strip.');
      await pumpEventQueue();
      check(player.clips.map((clip) => clip.tag)).deepEquals([0]);

      engine.answer('B strip.');
      await pumpEventQueue();
      check(player.clips.map((clip) => clip.tag)).deepEquals([0, 1, 2]);
      check(engine.waiting).deepEquals(['D strip.', 'E strip.']);

      engine.answer('E strip.');
      engine.answer('D strip.');
      await pumpEventQueue();
      check(player.clips.map((clip) => clip.tag)).deepEquals([0, 1, 2, 3, 4]);
      check(manager.playbackDuration).equals(const Duration(seconds: 100));
    },
  );

  /// Starts a device reading of four chunks: the first playing, the other
  /// three asked for and not yet answered.
  Future<void> startReadingWithRendersUnderWay() async {
    engine.queueRenders = true;
    final old = manager.speak(
      'Old one.\n\nOld two.\n\nOld three.\n\nOld four.',
      seekable: true,
    );
    await pumpEventQueue();
    engine.answerFirst();
    await old;
    await pumpEventQueue();
    check(engine.waiting).deepEquals(['Old two.', 'Old three.', 'Old four.']);
  }

  test('a reading whose render fails drops the renders still under way, so '
      'the next reading\'s goes first', () async {
    // The clip that landed is deleted by the failed reading's cleanup, which
    // nothing awaits; [deleted] marks when it is gone.
    final deleted = Completer<void>();
    String? landed;
    await IOOverrides.runZoned(
      () async {
        await startReadingWithRendersUnderWay();
        final finishedEarly = landed = engine.pathOf('Old three.');
        final stillWriting = engine.pathOf('Old four.');
        final failed = manager.events.firstWhere((event) => event is TtsError);

        // The third chunk lands before the second fails, the fourth never
        // does.
        engine.answer('Old three.');
        engine.failFirst();
        await failed;
        check(manager.isPlaying).isFalse();
        check(player.clips.map((clip) => clip.tag)).deepEquals([0]);
        final replacing = manager.speak('New one.', seekable: true);
        await pumpEventQueue();

        check(engine.waiting).deepEquals(['New one.']);
        await deleted.future;
        check(Zone.root.run(() => File(finishedEarly).existsSync())).isFalse();
        check(File(stillWriting).existsSync()).isFalse();
        engine.answerFirst();
        await replacing;
        await pumpEventQueue();
        check(player.clips.map((clip) => clip.uri))
            .deepEquals([File(engine.lastPath!).uri]);
        check(player.playing).isTrue();
        check(events.whereType<TtsError>()).length.equals(1);
      },
      createFile: (path) => path == landed
          ? _GatedFile(path, Future<void>.value(), deleted)
          : Zone.root.run(() => File(path)),
    );
  });

  test('a render asked for while a failed reading\'s renders are being '
      'dropped is not dropped with them', () async {
    await startReadingWithRendersUnderWay();
    final failed = manager.events.firstWhere((event) => event is TtsError);
    final dropping = engine.cancelGate = Completer<void>();

    engine.failFirst();
    await failed;
    final replacing = manager.speak('New one.', seekable: true);
    await pumpEventQueue();
    // Asked for only once the engine has dropped the old ones.
    check(engine.waiting).deepEquals(['Old three.', 'Old four.']);
    dropping.complete();
    await pumpEventQueue();

    check(engine.waiting).deepEquals(['New one.']);
    engine.answerFirst();
    await replacing;
    await pumpEventQueue();
    check(player.playing).isTrue();
    check(events.whereType<TtsError>()).length.equals(1);
  });
}

DioException _refused() => DioException(
  requestOptions: RequestOptions(path: '/audio/speech'),
  response: Response<void>(
    requestOptions: RequestOptions(path: '/audio/speech'),
    statusCode: 400,
  ),
);

final SynthesizedSpeech _audio = (
  bytes: Uint8List.fromList([1, 2, 3]),
  mimeType: 'audio/wav',
);

/// A player that keeps its playlist in memory. [addGate] holds the next
/// clip added until it completes; [addWaiting] says one is held.
final class _Player extends NullAudioPlayback {
  final clips = <AudioClip>[];
  final _states = StreamController<AudioPlaybackState>.broadcast(sync: true);
  final _indices = StreamController<int?>.broadcast(sync: true);
  bool playing = false;
  int stops = 0;
  int index = 0;
  AudioProcessingState processing = AudioProcessingState.ready;
  Completer<void>? addGate;
  Completer<void> addWaiting = Completer<void>();

  /// Holds the next stop until completed.
  Completer<void>? stopGate;

  /// A seek fails while set.
  bool failSeek = false;

  void reset() {
    clips.clear();
    playing = false;
    stops = 0;
    index = 0;
    processing = AudioProcessingState.ready;
    addGate = null;
    addWaiting = Completer<void>();
    stopGate = null;
    failSeek = false;
  }

  /// The clip playing comes to its end.
  void complete() {
    processing = AudioProcessingState.completed;
    _states.add(
      AudioPlaybackState(playing: playing, processingState: processing),
    );
  }

  @override
  Stream<AudioPlaybackState> get stateChanges => _states.stream;

  @override
  Stream<int?> get currentIndexChanges => _indices.stream;

  @override
  int? get currentIndex => index;

  @override
  AudioProcessingState get processingState => processing;

  @override
  Future<Duration?> durationOf(AudioClip clip) async =>
      const Duration(seconds: 20);

  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    this.clips
      ..clear()
      ..addAll(clips);
    index = initialIndex;
    processing = AudioProcessingState.ready;
  }

  @override
  Future<void> addClip(AudioClip clip) async {
    final gate = addGate;
    addGate = null;
    if (gate != null) {
      if (!addWaiting.isCompleted) addWaiting.complete();
      await gate.future;
    }
    clips.add(clip);
  }

  @override
  Future<void> clearClips() async => clips.clear();

  @override
  Future<void> play() async {
    playing = true;
    _states.add(AudioPlaybackState(playing: true, processingState: processing));
  }

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (failSeek) throw StateError('seek failed');
  }

  @override
  Future<void> stop() async {
    stops++;
    final gate = stopGate;
    stopGate = null;
    await gate?.future;
    playing = false;
  }
}

/// A device voice that renders each chunk to a file under [dir], and whose
/// [cancelSynthesis] waits for [cancelGate] when set.
///
/// With [queueRenders] set, a render waits until the test answers it
/// ([answer], [answerFirst], [failFirst]), its file there from the moment it
/// is asked for; [cancelSynthesis] fails every render not yet answered and
/// deletes its file, as both bridges do.
final class _Engine extends Fake implements DeviceSpeechEngine {
  _Engine(this.dir);

  final Directory dir;
  final rendered = <String>[];
  String? lastPath;
  Completer<void>? cancelGate;
  bool queueRenders = false;
  final queued = <_Render>[];

  /// The texts of the renders not yet answered, in the order asked.
  List<String> get waiting => [for (final render in queued) render.text];

  String pathOf(String text) =>
      queued.firstWhere((render) => render.text == text).path;

  void answer(String text) {
    final render = queued.firstWhere((render) => render.text == text);
    queued.remove(render);
    render.answer.complete(
      NativeTtsAudio(render.path, const Duration(seconds: 20)),
    );
  }

  void answerFirst() => answer(queued.first.text);

  void failFirst() => queued.removeAt(0).fail();

  @override
  Stream<NativeTtsEvent> get events => const Stream<NativeTtsEvent>.empty();

  @override
  String get engineName => 'test';

  @override
  bool get replacesOnSpeak => true;

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
  }) async => true;

  @override
  Future<NativeTtsAudio> synthesize({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
  }) async {
    rendered.add(text);
    final path = '${dir.path}/speech-${rendered.length}.caf';
    // Written at once, so a reading's start waits on nothing but the code.
    Zone.root.run(() => File(path)).writeAsStringSync('synthetic');
    lastPath = path;
    if (queueRenders) {
      final render = _Render(text, path);
      queued.add(render);
      return render.answer.future;
    }
    return NativeTtsAudio(path, const Duration(seconds: 20));
  }

  @override
  Future<bool> cancelSynthesis() async {
    final gate = cancelGate;
    cancelGate = null;
    await gate?.future;
    final dropped = List<_Render>.of(queued);
    queued.clear();
    for (final render in dropped) {
      render.fail();
    }
    return true;
  }

  @override
  Future<bool> stop() async => true;

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;
}

/// A render the engine has not answered yet, and the file it is writing.
final class _Render {
  _Render(this.text, this.path);

  final String text;
  final String path;
  final answer = Completer<NativeTtsAudio>();

  /// Fails it as both bridges do: its incomplete file is deleted first.
  void fail() {
    Zone.root.run(() => File(path)).deleteSync();
    answer.completeError(StateError('Synthetic render failure'));
  }
}

/// Server speech answering each text at once, or when the test completes
/// [pending]'s completer for it; [asked] completes as a text is asked for.
final class _Server extends Fake implements ServerSpeechProvider {
  final pending = <String, Completer<SynthesizedSpeech>>{};
  final asked = <String, Completer<void>>{};

  /// Answers for a text, one per request in turn, before [pending]'s.
  final turns = <String, List<Future<SynthesizedSpeech> Function()>>{};

  @override
  ServerSpeechSource get source => ServerSpeechSource.hermes;

  @override
  bool get canSynthesize => true;

  @override
  bool get offersVoiceChoice => false;

  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async {
    final ask = asked[text];
    if (ask != null && !ask.isCompleted) ask.complete();
    final queued = turns[text];
    if (queued != null && queued.isNotEmpty) {
      return await queued.removeAt(0)();
    }
    return await (pending[text]?.future ?? Future.value(_audio));
  }
}

/// Keeps clips in memory and records what it keeps and releases; fails the
/// next store when [failNext] is set.
final class _ClipStore implements TtsClipStore {
  final stored = <Uri>[];
  final released = <Uri>[];
  bool failNext = false;

  void reset() {
    stored.clear();
    released.clear();
    failNext = false;
  }

  @override
  Future<Uri> store(
    int sessionId,
    int index,
    Uint8List bytes,
    String mimeType,
  ) async {
    if (failNext) {
      failNext = false;
      throw const FileSystemException('disk full');
    }
    final uri = Uri.parse('memory:/$sessionId/$index');
    stored.add(uri);
    return uri;
  }

  @override
  Future<void> release(Uri uri) async => released.add(uri);
}

/// A speech file whose deletion waits for [gate]; [deleted] completes once
/// the file is gone.
final class _GatedFile extends Fake implements File {
  _GatedFile(this.path, this.gate, this.deleted);

  @override
  final String path;
  final Future<void> gate;
  final Completer<void> deleted;

  @override
  Uri get uri => Uri.file(path);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await gate;
    final gone = await Zone.root.run(() => File(path).delete());
    deleted.complete();
    return gone;
  }
}
