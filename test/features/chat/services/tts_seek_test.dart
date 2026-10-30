import 'dart:async';
import 'dart:io';

import 'package:conduit/features/chat/services/native_tts_service.dart';
import 'package:conduit/features/chat/services/tts_manager.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final player = _Player();
  AudioPlaybackPort.hostFactory = () => player;
  final manager = TtsManager.instance;
  late _Device device;

  setUp(() async {
    device = _Device();
    await manager.debugSetNativeTtsService(device);
    await manager.initialize(config: const TtsConfig());
  });

  tearDown(() async {
    await manager.reset();
  });

  test(
    'device read-aloud renders a seekable queue and jumps across chunks',
    () async {
      await manager.updateConfig(
        const TtsConfig(splitOn: TtsManager.splitOnParagraphs),
      );
      await manager.speak(
        'One paper square.\n\nAnother paper square.',
        seekable: true,
      );
      expect(device.rendered, ['One paper square.', 'Another paper square.']);
      expect(device.liveSpeech, 0);
      expect(manager.canSeek, isTrue);
      expect(manager.playbackDuration, const Duration(seconds: 40));
      player.at(0, const Duration(seconds: 12));
      expect(
        await manager.seekRelative(const Duration(seconds: 15)),
        const Duration(seconds: 27),
      );
      expect(player.currentIndex, 1);
      expect(player.position, const Duration(seconds: 7));
      expect(player.playing, isTrue);
      expect(
        await manager.seekRelative(const Duration(seconds: -15)),
        const Duration(seconds: 12),
      );
      expect(player.currentIndex, 0);
      expect(player.position, const Duration(seconds: 12));
    },
  );

  test('paused seeking stays paused and clamps to both ends', () async {
    await manager.speak('A paper triangle.', seekable: true);
    await manager.pause();
    player.at(0, const Duration(seconds: 3));
    expect(
      await manager.seekRelative(const Duration(seconds: -15)),
      Duration.zero,
    );
    expect(player.playing, isFalse);
    player.at(0, const Duration(seconds: 18));
    expect(
      await manager.seekRelative(const Duration(seconds: 15)),
      const Duration(seconds: 20),
    );
    expect(player.playing, isFalse);
  });

  test(
    'stopping generation ignores a late audio file and removes it',
    () async {
      final pending = Completer<NativeTtsAudio>();
      device.pending = pending;
      final request = manager.speak('A paper circle.', seekable: true);
      await Future<void>.delayed(Duration.zero);
      await manager.stop();
      final file = await File('${Directory.systemTemp.path}/late-speech.caf')
          .writeAsString('synthetic');
      pending.complete(NativeTtsAudio(file.path, const Duration(seconds: 20)));
      await request;
      expect(await file.exists(), isFalse);
      expect(manager.canSeek, isFalse);
    },
  );

  test(
    'canceling generation cannot send an error into a newer reply',
    () async {
      final events = <TtsEvent>[];
      final subscription = manager.events.listen(events.add);
      final pending = Completer<NativeTtsAudio>();
      device.pending = pending;
      final old = manager.speak('An old paper shape.', seekable: true);
      await Future<void>.delayed(Duration.zero);
      device.pending = null;
      await manager.speak('A new paper shape.', seekable: true);
      pending.completeError(StateError('Canceled synthetic generation'));
      await old;
      expect(manager.canSeek, isTrue);
      expect(events.whereType<TtsError>(), isEmpty);
      await subscription.cancel();
    },
  );

  test('live conversational speech retains the existing device path', () async {
    await manager.speak('A paper kite.');
    expect(device.liveSpeech, 1);
    expect(device.rendered, isEmpty);
    expect(manager.canSeek, isFalse);
  });

  test('seekable chunks respect the device limit without losing text', () {
    final text = List.filled(500, 'A smooth paper square').join(' ');
    final chunks = manager.splitTextForSpeech(text, seekable: true);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((chunk) => chunk.length <= 3500), isTrue);
    expect(chunks.join(' '), text);
  });
}

class _Device extends NativeTtsService {
  final rendered = <String>[];
  int liveSpeech = 0;
  Completer<NativeTtsAudio>? pending;
  @override
  Stream<NativeTtsEvent> get events => const Stream.empty();
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> stop() async => true;
  @override
  Future<bool> cancelSynthesis() async => true;
  @override
  Future<List<Map<String, dynamic>>> getVoices() async => [];
  @override
  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
    bool voiceCall = false,
  }) async {
    liveSpeech++;
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
    if (pending != null) return pending!.future;
    final file = await File(
      '${Directory.systemTemp.path}/speech-${DateTime.now().microsecondsSinceEpoch}-${rendered.length}.caf',
    ).writeAsString('synthetic');
    return NativeTtsAudio(file.path, const Duration(seconds: 20));
  }
}

class _Player extends NullAudioPlayback {
  final states = StreamController<AudioPlaybackState>.broadcast(sync: true);
  final indices = StreamController<int?>.broadcast(sync: true);
  int index = 0;
  Duration location = Duration.zero;
  bool playing = false;
  @override
  Stream<AudioPlaybackState> get stateChanges => states.stream;
  @override
  Stream<int?> get currentIndexChanges => indices.stream;
  @override
  int? get currentIndex => index;
  @override
  Duration get position => location;
  @override
  AudioProcessingState get processingState => AudioProcessingState.ready;
  void at(int value, Duration position) {
    index = value;
    location = position;
    indices.add(value);
  }

  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    at(initialIndex, initialPosition);
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async =>
      at(index ?? this.index, position ?? Duration.zero);
  @override
  Future<void> play() async {
    playing = true;
    states.add(
      const AudioPlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  @override
  Future<void> pause() async {
    playing = false;
    states.add(
      const AudioPlaybackState(
        playing: false,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  @override
  Future<void> stop() => pause();
}
