import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech.dart';

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
    player.duration = const Duration(seconds: 20);
    player.failDuration = false;
    player.failSeek = false;
    manager.setServerSpeech(null);
    await manager.debugSetNativeTtsService(device);
    await manager.initialize(config: const TtsConfig());
  });

  tearDown(() async {
    await manager.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
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

  test('late device fallback failure cannot clear a newer reply', () async {
    manager.setServerSpeech(_Server());
    player.failDuration = true;
    final pending = Completer<NativeTtsAudio>();
    device.pending = pending;
    final events = <TtsEvent>[];
    final sub = manager.events.listen(events.add);
    addTearDown(sub.cancel);
    final old = manager.speak('Old strip.', useServer: true, seekable: true);
    await _until(() => device.rendered.isNotEmpty);
    device.pending = null;
    await manager.speak('New strip.', useServer: false, seekable: true);
    pending.completeError(StateError('Synthetic canceled fallback'));
    await old;
    expect(manager.canSeek, isTrue);
    expect(events.whereType<TtsError>(), isEmpty);
  });

  test('failed duration probes delete their speech file', () async {
    manager.setServerSpeech(_Server());
    player.failDuration = true;
    await manager.speak('One folded strip.', useServer: true, seekable: true);
    expect(await File(player.lastProbed!.uri.toFilePath()).exists(), isFalse);
    expect(device.rendered, isNotEmpty);
  });

  test('unknown duration still plays cloud audio without seeking', () async {
    manager.setServerSpeech(_Server());
    player.duration = null;
    await manager.speak('One folded strip.', useServer: true, seekable: true);
    expect(player.playing, isTrue);
    expect(device.rendered, isEmpty);
    expect(manager.canSeek, isFalse);
  });

  test(
    'forward seeking waits only for its target and respects a later pause',
    () async {
      final third = Completer<SynthesizedSpeech>();
      final fourth = Completer<SynthesizedSpeech>();
      final server = _Server()
        ..pending['Third strip.'] = third
        ..pending['Fourth strip.'] = fourth;
      manager.setServerSpeech(server);
      await manager.updateConfig(
        const TtsConfig(splitOn: TtsManager.splitOnParagraphs),
      );
      await manager.speak(
        'First strip.\n\nSecond strip.\n\nThird strip.\n\nFourth strip.',
        useServer: true,
        seekable: true,
      );
      player.at(1, const Duration(seconds: 15));
      final seek = manager.seekRelative(const Duration(seconds: 15));
      await pumpEventQueue();
      await manager.resume();
      await manager.pause();
      third.complete(_audio);
      expect(
        await seek.timeout(const Duration(seconds: 2)),
        const Duration(seconds: 50),
      );
      expect(fourth.isCompleted, isFalse);
      expect(player.playing, isFalse);
      fourth.complete(_audio);
      await pumpEventQueue();
    },
  );

  test('terminal seek failure stops audio and clears the session', () async {
    final events = <TtsEvent>[];
    final sub = manager.events.listen(events.add);
    addTearDown(sub.cancel);
    await manager.speak('A folded square.', seekable: true);
    player.failSeek = true;
    expect(await manager.seekRelative(const Duration(seconds: 15)), isNull);
    await pumpEventQueue();
    expect(player.playing, isFalse);
    expect(manager.canSeek, isFalse);
    expect(events.whereType<TtsError>(), hasLength(1));
  });

  test('device queue setup does not report a user pause', () async {
    final events = <TtsEvent>[];
    final sub = manager.events.listen(events.add);
    addTearDown(sub.cancel);
    await manager.speak('A folded triangle.', seekable: true);
    await pumpEventQueue();
    expect(events.whereType<TtsPaused>(), isEmpty);
  });

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
  bool failSeek = false;
  bool failDuration = false;
  Duration? duration = const Duration(seconds: 20);
  AudioClip? lastProbed;
  @override
  Future<Duration?> durationOf(AudioClip clip) async {
    lastProbed = clip;
    if (failDuration) throw StateError('Synthetic invalid audio');
    return duration;
  }

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
    states.add(
      const AudioPlaybackState(
        playing: false,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (failSeek) throw StateError('Synthetic seek failure');
    at(index ?? this.index, position ?? Duration.zero);
  }

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

final _audio = (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'audio/wav');

class _Server extends Fake implements ServerSpeechProvider {
  final pending = <String, Completer<SynthesizedSpeech>>{};
  @override
  ServerSpeechSource get source => ServerSpeechSource.hermes;
  @override
  bool get canSynthesize => true;
  @override
  Future<SynthesizedSpeech> synthesize(
    String text, {
    String? preferredVoice,
    double? speed,
  }) async => await (pending[text]?.future ?? Future.value(_audio));
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Synthetic operation did not start');
}
