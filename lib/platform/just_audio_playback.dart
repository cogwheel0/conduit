import 'package:conduit_core/conduit_core.dart';
import 'package:just_audio/just_audio.dart';

/// The mobile app's [AudioPlaybackPort], backed by `just_audio`.
///
/// A thin mapping and nothing more: the gapless-queue behaviour the spoken
/// reply depends on is `just_audio`'s, so this deliberately does not add
/// buffering or retry logic of its own.
class JustAudioPlayback implements AudioPlaybackPort {
  JustAudioPlayback([AudioPlayer? player]) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Stream<AudioPlaybackState> get stateChanges => _player.playerStateStream.map(
    (state) => AudioPlaybackState(
      playing: state.playing,
      processingState: _mapProcessingState(state.processingState),
    ),
  );

  @override
  Stream<int?> get currentIndexChanges => _player.currentIndexStream;

  @override
  int? get currentIndex => _player.currentIndex;

  @override
  AudioProcessingState get processingState =>
      _mapProcessingState(_player.processingState);

  @override
  Future<void> setClips(
    List<AudioClip> clips, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) => _player.setAudioSources(
    clips.map(_toSource).toList(),
    initialIndex: initialIndex,
    initialPosition: initialPosition,
  );

  @override
  Future<void> addClip(AudioClip clip) =>
      _player.addAudioSource(_toSource(clip));

  @override
  Future<void> clearClips() => _player.clearAudioSources();

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration? position, {int? index}) =>
      _player.seek(position, index: index);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> dispose() => _player.dispose();

  AudioSource _toSource(AudioClip clip) =>
      AudioSource.uri(clip.uri, tag: clip.tag);

  static AudioProcessingState _mapProcessingState(ProcessingState state) =>
      switch (state) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      };
}
