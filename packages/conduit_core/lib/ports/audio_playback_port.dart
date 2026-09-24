import 'dart:async';

import 'package:meta/meta.dart';

/// Plays a queue of audio clips.
///
/// Spoken assistant replies arrive as a sequence of chunks that must play
/// back to back without an audible gap, which is why this is a queue with an
/// index rather than a play-one-file call: the next clip is appended while
/// the current one is still playing, and the index stream is how the caller
/// learns which chunk the listener actually reached.
///
/// The mobile app backs this with `just_audio`; the desktop renderer has an
/// `<audio>` element and the daemon has no output at all, so none of that can
/// be reached from the turn pipeline directly.
abstract interface class AudioPlaybackPort {
  /// Playing/paused and buffering transitions.
  Stream<AudioPlaybackState> get stateChanges;

  /// The index of the clip now playing, or null before playback starts.
  ///
  /// Distinct from anything the caller can compute: a clip can finish and
  /// advance the queue on its own, so this is the only account of where
  /// playback actually is.
  Stream<int?> get currentIndexChanges;

  int? get currentIndex;

  AudioProcessingState get processingState;

  /// Replaces the queue and seeks to [initialIndex].
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  });

  /// Appends to the queue without interrupting what is playing.
  Future<void> addClip(AudioClip clip);

  Future<void> clearClips();

  Future<void> play();

  Future<void> pause();

  Future<void> stop();

  /// Seeks within the current clip, or to [index] when given.
  Future<void> seek(Duration? position, {int? index});

  /// 1.0 is normal speed.
  Future<void> setSpeed(double speed);

  Future<void> dispose();

  /// Creates the host's player.
  ///
  /// A factory rather than an instance because `TtsManager` is a singleton
  /// that owns its player for the process lifetime, and because a second
  /// voice session must not inherit the first one's queue.
  ///
  /// Installed once at startup, as with `DebugLogger.sink`. `main.dart` and
  /// `test/flutter_test_config.dart` both install the `just_audio` one.
  static AudioPlaybackPort Function() hostFactory = NullAudioPlayback.new;
}

/// Accepts a queue and never plays it.
///
/// The right behaviour for a host with no audio output -- the daemon -- and
/// the reason the default is this rather than a throw: spoken replies are an
/// enhancement, and a host that cannot speak should fall silent rather than
/// fail the turn.
class NullAudioPlayback implements AudioPlaybackPort {
  NullAudioPlayback();

  final _states = StreamController<AudioPlaybackState>.broadcast();
  final _indices = StreamController<int?>.broadcast();

  @override
  Stream<AudioPlaybackState> get stateChanges => _states.stream;

  @override
  Stream<int?> get currentIndexChanges => _indices.stream;

  @override
  int? get currentIndex => null;

  @override
  AudioProcessingState get processingState => AudioProcessingState.idle;

  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {}

  @override
  Future<void> addClip(AudioClip clip) async {}

  @override
  Future<void> clearClips() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {
    await _states.close();
    await _indices.close();
  }
}

/// One item in the playback queue.
@immutable
class AudioClip {
  const AudioClip({required this.uri, this.tag});

  /// Where the audio lives. The mobile host writes chunks to temporary files
  /// and passes their `file:` URIs.
  final Uri uri;

  /// Carried through untouched so the caller can identify the clip when it
  /// comes back on [AudioPlaybackPort.currentIndexChanges].
  final Object? tag;
}

/// Whether audio is playing, and how ready the pipeline is.
@immutable
class AudioPlaybackState {
  const AudioPlaybackState({
    required this.playing,
    required this.processingState,
  });

  final bool playing;
  final AudioProcessingState processingState;
}

/// Mirrors `just_audio`'s `ProcessingState`.
///
/// Kept as its own enum so the core does not name a plugin type; the mapping
/// is one-to-one and lives in the adapter.
enum AudioProcessingState {
  /// No source loaded.
  idle,

  /// Loading a source.
  loading,

  /// Loaded, waiting for enough data to play.
  buffering,

  /// Ready to play, or playing.
  ready,

  /// The queue has run to the end.
  completed,
}
