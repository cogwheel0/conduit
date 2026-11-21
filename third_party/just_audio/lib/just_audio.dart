import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:meta/meta.dart' show experimental;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

JustAudioPlatform? _pluginPlatformCache;

JustAudioPlatform get _pluginPlatform {
  var pluginPlatform = JustAudioPlatform.instance;
  // If this is a new FlutterEngine or if we've just hot restarted an existing
  // FlutterEngine...
  if (_pluginPlatformCache == null) {
    // Dispose of all existing players within this FlutterEngine. This helps to
    // shut down existing players on a hot restart. TODO: Remove this hack once
    // https://github.com/flutter/flutter/issues/10437 is implemented.
    try {
      pluginPlatform.disposeAllPlayers(DisposeAllPlayersRequest());
    } catch (e) {
      // Silently ignore if a platform doesn't support this method.
    }
    _pluginPlatformCache = pluginPlatform;
  }
  return pluginPlatform;
}

/// An audio player that plays a gapless playlist of [AudioSource]s.
///
/// ```
/// final player = AudioPlayer();
/// await player.setUrl('https://foo.com/bar.mp3');
/// player.play();
/// await player.pause();
/// await player.setClip(start: Duration(seconds: 10), end: Duration(seconds: 20));
/// await player.play();
/// await player.setUrl('https://foo.com/baz.mp3');
/// await player.seek(Duration(minutes: 5));
/// player.play();
/// await player.pause();
/// await player.dispose();
/// ```
///
/// You must call [stop] or [dispose] to release the resources used by this
/// player, including any temporary files created to cache assets.
class AudioPlayer {
  static String _generateId() => _uuid.v4();
  final _lock = Lock(reentrant: true);
  Future<void>? _playbackEventPipe;

  /// The user agent to set on all HTTP requests.
  final String? _userAgent;

  /// Whether to use the proxy server to send request headers.
  final bool _useProxyForRequestHeaders;

  final AudioLoadConfiguration? _audioLoadConfiguration;

  final bool _androidOffloadSchedulingEnabled;

  final AndroidAudioOffloadPreferences? _androidAudioOffloadPreferences;

  /// This is `true` when the audio player needs to engage the native platform
  /// side of the plugin to decode or play audio, and is `false` when the native
  /// resources are not needed (i.e. after initial instantiation and after [stop]).
  bool _active = false;

  /// This is set to [_nativePlatform] when [_active] is `true` and
  /// [_idlePlatform] otherwise.
  late Future<AudioPlayerPlatform> _platform;

  /// Reflects the current platform immediately after it is set.
  AudioPlayerPlatform? _platformValue;

  /// The interface to the native portion of the plugin. This will be disposed
  /// and set to `null` when not in use.
  Future<AudioPlayerPlatform>? _nativePlatform;

  /// A pure Dart implementation of the platform interface for use when the
  /// native platform is not needed.
  _IdleAudioPlayer? _idlePlatform;

  /// The subscription to the event channel of the current platform
  /// implementation. When switching between active and inactive modes, this is
  /// used to cancel the subscription to the previous platform's events and
  /// subscribe to the new platform's events.
  StreamSubscription<PlaybackEventMessage>? _playbackEventSubscription;

  /// The subscription to the data event channel of the current platform
  /// implementation. When switching between active and inactive modes, this is
  /// used to cancel the subscription to the previous platform's events and
  /// subscribe to the new platform's events.
  StreamSubscription<PlayerDataMessage>? _playerDataSubscription;

  StreamSubscription<AndroidAudioAttributes>?
      _androidAudioAttributesSubscription;
  StreamSubscription<void>? _becomingNoisyEventSubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionEventSubscription;
  StreamSubscription<void>? _positionDiscontinuitySubscription;
  StreamSubscription<void>? _currentIndexSubscription;
  StreamSubscription<void>? _errorsSubscription;
  StreamSubscription<void>? _errorsResetSubscription;

  String? _id;
  final _proxy = _ProxyHttpServer();
  // ignore: deprecated_member_use_from_same_package
  final ConcatenatingAudioSource _playlist;
  final Map<String, AudioSource> _audioSources = {};
  bool _disposed = false;
  _PluginLoadRequest? _pluginLoadRequest;
  final AudioPipeline _audioPipeline;

  Future<Duration?>? _loadFuture;
  final _shuffleIndicesInv = <int>[];

  final _playerEventSubject =
      BehaviorSubject<PlayerEvent>.seeded(PlayerEvent(), sync: true);

  final _playbackEventSubject =
      BehaviorSubject<PlaybackEvent>.seeded(PlaybackEvent(), sync: true);

  // derived from playbackEventStream
  final _processingStateSubject =
      BehaviorSubject<ProcessingState>.seeded(ProcessingState.idle);
  final _durationSubject = BehaviorSubject<Duration?>.seeded(null);
  final _bufferedPositionSubject =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final _icyMetadataSubject = BehaviorSubject<IcyMetadata?>.seeded(null);
  final _androidAudioSessionIdSubject = BehaviorSubject<int?>.seeded(null);
  final _errorSubject = PublishSubject<PlayerException>();

  // independent streams
  final _playingSubject = BehaviorSubject.seeded(false);
  final _volumeSubject = BehaviorSubject.seeded(1.0);
  final _speedSubject = BehaviorSubject.seeded(1.0);
  final _pitchSubject = BehaviorSubject.seeded(1.0);
  final _skipSilenceEnabledSubject = BehaviorSubject.seeded(false);

  final _positionDiscontinuitySubject =
      PublishSubject<PositionDiscontinuity>(sync: true);

  final _sequenceStateSubject = BehaviorSubject<SequenceState>.seeded(
      SequenceState(
        sequence: [],
        currentIndex: null,
        shuffleIndices: [],
        shuffleModeEnabled: false,
        loopMode: LoopMode.off,
      ),
      sync: true);

  // derived from sequenceStateStream
  final _sequenceSubject = BehaviorSubject.seeded(<IndexedAudioSource>[]);
  final _shuffleIndicesSubject = BehaviorSubject.seeded(<int>[]);
  final _currentIndexSubject = BehaviorSubject<int?>.seeded(null);
  final _loopModeSubject = BehaviorSubject.seeded(LoopMode.off);
  final _shuffleModeEnabledSubject = BehaviorSubject.seeded(false);

  final _playerStateSubject = BehaviorSubject<PlayerState>.seeded(
      PlayerState(false, ProcessingState.idle));

  var _seeking = false;
  // ignore: close_sinks
  BehaviorSubject<Duration>? _positionSubject;
  bool _automaticallyWaitsToMinimizeStalling = true;
  bool _canUseNetworkResourcesForLiveStreamingWhilePaused = false;
  double _preferredPeakBitRate = 0;
  bool _allowsExternalPlayback = false;
  bool _playInterrupted = false;
  bool _platformLoading = false;
  AndroidAudioAttributes? _androidAudioAttributes;
  WebCrossOrigin? _webCrossOrigin;
  String _webSinkId = '';
  final bool _androidApplyAudioAttributes;
  final bool _handleAudioSessionActivation;

  /// Counts how many times [_setPlatformActive] is called.
  int _activationCount = 0;

  /// Creates an [AudioPlayer].
  ///
  /// Apps requesting remote URLs should set the [userAgent] parameter which
  /// will be set as the `user-agent` header on all requests (except on web
  /// where the browser's user agent will be used) to identify the client. If
  /// unspecified, a platform-specific default will be supplied.
  ///
  /// Request headers including `user-agent` are sent by default via a local
  /// HTTP proxy which requires non-HTTPS support to be enabled (see the README
  /// page for setup instructions). Alternatively, you can set
  /// [useProxyForRequestHeaders] to `false` to allow supported platforms to
  /// send the request headers directly without use of the proxy. On iOS/macOS,
  /// this will use the `AVURLAssetHTTPUserAgentKey` on iOS 16 and above, and
  /// macOS 13 and above, if `user-agent` is the only header used. Otherwise,
  /// the `AVURLAssetHTTPHeaderFieldsKey` key will be used. On Android, this
  /// will use ExoPlayer's `setUserAgent` and `setDefaultRequestProperties`.
  /// For Linux/Windows federated platform implementations, refer to the
  /// documentation for that implementation's support.
  ///
  /// The player will automatically pause/duck and resume/unduck when audio
  /// interruptions occur (e.g. a phone call) or when headphones are unplugged.
  /// If you wish to handle audio interruptions manually, set
  /// [handleInterruptions] to `false` and interface directly with the audio
  /// session via the [audio_session](https://pub.dev/packages/audio_session)
  /// package. If you do not wish just_audio to automatically activate the audio
  /// session when playing audio, set [handleAudioSessionActivation] to `false`.
  /// If you do not want just_audio to respect the global
  /// [AndroidAudioAttributes] configured by audio_session, set
  /// [androidApplyAudioAttributes] to `false`.
  ///
  /// The default audio loading and buffering behaviour can be configured via
  /// the [audioLoadConfiguration] parameter.
  ///
  /// [useLazyPreparation] specifies whether audio sources will be loaded lazily
  /// in preparation to be played. Set this to `false` to make all audio
  /// sources load eagerly in advance.
  ///
  /// [shuffleOrder] determines the playback order (defaulting to
  /// [DefaultShuffleOrder]) when [shuffleModeEnabled] is `true`,
  ///
  /// When [maxSkipsOnError] is set, the player will automatically skip to the
  /// next audio source on load errors, and will give up after [maxSkipsOnError]
  /// attempts. This is supported on Android, iOS and web. For other platforms,
  /// check the documentation of the respective platform implementation.
  ///
  /// [androidAudioOffloadPreferences] specifies whether audio offload is enabled
  /// on Android.
  AudioPlayer({
    String? userAgent,
    bool handleInterruptions = true,
    bool androidApplyAudioAttributes = true,
    bool handleAudioSessionActivation = true,
    AudioLoadConfiguration? audioLoadConfiguration,
    AudioPipeline? audioPipeline,
    AndroidAudioOffloadPreferences? androidAudioOffloadPreferences,
    @Deprecated('Use androidAudioOffloadPreferences instead')
    bool androidOffloadSchedulingEnabled = false,
    bool useProxyForRequestHeaders = true,
    bool useLazyPreparation = true,
    ShuffleOrder? shuffleOrder,
    int maxSkipsOnError = 0,
  })  : _id = _generateId(),
        _userAgent = userAgent,
        _androidApplyAudioAttributes =
            androidApplyAudioAttributes && _isAndroid(),
        _handleAudioSessionActivation = handleAudioSessionActivation,
        _audioLoadConfiguration = audioLoadConfiguration,
        _audioPipeline = audioPipeline ?? AudioPipeline(),
        _androidOffloadSchedulingEnabled = androidOffloadSchedulingEnabled,
        _androidAudioOffloadPreferences = androidAudioOffloadPreferences,
        _useProxyForRequestHeaders = useProxyForRequestHeaders,
        // ignore: deprecated_member_use_from_same_package
        _playlist = ConcatenatingAudioSource._playlist(
          children: [],
          useLazyPreparation: useLazyPreparation,
          shuffleOrder: shuffleOrder,
        ) {
    _audioPipeline._setup(this);
    _playlist._onAttach(this);
    if (_audioLoadConfiguration?.darwinLoadControl != null) {
      _automaticallyWaitsToMinimizeStalling = _audioLoadConfiguration!
          .darwinLoadControl!.automaticallyWaitsToMinimizeStalling;
    }
    _playbackEventPipe = _playbackEventSubject.addStream(
        playerEventStream.map((event) => event.playbackEvent).distinct());
    _playingSubject
        .addStream(playerEventStream.map((event) => event.playing).distinct());
    _durationSubject.addStream(
        playbackEventStream.map((event) => event.duration).distinct());
    _processingStateSubject.addStream(
        playbackEventStream.map((event) => event.processingState).distinct());
    _bufferedPositionSubject.addStream(
        playbackEventStream.map((event) => event.bufferedPosition).distinct());
    _icyMetadataSubject.addStream(
        playbackEventStream.map((event) => event.icyMetadata).distinct());
    _positionDiscontinuitySubscription = playbackEventStream
        .map((event) => (
              event,
              (sequence.isNotEmpty &&
                      event.currentIndex != null &&
                      event.currentIndex! < sequence.length)
                  ? sequence[event.currentIndex!]
                  : null
            ))
        .pairwise()
        .listen((rec) {
      if (_seeking) return;
      final [(prevEvent, prevSource), (currEvent, currSource)] = rec.toList();
      if (prevSource == null || currSource == null) return;
      if (currSource._id != prevSource._id) {
        // If we've changed item without seeking, it must be an autoAdvance.
        _positionDiscontinuitySubject.add(PositionDiscontinuity(
            PositionDiscontinuityReason.autoAdvance, prevEvent, currEvent));
      } else {
        // If the item is the same, try to determine whether we have looped
        // back.
        if (loopMode == LoopMode.off) return;
        final prevPos = _getPositionFor(prevEvent);
        final currPos = _getPositionFor(currEvent);
        // if (loopMode != LoopMode.one) return;
        if (currPos >= prevPos) return;
        if (currPos >= const Duration(milliseconds: 300)) return;
        final duration = this.duration;
        if (duration != null && prevPos < duration * 0.6) return;
        if (duration == null &&
            currPos - prevPos < const Duration(seconds: 1)) {
          return;
        }
        _positionDiscontinuitySubject.add(PositionDiscontinuity(
            PositionDiscontinuityReason.autoAdvance, prevEvent, currEvent));
      }
    });
    _currentIndexSubscription = playbackEventStream.listen(
      (event) => _sequenceStateSubject
          .add(sequenceState.copyWith(currentIndex: event.currentIndex)),
    );
    _currentIndexSubject.addStream(
        sequenceStateStream.map((sequenceState) => sequenceState.currentIndex));
    _sequenceSubject.addStream(
        sequenceStateStream.map((sequenceState) => sequenceState.sequence));
    _shuffleIndicesSubject.addStream(sequenceStateStream
        .map((sequenceState) => sequenceState.shuffleIndices));
    _shuffleModeEnabledSubject.addStream(sequenceStateStream
        .map((sequenceState) => sequenceState.shuffleModeEnabled));
    _loopModeSubject.addStream(
        sequenceStateStream.map((sequenceState) => sequenceState.loopMode));

    _androidAudioSessionIdSubject.addStream(playbackEventStream
        .map((event) => event.androidAudioSessionId)
        .distinct());

    _errorSubject.addStream(playbackEventStream
        .map((event) => (
              code: event.errorCode,
              message: event.errorMessage,
              index: event.currentIndex,
            ))
        .distinct()
        .where((error) => error.code != null)
        .map((error) =>
            PlayerException(error.code!, error.message, error.index)));
    _playerStateSubject.addStream(playerEventStream
        .map((event) =>
            PlayerState(event.playing, event.playbackEvent.processingState))
        .distinct());
    _setPlatformActive(false, force: true)
        ?.catchError((dynamic e) async => null);
    // Respond to changes to AndroidAudioAttributes configuration.
    if (androidApplyAudioAttributes && _isAndroid()) {
      AudioSession.instance.then((audioSession) {
        _androidAudioAttributesSubscription = audioSession.configurationStream
            .map((conf) => conf.androidAudioAttributes)
            .where((attributes) => attributes != null)
            .cast<AndroidAudioAttributes>()
            .distinct()
            .listen(setAndroidAudioAttributes);
      });
    }
    if (handleInterruptions) {
      AudioSession.instance.then((session) {
        _becomingNoisyEventSubscription =
            session.becomingNoisyEventStream.listen((_) {
          pause();
        });
        _interruptionEventSubscription =
            session.interruptionEventStream.listen((event) {
          if (event.begin) {
            switch (event.type) {
              case AudioInterruptionType.duck:
                assert(_isAndroid());
                if (session.androidAudioAttributes!.usage ==
                    AndroidAudioUsage.game) {
                  setVolume(volume / 2);
                }
                _playInterrupted = false;
                break;
              case AudioInterruptionType.pause:
              case AudioInterruptionType.unknown:
                if (playing) {
                  pause();
                  // Although pause is async and sets _playInterrupted = false,
                  // this is done in the sync portion.
                  _playInterrupted = true;
                }
                break;
            }
          } else {
            switch (event.type) {
              case AudioInterruptionType.duck:
                assert(_isAndroid());
                setVolume(min(1.0, volume * 2));
                _playInterrupted = false;
                break;
              case AudioInterruptionType.pause:
                if (_playInterrupted) play();
                _playInterrupted = false;
                break;
              case AudioInterruptionType.unknown:
                _playInterrupted = false;
                break;
            }
          }
        });
      });
    }
    if (maxSkipsOnError > 0) {
      var consecutiveErrorCount = 0;
      _errorsSubscription = errorStream.listen((error) async {
        if (audioSources.length > 1 &&
            consecutiveErrorCount < maxSkipsOnError &&
            hasNext) {
          consecutiveErrorCount++;
          scheduleMicrotask(() => seekToNext().catchError((e, st) {}));
        } else {
          scheduleMicrotask(() => pause().catchError((e, st) {}));
        }
      });
      _errorsResetSubscription = processingStateStream.listen((state) {
        if (state == ProcessingState.ready && consecutiveErrorCount > 0) {
          consecutiveErrorCount = 0;
        }
      });
    }
    _removeOldAssetCacheDir();
  }

  /// Old versions of just_audio used an asset caching system that created a
  /// separate cache file per asset per player instance, and was highly
  /// dependent on the app calling [dispose] to clean up afterwards. If the app
  /// is upgrading from an old version of just_audio, this will delete the old
  /// cache directory.
  Future<void> _removeOldAssetCacheDir() async {
    if (kIsWeb) return;
    try {
      final oldAssetCacheDir = Directory(p.join(
          (await getTemporaryDirectory()).path, 'just_audio_asset_cache'));
      if (oldAssetCacheDir.existsSync()) {
        try {
          oldAssetCacheDir.deleteSync(recursive: true);
        } catch (e) {
          // ignore: avoid_print
          print("Failed to delete old asset cache dir: $e");
        }
      }
    } catch (e) {
      // There is no temporary directory for this platform.
    }
  }

  /// The first [AudioSource] in the playlist, if any.
  AudioSource? get audioSource => _playlist.children.firstOrNull;

  /// The latest [PlayerEvent].
  PlayerEvent get playerEvent => _playerEventSubject.nvalue!;

  /// A stream of [PlayerEvent]s.
  Stream<PlayerEvent> get playerEventStream => _playerEventSubject.stream;

  /// The latest [PlaybackEvent].
  PlaybackEvent get playbackEvent => _playerEventSubject.nvalue!.playbackEvent;

  /// A stream of [PlaybackEvent]s.
  Stream<PlaybackEvent> get playbackEventStream => _playbackEventSubject.stream;

  /// The duration of the current audio or `null` if unknown.
  Duration? get duration => playbackEvent.duration;

  /// The duration of the current audio.
  Stream<Duration?> get durationStream => _durationSubject.stream.distinct();

  /// The current [ProcessingState].
  ProcessingState get processingState => playbackEvent.processingState;

  /// A stream of [ProcessingState]s.
  Stream<ProcessingState> get processingStateStream =>
      _processingStateSubject.stream.distinct();

  /// Whether the player is playing.
  bool get playing => _playerEventSubject.nvalue!.playing;

  /// A stream of changing [playing] states.
  Stream<bool> get playingStream => _playingSubject.stream.distinct();

  /// The current volume of the player.
  double get volume => _volumeSubject.nvalue!;

  /// A stream of [volume] changes.
  Stream<double> get volumeStream => _volumeSubject.stream;

  /// The current speed of the player.
  double get speed => _speedSubject.nvalue!;

  /// A stream of current speed values.
  Stream<double> get speedStream => _speedSubject.stream;

  /// The current pitch factor of the player.
  double get pitch => _pitchSubject.nvalue!;

  /// A stream of current pitch factor values.
  Stream<double> get pitchStream => _pitchSubject.stream;

  /// The current skipSilenceEnabled factor of the player.
  bool get skipSilenceEnabled => _skipSilenceEnabledSubject.nvalue!;

  /// A stream of current skipSilenceEnabled factor values.
  Stream<bool> get skipSilenceEnabledStream =>
      _skipSilenceEnabledSubject.stream;

  /// The position up to which buffered audio is available.
  Duration get bufferedPosition =>
      _bufferedPositionSubject.nvalue ?? Duration.zero;

  /// A stream of buffered positions.
  Stream<Duration> get bufferedPositionStream =>
      _bufferedPositionSubject.stream.distinct();

  /// The latest ICY metadata received through the audio source, or `null` if no
  /// metadata is available.
  IcyMetadata? get icyMetadata => playbackEvent.icyMetadata;

  /// A stream of ICY metadata received through the audio source.
  Stream<IcyMetadata?> get icyMetadataStream =>
      _icyMetadataSubject.stream.distinct();

  /// The current player state containing only the processing and playing
  /// states.
  PlayerState get playerState =>
      _playerStateSubject.nvalue ?? PlayerState(false, ProcessingState.idle);

  /// A stream of [PlayerState]s.
  Stream<PlayerState> get playerStateStream => _playerStateSubject.stream;

  /// The current sequence of indexed audio sources.
  List<IndexedAudioSource> get sequence => _sequenceSubject.nvalue!;

  /// A stream broadcasting the current sequence of indexed audio sources.
  Stream<List<IndexedAudioSource>> get sequenceStream =>
      _sequenceSubject.stream;

  /// The current shuffled sequence of indexed audio sources.
  List<int> get shuffleIndices => _shuffleIndicesSubject.nvalue!;

  /// A stream broadcasting the current shuffled sequence of indexed audio
  /// sources.
  Stream<List<int>> get shuffleIndicesStream => _shuffleIndicesSubject.stream;

  /// The index of the current [IndexedAudioSource] in [sequence], or `null` if
  /// [sequence] is empty.
  int? get currentIndex => _currentIndexSubject.nvalue;

  /// A stream broadcasting the current index.
  Stream<int?> get currentIndexStream => _currentIndexSubject.stream;

  /// The current [SequenceState].
  SequenceState get sequenceState => _sequenceStateSubject.nvalue!;

  /// A stream broadcasting the current [SequenceState].
  Stream<SequenceState> get sequenceStateStream => _sequenceStateSubject.stream;

  /// Whether there is another item after the current index.
  bool get hasNext => nextIndex != null;

  /// Whether there is another item before the current index.
  bool get hasPrevious => previousIndex != null;

  /// Returns [shuffleIndices] if [shuffleModeEnabled] is `true`, otherwise
  /// returns the unshuffled indices.
  List<int> get effectiveIndices {
    return shuffleModeEnabled
        ? shuffleIndices
        : List.generate(sequence.length, (i) => i);
  }

  List<int> get _effectiveIndicesInv {
    return shuffleModeEnabled
        ? _shuffleIndicesInv
        : List.generate(sequence.length, (i) => i);
  }

  /// The index of the next item to be played, or `null` if there is no next
  /// item.
  int? get nextIndex => _getRelativeIndex(1);

  /// The index of the previous item in play order, or `null` if there is no
  /// previous item.
  int? get previousIndex => _getRelativeIndex(-1);

  int? _getRelativeIndex(int offset) {
    if (_playlist.children.isEmpty || currentIndex == null) return null;
    if (loopMode == LoopMode.one) return currentIndex;
    final effectiveIndices = this.effectiveIndices;
    if (effectiveIndices.isEmpty) return null;
    final effectiveIndicesInv = _effectiveIndicesInv;
    if (currentIndex! >= effectiveIndicesInv.length) return null;
    final invPos = effectiveIndicesInv[currentIndex!];
    var newInvPos = invPos + offset;
    if (newInvPos >= effectiveIndices.length || newInvPos < 0) {
      if (loopMode == LoopMode.all) {
        newInvPos %= effectiveIndices.length;
      } else {
        return null;
      }
    }
    final result = effectiveIndices[newInvPos];
    return result;
  }

  /// The current loop mode.
  LoopMode get loopMode => _loopModeSubject.nvalue!;

  /// A stream of [LoopMode]s.
  Stream<LoopMode> get loopModeStream => _loopModeSubject.stream;

  /// Whether shuffle mode is currently enabled.
  bool get shuffleModeEnabled => _shuffleModeEnabledSubject.nvalue!;

  /// A stream of the shuffle mode status.
  Stream<bool> get shuffleModeEnabledStream =>
      _shuffleModeEnabledSubject.stream;

  /// The current Android AudioSession ID or `null` if not set.
  int? get androidAudioSessionId => playbackEvent.androidAudioSessionId;

  /// Broadcasts the current Android AudioSession ID or `null` if not set.
  Stream<int?> get androidAudioSessionIdStream =>
      _androidAudioSessionIdSubject.stream;

  /// A stream of errors broadcast by the player.
  Stream<PlayerException> get errorStream => _errorSubject.stream;

  /// A stream broadcasting every position discontinuity.
  Stream<PositionDiscontinuity> get positionDiscontinuityStream =>
      _positionDiscontinuitySubject.stream;

  /// Whether the player should automatically delay playback in order to
  /// minimize stalling. (iOS 10.0 or later only)
  bool get automaticallyWaitsToMinimizeStalling =>
      _automaticallyWaitsToMinimizeStalling;

  /// Whether the player can use the network for live streaming while paused on
  /// iOS/macOS.
  bool get canUseNetworkResourcesForLiveStreamingWhilePaused =>
      _canUseNetworkResourcesForLiveStreamingWhilePaused;

  /// The preferred peak bit rate (in bits per second) of bandwidth usage on iOS/macOS.
  double get preferredPeakBitRate => _preferredPeakBitRate;

  /// Whether the player allows external playback on iOS/macOS, defaults to
  /// false.
  bool get allowsExternalPlayback => _allowsExternalPlayback;

  /// The `crossorigin` attribute set the `<audio>` element backing this player
  /// instance on web.
  WebCrossOrigin? get webCrossOrigin => _webCrossOrigin;

  /// The current sink ID of the `<audio>` element backing this instance on web.
  String get webSinkId => _webSinkId;

  /// The current position of the player.
  Duration get position => _getPositionFor(playbackEvent);

  Duration _getPositionFor(PlaybackEvent playbackEvent) {
    if (playing && processingState == ProcessingState.ready) {
      final result = playbackEvent.updatePosition +
          (DateTime.now().difference(playbackEvent.updateTime)) * speed;
      return playbackEvent.duration == null || result <= playbackEvent.duration!
          ? result
          : playbackEvent.duration!;
    } else {
      return playbackEvent.updatePosition;
    }
  }

  /// A stream tracking the current position of this player, suitable for
  /// animating a seek bar. To ensure a smooth animation, this stream emits
  /// values more frequently on short items where the seek bar moves more
  /// quickly, and less frequenly on long items where the seek bar moves more
  /// slowly. The interval between each update will be no quicker than once
  /// every 16ms and no slower than once every 200ms.
  ///
  /// See [createPositionStream] for more control over the stream parameters.
  Stream<Duration> get positionStream {
    if (_positionSubject == null) {
      _positionSubject =
          BehaviorSubject<Duration>(onCancel: () => _positionSubject = null);
      if (!_disposed) {
        _positionSubject!.addStream(createPositionStream(
            steps: 800,
            minPeriod: const Duration(milliseconds: 16),
            maxPeriod: const Duration(milliseconds: 200)));
      }
    }
    return _positionSubject!.stream;
  }

  /// Creates a new stream periodically tracking the current position of this
  /// player. The stream will aim to emit [steps] position updates from the
  /// beginning to the end of the current audio source, at intervals of
  /// [duration] / [steps]. This interval will be clipped between [minPeriod]
  /// and [maxPeriod]. This stream will not emit values while audio playback is
  /// paused or stalled.
  ///
  /// Note: each time this method is called, a new stream is created. If you
  /// intend to use this stream multiple times, you should hold a reference to
  /// the returned stream and close it once you are done.
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) {
    assert(minPeriod <= maxPeriod);
    assert(minPeriod > Duration.zero);
    final controller = StreamController<Duration>.broadcast();
    if (_disposed) return controller.stream;

    Duration duration() => this.duration ?? Duration.zero;
    Duration step() {
      var s = duration() ~/ steps;
      if (s < minPeriod) s = minPeriod;
      if (s > maxPeriod) s = maxPeriod;
      return s;
    }

    Timer? currentTimer;
    StreamSubscription<PlayerEvent>? playerEventSubscription;
    void yieldPosition(Timer timer) {
      if (controller.isClosed || _durationSubject.isClosed) {
        timer.cancel();
        playerEventSubscription?.cancel();
        if (!controller.isClosed) {
          // This will in turn close _positionSubject.
          controller.close();
        }
        return;
      }
      if (playing) {
        controller.add(position);
      }
    }

    playerEventSubscription = playerEventStream.listen((event) {
      controller.add(position);
      currentTimer?.cancel();
      if (playing) {
        currentTimer = Timer.periodic(step(), yieldPosition);
      }
    });
    return controller.stream.distinct();
  }

  /// Convenience method to set the audio source to a URL with optional headers,
  /// preloaded by default, with an initial position of zero by default.
  /// If headers are set, just_audio will create a cleartext local HTTP proxy on
  /// your device to forward HTTP requests with headers included.
  ///
  /// This is equivalent to:
  ///
  /// ```
  /// setAudioSource(AudioSource.uri(Uri.parse(url), headers: headers, tag: tag),
  ///     initialPosition: Duration.zero, preload: true);
  /// ```
  ///
  /// See [setAudioSources] for a detailed explanation of the options.
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) =>
      setAudioSource(
          AudioSource.uri(Uri.parse(url), headers: headers, tag: tag),
          initialPosition: initialPosition,
          preload: preload);

  /// Convenience method to set the audio source to a file, preloaded by
  /// default, with an initial position of zero by default.
  ///
  /// This is equivalent to:
  ///
  /// ```
  /// setAudioSource(AudioSource.uri(Uri.file(filePath), tag: tag),
  ///     initialPosition: Duration.zero, preload: true);
  /// ```
  ///
  /// See [setAudioSources] for a detailed explanation of the options.
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) =>
      setAudioSource(AudioSource.file(filePath, tag: tag),
          initialPosition: initialPosition, preload: preload);

  /// Convenience method to set the audio source to an asset, preloaded by
  /// default, with an initial position of zero by default.
  ///
  /// For assets within the same package, this is equivalent to:
  ///
  /// ```
  /// setAudioSource(AudioSource.uri(Uri.parse('asset:///$assetPath'), tag: tag),
  ///     initialPosition: Duration.zero, preload: true);
  /// ```
  ///
  /// If the asset is to be loaded from a different package, the [package]
  /// parameter must be given to specify the package name.
  ///
  /// See [setAudioSources] for a detailed explanation of the options.
  Future<Duration?> setAsset(
    String assetPath, {
    String? package,
    bool preload = true,
    Duration? initialPosition,
    dynamic tag,
  }) =>
      setAudioSource(
        AudioSource.asset(assetPath, package: package, tag: tag),
        initialPosition: initialPosition,
        preload: preload,
      );

  /// Clears the playlist and adds the given [audioSource].
  ///
  /// This is equivalent to:
  ///
  /// ```
  /// setAudioSources([source], initialIndex: 0, initialPosition: Duration.zero,
  ///     preload: true);
  /// ```
  ///
  /// See [setAudioSources] for a detailed explanation of the options.
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) =>
      setAudioSources(
        [audioSource],
        preload: preload,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
      );

  /// Clears the playlist and adds the given [audioSources].
  ///
  /// By default, this method will immediately start loading the initial
  /// [AudioSource] and return its duration as soon as it is known, or `null` if
  /// that information is unavailable. Set [preload] to `false` if you would
  /// prefer to delay loading until some later point, either via an explicit
  /// call to [load] or via a call to [play] which implicitly loads the audio.
  /// If [preload] is `false`, a `null` duration will be returned. Note that the
  /// [preload] option will automatically be assumed as `true` if `playing` is
  /// currently `true`.
  ///
  /// Optionally specify [initialPosition] and [initialIndex] to seek to an
  /// initial position within a particular item (defaulting to position zero of
  /// the first item).
  ///
  /// When [preload] is `true`, this method may throw:
  ///
  /// * [PlayerException] if the initial audio source was unable to be loaded.
  /// * [PlayerInterruptedException] if another invocation of this method
  /// interrupted this invocation.
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    _pluginLoadRequest?.interrupted = true;
    if (_disposed) return null;
    final loadRequest = _pluginLoadRequest = _PluginLoadRequest(
      audioSources: audioSources,
      preload: preload,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
      shuffleOrder: shuffleOrder ?? DefaultShuffleOrder(),
    );
    await _playlist._init(audioSources, loadRequest.shuffleOrder);
    loadRequest.checkInterruption();
    Duration? duration;
    if (preload || playing) {
      duration = await load();
    } else {
      await _setPlatformActive(false)?.catchError((dynamic e) async => null);
    }
    loadRequest.checkInterruption();
    return duration;
  }

  /// Starts loading the playlist and returns the audio duration of the initial
  /// [AudioSource] in the playlist as soon as it is known, or `null` if
  /// unavailable. This method does nothing if the playlist is empty.
  ///
  /// This method throws:
  ///
  /// * [PlayerException] if the audio source was unable to be loaded.
  /// * [PlayerInterruptedException] if another invocation of [setAudioSources]
  /// interrupted this invocation.
  Future<Duration?> load() async {
    if (_disposed) return null;
    final pluginLoadRequest = _pluginLoadRequest;
    if (_playlist.children.isEmpty) return null;
    if (_active) {
      return await _load(
        await _platform,
        _playlist,
        initialSeekValues: pluginLoadRequest?.initialSeekValues,
      );
    } else {
      // This will implicitly load the current audio source.
      return await _setPlatformActive(true);
    }
  }

  /// Adds [audioSource] to the end of the playlist.
  Future<void> addAudioSource(AudioSource audioSource) =>
      _playlist.add(audioSource);

  /// Inserts [audioSource] into the playlist at [index].
  Future<void> insertAudioSource(int index, AudioSource audioSource) =>
      _playlist.insert(index, audioSource);

  /// Adds [audioSources] to the end of the playlist.
  Future<void> addAudioSources(List<AudioSource> audioSources) =>
      _playlist.addAll(audioSources);

  /// Inserts [audioSources] into the playlist at [index].
  Future<void> insertAudioSources(int index, List<AudioSource> audioSources) =>
      _playlist.insertAll(index, audioSources);

  /// Removes the [AudioSource] at [index] from the playlist.
  Future<void> removeAudioSourceAt(int index) => _playlist.removeAt(index);

  /// Removes the [AudioSource]s from index [start] to [end] from the playlist.
  Future<void> removeAudioSourceRange(int start, int end) =>
      _playlist.removeRange(start, end);

  /// Moves the [AudioSource] in the playlist at [currentIndex] to [newIndex].
  Future<void> moveAudioSource(int currentIndex, int newIndex) =>
      _playlist.move(currentIndex, newIndex);

  /// Clears the playlist.
  Future<void> clearAudioSources() => _playlist.clear();

  /// The playlist.
  List<AudioSource> get audioSources => _playlist.children;

  Future<void> _broadcastSequence({bool sequenceChanged = true}) async {
    _sequenceStateSubject.add(sequenceState.copyWith(
      sequence: sequenceChanged ? _playlist.sequence : sequenceState.sequence,
      shuffleIndices: _playlist.shuffleIndices,
    ));
    final shuffleIndicesLength = shuffleIndices.length;
    if (_shuffleIndicesInv.length > shuffleIndicesLength) {
      _shuffleIndicesInv.removeRange(
          shuffleIndicesLength, _shuffleIndicesInv.length);
    } else if (_shuffleIndicesInv.length < shuffleIndicesLength) {
      _shuffleIndicesInv.addAll(
          List.filled(shuffleIndicesLength - _shuffleIndicesInv.length, 0));
    }
    for (var i = 0; i < shuffleIndicesLength; i++) {
      _shuffleIndicesInv[shuffleIndices[i]] = i;
    }
    // Allow this event to propagate to derived streams.
    await currentIndexStream.firstWhere((i) => i == sequenceState.currentIndex);
  }

  void _registerAudioSource(AudioSource source) {
    _audioSources[source._id] = source;
  }

  Future<Duration?> _load(
    AudioPlayerPlatform platform,
    // ignore: deprecated_member_use_from_same_package
    ConcatenatingAudioSource source, {
    _InitialSeekValues? initialSeekValues,
  }) async {
    final pluginLoadRequest = _pluginLoadRequest;
    final activationNumber = _activationCount;
    void checkInterruption() {
      if (_activationCount != activationNumber ||
          pluginLoadRequest != _pluginLoadRequest) {
        // the platform has changed since we started loading, so abort.
        throw PlayerInterruptedException('Loading interrupted');
      }
      pluginLoadRequest?.checkInterruption();
    }

    try {
      if (_active) {
        await source._onLoad();
        checkInterruption();
      }
      source._shuffle(initialIndex: initialSeekValues?.index ?? 0);
      await _broadcastSequence();
      checkInterruption();
      _loadFuture = platform
          .load(LoadRequest(
            audioSourceMessage: source._toMessage(),
            initialPosition: initialSeekValues?.position,
            initialIndex: initialSeekValues?.index,
          ))
          .then((response) => response.duration);
      final duration = await _loadFuture;
      checkInterruption();
      if (platform != _platformValue) {
        // the platform has changed since we started loading, so abort.
        throw PlayerInterruptedException('Loading interrupted');
      }
      // Wait for loading state to pass.
      await processingStateStream
          .firstWhere((state) => state != ProcessingState.loading);
      checkInterruption();
      _pluginLoadRequest = null;
      return duration;
    } on PlatformException catch (e, st) {
      Error.throwWithStackTrace(_convertException(e), st);
    }
  }

  /// Clips the current [AudioSource] to the given [start] and [end]
  /// timestamps. If [start] is null, it will be reset to the start of the
  /// original [AudioSource]. If [end] is null, it will be reset to the end of
  /// the original [AudioSource]. This method cannot be called from the
  /// [ProcessingState.idle] state.
  Future<Duration?> setClip(
      {Duration? start, Duration? end, dynamic tag}) async {
    if (_disposed) return null;
    final audioSource = _playlist.children.firstOrNull;
    if (_playlist.children.length != 1 || audioSource is! UriAudioSource) {
      throw Exception('Playlist must contain 1 UriAudioSource');
    }
    _setPlatformActive(true)?.catchError((dynamic e) async => null);
    final duration = await _load(
        await _platform,
        start == null && end == null
            ? _playlist
            // ignore: deprecated_member_use_from_same_package
            : ConcatenatingAudioSource._playlist(children: [
                ClippingAudioSource(
                  child: audioSource,
                  start: start,
                  end: end,
                  tag: tag,
                )
              ]));
    return duration;
  }

  /// Tells the player to play audio at the current [speed] and [volume] as soon
  /// as an audio source is loaded and ready to play. If an audio source has
  /// been set but not preloaded, this method will also initiate the loading.
  /// The [Future] returned by this method completes when the playback completes
  /// or is paused or stopped. If the player is already playing, this method
  /// completes immediately.
  ///
  /// This method causes [playing] to become true, and it will remain true
  /// until [pause] or [stop] is called. This means that if playback completes,
  /// and then you [seek] to an earlier position in the audio, playback will
  /// continue playing from that position. If you instead wish to [pause] or
  /// [stop] playback on completion, you can call either method as soon as
  /// [processingState] becomes [ProcessingState.completed] by listening to
  /// [processingStateStream].
  ///
  /// This method activates the audio session before playback, and will do
  /// nothing if activation of the audio session fails for any reason.
  Future<void> play() async {
    if (_disposed) return;
    if (playing) return;
    _playInterrupted = false;
    // Broadcast to clients immediately, but revert to false if we fail to
    // activate the audio session. This allows setAudioSource to be aware of a
    // prior play request.
    _playerEventSubject.add(PlayerEvent(
      playing: true,
      playbackEvent: playbackEvent.copyWith(
        updatePosition: position,
        updateTime: DateTime.now(),
      ),
    ));
    final playCompleter = Completer<dynamic>();
    final audioSession = await AudioSession.instance;
    if (!_handleAudioSessionActivation || await audioSession.setActive(true)) {
      if (!playing) return;
      // TODO: rewrite this to more cleanly handle simultaneous load/play
      // requests which each may result in platform play requests.
      final requireActive = _playlist.children.isNotEmpty;
      if (requireActive) {
        if (_active) {
          // If the native platform is already active, send it a play request.
          // NOTE: If a load() request happens simultaneously, this may result
          // in two play requests being sent. The platform implementation should
          // ignore the second play request since it is already playing.
          _sendPlayRequest(await _platform, playCompleter);
        } else {
          // If the native platform wasn't already active, activating it will
          // implicitly restore the playing state and send a play request.
          _setPlatformActive(true, playCompleter: playCompleter)
              ?.catchError((dynamic e) async => null);
        }
      }
    } else {
      // Revert if we fail to activate the audio session.
      _playerEventSubject.add(playerEvent.copyWith(playing: false));
    }
    await playCompleter.future;
  }

  /// Pauses the currently playing media. This method does nothing if
  /// ![playing].
  Future<void> pause() async {
    if (_disposed) return;
    if (!playing) return;
    final stopwatch = Stopwatch();
    stopwatch.start();
    _playInterrupted = false;
    // Update local state immediately so that queries aren't surprised.
    _playerEventSubject.add(PlayerEvent(
      playing: false,
      playbackEvent: playbackEvent.copyWith(
        updatePosition: position,
        updateTime: DateTime.now(),
      ),
    ));
    // Allow propagation to secondary streams.
    await playingStream.firstWhere((p) => p == playing);
    // TODO: perhaps modify platform side to ensure new state is broadcast
    // before this method returns.
    await (await _platform).pause(PauseRequest());
  }

  Future<void> _sendPlayRequest(
      AudioPlayerPlatform platform, Completer<void>? playCompleter) async {
    try {
      if (!playing) return; // defensive
      await platform.play(PlayRequest());
      playCompleter?.complete();
    } catch (e, stackTrace) {
      playCompleter?.completeError(e, stackTrace);
    }
  }

  /// Stops playing audio and releases decoders and other native platform
  /// resources needed to play audio. The current audio source state will be
  /// retained and playback can be resumed at a later point in time.
  ///
  /// Use [stop] if the app is done playing audio for now but may need still
  /// want to resume playback later. Use [dispose] when the app is completely
  /// finished playing audio. Use [pause] instead if you would like to keep the
  /// decoders alive so that the app can quickly resume audio playback.
  Future<void> stop() async {
    if (_disposed) return;
    final future =
        _setPlatformActive(false)?.catchError((dynamic e) async => null);

    _playInterrupted = false;
    // Update local state immediately so that queries aren't surprised.
    _playerEventSubject.add(playerEvent.copyWith(playing: false));
    await future;
  }

  /// Sets the volume of this player, where 1.0 is normal volume.
  Future<void> setVolume(final double volume) async {
    if (_disposed) return;
    _volumeSubject.add(volume);
    await (await _platform).setVolume(SetVolumeRequest(volume: volume));
  }

  /// Sets whether silence should be skipped in audio playback. (Currently
  /// Android only).
  Future<void> setSkipSilenceEnabled(bool enabled) async {
    if (_disposed) return;
    final previouslyEnabled = skipSilenceEnabled;
    if (enabled == previouslyEnabled) return;
    _skipSilenceEnabledSubject.add(enabled);
    try {
      await (await _platform)
          .setSkipSilence(SetSkipSilenceRequest(enabled: enabled));
    } catch (e) {
      _skipSilenceEnabledSubject.add(previouslyEnabled);
      rethrow;
    }
  }

  /// Sets the playback speed to use when [playing] is `true`, where 1.0 is
  /// normal speed. Note that values in excess of 1.0 may result in stalls if
  /// the playback speed is faster than the player is able to downloaded the
  /// audio.
  Future<void> setSpeed(final double speed) async {
    if (_disposed) return;
    _playerEventSubject.add(playerEvent.copyWith(
      playbackEvent: playbackEvent.copyWith(
        updatePosition: position,
        updateTime: DateTime.now(),
      ),
    ));
    _speedSubject.add(speed);
    await (await _platform).setSpeed(SetSpeedRequest(speed: speed));
  }

  /// Sets the factor by which pitch will be shifted.
  Future<void> setPitch(final double pitch) async {
    if (_disposed) return;
    _playerEventSubject.add(playerEvent.copyWith(
      playbackEvent: playbackEvent.copyWith(
        updatePosition: position,
        updateTime: DateTime.now(),
      ),
    ));
    _pitchSubject.add(pitch);
    await (await _platform).setPitch(SetPitchRequest(pitch: pitch));
  }

  /// Sets the [LoopMode]. Looping will be gapless on Android, iOS and macOS. On
  /// web, there will be a slight gap at the loop point.
  Future<void> setLoopMode(LoopMode mode) async {
    if (_disposed) return;
    _sequenceStateSubject.add(sequenceState.copyWith(loopMode: mode));
    await (await _platform).setLoopMode(
        SetLoopModeRequest(loopMode: LoopModeMessage.values[mode.index]));
  }

  /// Sets whether shuffle mode is enabled.
  Future<void> setShuffleModeEnabled(bool enabled) async {
    if (_disposed) return;
    _sequenceStateSubject
        .add(sequenceState.copyWith(shuffleModeEnabled: enabled));
    await (await _platform).setShuffleMode(SetShuffleModeRequest(
        shuffleMode:
            enabled ? ShuffleModeMessage.all : ShuffleModeMessage.none));
  }

  /// Shuffles the playlist using the [ShuffleOrder] passed into the
  /// constructor, and recursively shuffles each nested [AudioSource]
  /// according to its own [ShuffleOrder].
  Future<void> shuffle() async {
    if (_disposed) return;
    if (_playlist.children.isEmpty) return;
    _playlist._shuffle(initialIndex: currentIndex);
    await _broadcastSequence(sequenceChanged: false);
    await (await _platform).setShuffleOrder(
        SetShuffleOrderRequest(audioSourceMessage: _playlist._toMessage()));
  }

  /// Sets automaticallyWaitsToMinimizeStalling for AVPlayer in iOS 10.0 or later, defaults to true.
  /// Has no effect on Android clients
  Future<void> setAutomaticallyWaitsToMinimizeStalling(
      final bool automaticallyWaitsToMinimizeStalling) async {
    if (_disposed) return;
    _automaticallyWaitsToMinimizeStalling =
        automaticallyWaitsToMinimizeStalling;
    await (await _platform).setAutomaticallyWaitsToMinimizeStalling(
        SetAutomaticallyWaitsToMinimizeStallingRequest(
            enabled: automaticallyWaitsToMinimizeStalling));
  }

  /// Sets canUseNetworkResourcesForLiveStreamingWhilePaused on iOS/macOS,
  /// defaults to false.
  Future<void> setCanUseNetworkResourcesForLiveStreamingWhilePaused(
      final bool canUseNetworkResourcesForLiveStreamingWhilePaused) async {
    if (_disposed) return;
    _canUseNetworkResourcesForLiveStreamingWhilePaused =
        canUseNetworkResourcesForLiveStreamingWhilePaused;
    await (await _platform)
        .setCanUseNetworkResourcesForLiveStreamingWhilePaused(
            SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest(
                enabled: canUseNetworkResourcesForLiveStreamingWhilePaused));
  }

  /// Sets preferredPeakBitRate on iOS/macOS, defaults to true.
  Future<void> setPreferredPeakBitRate(
      final double preferredPeakBitRate) async {
    if (_disposed) return;
    _preferredPeakBitRate = preferredPeakBitRate;
    await (await _platform).setPreferredPeakBitRate(
        SetPreferredPeakBitRateRequest(bitRate: preferredPeakBitRate));
  }

  /// Sets allowsExternalPlayback on iOS/macOS, defaults to false.
  Future<void> setAllowsExternalPlayback(
      final bool allowsExternalPlayback) async {
    if (_disposed) return;
    _allowsExternalPlayback = allowsExternalPlayback;
    await (await _platform).setAllowsExternalPlayback(
        SetAllowsExternalPlaybackRequest(
            allowsExternalPlayback: allowsExternalPlayback));
  }

  /// Seeks to a particular [position], and optionally to a particular [index]
  /// within [sequence].
  ///
  /// A `null` [position] seeks to the head of a live stream.
  Future<void> seek(final Duration? position, {int? index}) async {
    if (_disposed) return;
    _pluginLoadRequest?.resetInitialSeekValues();
    switch (processingState) {
      case ProcessingState.loading:
        return;
      default:
        try {
          _seeking = true;
          final prevPlaybackEvent = playbackEvent;
          _playerEventSubject.add(playerEvent.copyWith(
            playbackEvent: prevPlaybackEvent.copyWith(
              updatePosition: position,
              updateTime: DateTime.now(),
            ),
          ));
          _positionDiscontinuitySubject.add(PositionDiscontinuity(
              PositionDiscontinuityReason.seek,
              prevPlaybackEvent,
              playbackEvent));
          await (await _platform)
              .seek(SeekRequest(position: position, index: index));
          if (playing && !_active) {
            _setPlatformActive(true)?.catchError((dynamic e) async => null);
          }
        } finally {
          _seeking = false;
        }
    }
  }

  /// Seeks to the next item, or does nothing if there is no next item.
  Future<void> seekToNext() async {
    if (hasNext) {
      await seek(Duration.zero, index: nextIndex);
    }
  }

  /// Seeks to the previous item, or does nothing if there is no previous item.
  Future<void> seekToPrevious() async {
    if (hasPrevious) {
      await seek(Duration.zero, index: previousIndex);
    }
  }

  /// Sets the Android audio attributes for this player. Has no effect on other
  /// platforms. This will cause a new Android AudioSession ID to be generated.
  Future<void> setAndroidAudioAttributes(
      AndroidAudioAttributes audioAttributes) async {
    if (_disposed) return;
    if (!_isAndroid() && !_isUnitTest()) return;
    if (audioAttributes == _androidAudioAttributes) return;
    _androidAudioAttributes = audioAttributes;
    await _internalSetAndroidAudioAttributes(await _platform, audioAttributes);
  }

  Future<void> _internalSetAndroidAudioAttributes(AudioPlayerPlatform platform,
      AndroidAudioAttributes audioAttributes) async {
    if (!_isAndroid() && !_isUnitTest()) return;
    await platform.setAndroidAudioAttributes(SetAndroidAudioAttributesRequest(
        contentType: audioAttributes.contentType.index,
        flags: audioAttributes.flags.value,
        usage: audioAttributes.usage.value));
  }

  /// Sets the `crossorigin` attribute on the `<audio>` element backing this
  /// player instance on web (see
  /// [HTMLMediaElement crossorigin](https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/crossOrigin) ).
  ///
  /// If [webCrossOrigin] is null (the initial state), the URL will be fetched
  /// without CORS. If it is `useCredentials`, a CORS request will be made
  /// exchanging credentials (via cookies/certificates/HTTP authentication)
  /// regardless of the origin. If it is 'anonymous', a CORS request will be
  /// made, but credentials are exchanged only if the URL is fetched from the
  /// same origin.
  Future<void> setWebCrossOrigin(WebCrossOrigin? webCrossOrigin) async {
    if (_disposed) return;
    if (!kIsWeb && !_isUnitTest()) return;

    await (await _platform).setWebCrossOrigin(
      SetWebCrossOriginRequest(
          crossOrigin: webCrossOrigin == null
              ? null
              : WebCrossOriginMessage.values[webCrossOrigin.index]),
    );
    _webCrossOrigin = webCrossOrigin;
  }

  /// Sets a specific device output id on Web.
  Future<void> setWebSinkId(String webSinkId) async {
    if (_disposed) return;
    if (!kIsWeb && !_isUnitTest()) return;

    await (await _platform)
        .setWebSinkId(SetWebSinkIdRequest(sinkId: webSinkId));
    _webSinkId = webSinkId;
  }

  /// Releases all resources associated with this player. You must invoke this
  /// after you are done with the player.
  Future<void> dispose() {
    return _lock.synchronized(() async {
      if (_disposed) return;
      await stop();
      _disposed = true;
      if (_nativePlatform != null) {
        await _disposePlatform(await _nativePlatform!);
        _nativePlatform = null;
      }
      if (_idlePlatform != null) {
        await _disposePlatform(_idlePlatform!);
        _idlePlatform = null;
      }
      _playlist.children.clear();
      for (var s in _audioSources.values) {
        s._dispose();
      }
      _audioSources.clear();
      _proxy.stop();
      await _playerDataSubscription?.cancel();
      await _playbackEventSubscription?.cancel();
      await _androidAudioAttributesSubscription?.cancel();
      await _becomingNoisyEventSubscription?.cancel();
      await _interruptionEventSubscription?.cancel();
      await _positionDiscontinuitySubscription?.cancel();
      await _currentIndexSubscription?.cancel();
      await _errorsSubscription?.cancel();
      await _errorsResetSubscription?.cancel();

      await _playerEventSubject.close();

      await _playbackEventPipe;

      await _playbackEventSubject.close();
      await _sequenceStateSubject.close();
      await _playingSubject.close();
      await _volumeSubject.close();
      await _speedSubject.close();
      await _pitchSubject.close();

      await _durationSubject.close();
      await _processingStateSubject.close();
      await _bufferedPositionSubject.close();
      await _icyMetadataSubject.close();
      await _androidAudioSessionIdSubject.close();
      await _errorSubject.close();
      await _playerStateSubject.close();
      await _skipSilenceEnabledSubject.close();
      await _positionDiscontinuitySubject.close();
      await _sequenceSubject.close();
      await _shuffleIndicesSubject.close();
      await _currentIndexSubject.close();
      await _loopModeSubject.close();
      await _shuffleModeEnabledSubject.close();
      await _shuffleModeEnabledSubject.close();
    });
  }

  /// Switches to using the native platform when [active] is `true` and using the
  /// idle platform when [active] is `false`. If an audio source has been set,
  /// the returned future completes with its duration if known, or `null`
  /// otherwise.
  ///
  /// The platform will not switch if [active] == [_active] unless [force] is
  /// `true`.
  Future<Duration?>? _setPlatformActive(bool active,
      {Completer<void>? playCompleter, bool force = false}) {
    if (_disposed) return null;
    if (!force && (active == _active)) return _loadFuture;
    _platformLoading = active;

    // Warning! Tricky async code lies ahead.
    // (This should definitely be made less tricky)
    // This method itself is not asynchronous, and guarantees that _platform
    // will be set in this cycle to a Future. The platform returned by that
    // future takes time to initialise and so we need to handle the case where
    // that initialisation was interrupted by another call to
    // _setPlatformActive.

    // Store the current activation sequence number. activationNumber should
    // equal _activationCount for the duration of this call, unless it is
    // interrupted by another simultaneous call.
    final pluginLoadRequest = _pluginLoadRequest;
    final activationNumber = ++_activationCount;

    /// Tells whether we've been interrupted.
    bool wasInterrupted() =>
        _activationCount != activationNumber ||
        pluginLoadRequest != _pluginLoadRequest ||
        _disposed;

    final durationCompleter = Completer<Duration?>();

    // Checks if we were interrupted and aborts the current activation. If we
    // are interrupted, there are two cases:
    // 1. If we were activating the native platform, abort with an exception.
    // 2. If we were activating the idle dummy, abort silently.
    //
    // We should call this after each awaited call since those are opportunities
    // for other coroutines to run and interrupt this one.
    bool checkInterruption() {
      // No interruption.
      if (!wasInterrupted()) return false;
      pluginLoadRequest?.checkInterruption();
      // An interruption that we can ignore
      if (!active) return true;
      // An interruption that should throw
      throw PlayerInterruptedException('Loading interrupted');
    }

    // This method updates _active and _platform before yielding to the next
    // task in the event loop.
    _active = active;
    final position = this.position;
    final currentIndex = this.currentIndex;
    final playlist = _playlist;

    void subscribeToEvents(AudioPlayerPlatform platform) {
      _playerDataSubscription =
          platform.playerDataMessageStream.listen((message) {
        if (message.playing != null && message.playing != playing) {
          _playerEventSubject
              .add(playerEvent.copyWith(playing: message.playing!));
        }
        if (message.volume != null) {
          _volumeSubject.add(message.volume!);
        }
        if (message.speed != null) {
          _speedSubject.add(message.speed!);
        }
        if (message.pitch != null) {
          _pitchSubject.add(message.pitch!);
        }
        if (message.loopMode != null) {
          _sequenceStateSubject.add(sequenceState.copyWith(
              loopMode: LoopMode.values[message.loopMode!.index]));
        }
        if (message.shuffleMode != null) {
          _sequenceStateSubject.add(sequenceState.copyWith(
              shuffleModeEnabled:
                  message.shuffleMode != ShuffleModeMessage.none));
        }
      }, onDone: () {
        _playerDataSubscription = null;
      });
      _playbackEventSubscription =
          platform.playbackEventMessageStream.listen((message) {
        var duration = message.duration;
        var index = message.currentIndex ?? currentIndex;
        if (index != null && index < sequence.length) {
          if (duration == null) {
            duration = sequence[index].duration;
          } else {
            sequence[index].duration = duration;
          }
        }
        if (_platformLoading &&
            message.processingState != ProcessingStateMessage.idle) {
          _platformLoading = false;
        }
        final newPlaybackEvent = PlaybackEvent(
          // The platform may emit an idle state while it's starting up which we
          // override here.
          processingState: _platformLoading
              ? ProcessingState.loading
              : ProcessingState.values[message.processingState.index],
          updateTime: message.updateTime,
          updatePosition: message.updatePosition,
          bufferedPosition: message.bufferedPosition,
          duration: duration,
          icyMetadata: message.icyMetadata == null
              ? null
              : IcyMetadata._fromMessage(message.icyMetadata!),
          currentIndex: index,
          androidAudioSessionId: message.androidAudioSessionId,
          errorCode: message.errorCode,
          errorMessage: message.errorMessage,
        );
        _loadFuture = Future.value(newPlaybackEvent.duration);
        if (newPlaybackEvent == playbackEvent) {
          return;
        }
        final oldPlaybackEvent = playbackEvent;
        _playerEventSubject.add(playerEvent.copyWith(
          playbackEvent: newPlaybackEvent,
        ));
        if (playbackEvent.processingState != oldPlaybackEvent.processingState &&
            playbackEvent.processingState == ProcessingState.idle &&
            _active) {
          _setPlatformActive(false)?.catchError((dynamic e) async => null);
        }
      }, onError: (Object e, [StackTrace? st]) {});
    }

    Future<AudioPlayerPlatform> setPlatform() async {
      // We need to cancel before calling _disposePlatform in order to prevent a
      // MissingPluginException. This also means there will potentially be
      // unconsumed events which will unfortunately appear when spinning up a
      // new platform player. For now, we change the player ID to avoid wires
      // getting crossed, although it would be better to find a way to flush the
      // event channel and keep the same ID.

      AudioPlayerPlatform inactiveResult(AudioPlayerPlatform platform) {
        durationCompleter.complete(null);
        return platform;
      }

      final platform = await _lock.synchronized(() async {
        final oldPlatform = _platformValue;
        // Strangely, this throws "Cannot complete a future with itself" when
        // _playbackEventSubscription==null under flutter test.
        // await _playbackEventSubscription?.cancel();
        // await _playerDataSubscription?.cancel();
        if (_playbackEventSubscription != null) {
          await _playbackEventSubscription!.cancel();
        }
        if (_playerDataSubscription != null) {
          await _playerDataSubscription!.cancel();
        }

        if (!force) {
          if (oldPlatform != null && oldPlatform is! _IdleAudioPlayer) {
            await _disposePlatform(oldPlatform);
          }
        }
        // During initialisation, we must only use this platform reference in case
        // _platform is updated again during initialisation.
        final platform = active && !_disposed
            ? await (_nativePlatform = _pluginPlatform.init(InitRequest(
                id: _id = _generateId(),
                audioLoadConfiguration: _audioLoadConfiguration?._toMessage(),
                androidAudioEffects: (_isAndroid() || _isUnitTest())
                    ? _audioPipeline.androidAudioEffects
                        .map((audioEffect) => audioEffect._toMessage())
                        .toList()
                    : [],
                darwinAudioEffects: (_isDarwin() || _isUnitTest())
                    ? _audioPipeline.darwinAudioEffects
                        .map((audioEffect) => audioEffect._toMessage())
                        .toList()
                    : [],
                androidOffloadSchedulingEnabled:
                    _androidOffloadSchedulingEnabled,
                androidAudioOffloadPreferences:
                    _androidAudioOffloadPreferences?._toMessage(),
                useLazyPreparation: _playlist.useLazyPreparation,
              )))
            : (_idlePlatform = _IdleAudioPlayer(
                id: _id = _generateId(),
                sequenceStream: sequenceStream,
                errorCode: playbackEvent.errorCode,
                errorMessage: playbackEvent.errorMessage,
              ));

        _platformValue = platform;
        return platform;
      });
      if (checkInterruption() || _disposed) return inactiveResult(platform);

      if (active) {
        if (playlist.children.isNotEmpty) {
          _playerEventSubject.add(playerEvent.copyWith(
            playbackEvent: playbackEvent.copyWith(
              updatePosition: position,
              processingState: ProcessingState.loading,
            ),
          ));
        }

        final automaticallyWaitsToMinimizeStalling =
            this.automaticallyWaitsToMinimizeStalling;
        final playing = this.playing;
        // To avoid a glitch in ExoPlayer, ensure that any requested audio
        // attributes are set before loading the audio source.
        if (_isAndroid() || _isUnitTest()) {
          if (_androidApplyAudioAttributes) {
            final audioSession = await AudioSession.instance;
            if (checkInterruption()) return inactiveResult(platform);
            _androidAudioAttributes ??=
                audioSession.configuration?.androidAudioAttributes;
          }
          if (_androidAudioAttributes != null) {
            await _internalSetAndroidAudioAttributes(
                platform, _androidAudioAttributes!);
            if (checkInterruption()) return inactiveResult(platform);
          }
        }
        if (!automaticallyWaitsToMinimizeStalling) {
          // Only set if different from default.
          await platform.setAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest(
                  enabled: automaticallyWaitsToMinimizeStalling));
          if (checkInterruption()) return inactiveResult(platform);
        }
        await platform.setVolume(SetVolumeRequest(volume: volume));
        if (checkInterruption()) return inactiveResult(platform);
        await platform.setSpeed(SetSpeedRequest(speed: speed));
        if (checkInterruption()) return inactiveResult(platform);
        try {
          await platform.setPitch(SetPitchRequest(pitch: pitch));
        } catch (e) {
          // setPitch not supported on this platform.
        }
        if (checkInterruption()) return inactiveResult(platform);
        try {
          await platform.setSkipSilence(
              SetSkipSilenceRequest(enabled: skipSilenceEnabled));
        } catch (e) {
          // setSkipSilence not supported on this platform.
        }
        if (checkInterruption()) return inactiveResult(platform);
        await platform.setLoopMode(SetLoopModeRequest(
            loopMode: LoopModeMessage.values[loopMode.index]));
        if (checkInterruption()) return inactiveResult(platform);
        await platform.setShuffleMode(SetShuffleModeRequest(
            shuffleMode: shuffleModeEnabled
                ? ShuffleModeMessage.all
                : ShuffleModeMessage.none));
        if (checkInterruption()) return inactiveResult(platform);
        if (kIsWeb) {
          if (_webCrossOrigin != null) {
            await platform.setWebCrossOrigin(SetWebCrossOriginRequest(
              crossOrigin: WebCrossOriginMessage.values[_webCrossOrigin!.index],
            ));
            if (checkInterruption()) return inactiveResult(platform);
          }
          if (_webSinkId != '') {
            await platform.setWebSinkId(SetWebSinkIdRequest(
              sinkId: _webSinkId,
            ));
            if (checkInterruption()) return inactiveResult(platform);
          }
        }
        for (var audioEffect in _audioPipeline._audioEffects) {
          await audioEffect._activate(platform);
          if (checkInterruption()) return inactiveResult(platform);
        }
        if (playing) {
          _sendPlayRequest(platform, playCompleter);
        }
      }

      subscribeToEvents(platform);

      try {
        final initialSeekValues = pluginLoadRequest?.initialSeekValues ??
            (index: currentIndex, position: position);
        final duration = await _load(
          platform,
          _playlist,
          initialSeekValues: initialSeekValues,
        );
        durationCompleter.complete(duration);
      } catch (e, stackTrace) {
        durationCompleter.completeError(e, stackTrace);
      }

      return platform;
    }

    _platform = setPlatform();
    return _platform.then((_) => durationCompleter.future);
  }

  /// Disposes of the given platform.
  Future<void> _disposePlatform(AudioPlayerPlatform platform) async {
    if (platform is _IdleAudioPlayer) {
      await platform.dispose(DisposeRequest());
    } else {
      _nativePlatform = null;
      try {
        await _pluginPlatform.disposePlayer(DisposePlayerRequest(id: _id!));
      } catch (e) {
        // Fallback if disposePlayer hasn't been implemented.
        await platform.dispose(DisposeRequest());
      } finally {
        _id = null;
      }
    }
  }

  /// Clears the plugin's internal asset cache directory. Call this when the
  /// app's assets have changed to force assets to be re-fetched from the asset
  /// bundle.
  static Future<void> clearAssetCache() async {
    if (kIsWeb) return;
    await for (var file in (await _getCacheDir()).list()) {
      await file.delete(recursive: true);
    }
  }

  Exception _convertException(PlatformException e) {
    const kUnknownErrorCode = 9999999;
    const kInterruptedErrorCode = 10000000;
    final details =
        (e.details as Map<dynamic, dynamic>?)?.cast<String, dynamic>();
    final index = details?['index'] as int? ?? currentIndex;
    final code = int.tryParse(e.code);
    if (code == null) {
      if (e.code == 'abort') {
        return PlayerInterruptedException(e.message);
      } else {
        return PlayerException(kUnknownErrorCode, e.message, index);
      }
    } else if (code == kInterruptedErrorCode) {
      return PlayerInterruptedException(e.message);
    } else {
      return PlayerException(code, e.message, index);
    }
  }
}

/// Captures the details of any error accessing, loading or playing an audio
/// source, including an invalid or inaccessible URL, or an audio encoding that
/// could not be understood.
class PlayerException implements Exception {
  /// On iOS and macOS, maps to `NSError.code`. On Android, maps to
  /// `ExoPlaybackException.type`. On Web, maps to `MediaError.code`.
  final int code;

  /// On iOS and macOS, maps to `NSError.localizedDescription`. On Android,
  /// maps to `ExoPlaybackException.getMessage()`. On Web, a generic message
  /// is provided.
  final String? message;

  /// The index of the audio source associated with this error.
  final int? index;

  PlayerException(this.code, this.message, this.index);

  @override
  String toString() => "($code) $message";
}

/// An error that occurs when one operation on the player has been interrupted
/// (e.g. by another simultaneous operation).
class PlayerInterruptedException implements Exception {
  final String? message;

  PlayerInterruptedException(this.message);

  @override
  String toString() => "$message";
}

/// Encapsulates the playback event and the playing state of the player.
class PlayerEvent {
  /// The current [PlaybackEvent]
  final PlaybackEvent playbackEvent;

  /// Whether the player is currently playing.
  final bool playing;

  PlayerEvent({PlaybackEvent? playbackEvent, this.playing = false})
      : playbackEvent = playbackEvent ?? PlaybackEvent();

  PlayerEvent copyWith({
    PlaybackEvent? playbackEvent,
    bool? playing,
  }) =>
      PlayerEvent(
        playbackEvent: playbackEvent ?? this.playbackEvent,
        playing: playing ?? this.playing,
      );

  @override
  int get hashCode => Object.hash(
        playbackEvent.hashCode,
        playing,
      );

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is PlayerEvent &&
      playbackEvent == other.playbackEvent &&
      playing == other.playing;

  @override
  String toString() => "{playbackEvent=$playbackEvent, playing=$playing}";
}

/// Encapsulates the playback state and current position of the player.
class PlaybackEvent {
  /// The current processing state.
  final ProcessingState processingState;

  /// When the last time a position discontinuity happened, as measured in time
  /// since the epoch.
  final DateTime updateTime;

  /// The position at [updateTime].
  final Duration updatePosition;

  /// The buffer position.
  final Duration bufferedPosition;

  /// The media duration, or `null` if unknown.
  final Duration? duration;

  /// The latest ICY metadata received through the audio stream if available.
  final IcyMetadata? icyMetadata;

  /// The index of the currently playing item, or `null` if no item is selected.
  // TODO: Consider introducing currentAudioSourceId
  final int? currentIndex;

  /// The current Android AudioSession ID if set.
  final int? androidAudioSessionId;

  /// The error code when [processingState] is [ProcessingState.error].
  ///
  /// Supported on Android, iOS and web. For other platforms, check the
  /// documentation of the respective platform implementation.
  final int? errorCode;

  /// The error message when [processingState] is [ProcessingState.error].
  ///
  /// Supported on Android, iOS and web. For other platforms, check the
  /// documentation of the respective platform implementation.
  final String? errorMessage;

  PlaybackEvent({
    this.processingState = ProcessingState.idle,
    DateTime? updateTime,
    this.updatePosition = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.duration,
    this.icyMetadata,
    this.currentIndex,
    this.androidAudioSessionId,
    this.errorCode,
    this.errorMessage,
  }) : updateTime = updateTime ?? DateTime.now();

  /// Returns a copy of this event with given properties replaced.
  PlaybackEvent copyWith({
    ProcessingState? processingState,
    DateTime? updateTime,
    Duration? updatePosition,
    Duration? bufferedPosition,
    Duration? duration,
    IcyMetadata? icyMetadata,
    int? currentIndex,
    int? androidAudioSessionId,
    int? errorCode,
    String? errorMessage,
  }) =>
      PlaybackEvent(
        processingState: processingState ?? this.processingState,
        updateTime: updateTime ?? this.updateTime,
        updatePosition: updatePosition ?? this.updatePosition,
        bufferedPosition: bufferedPosition ?? this.bufferedPosition,
        duration: duration ?? this.duration,
        icyMetadata: icyMetadata ?? this.icyMetadata,
        currentIndex: currentIndex ?? this.currentIndex,
        androidAudioSessionId:
            androidAudioSessionId ?? this.androidAudioSessionId,
        errorCode: errorCode ?? this.errorCode,
        errorMessage: errorMessage ?? this.errorMessage,
      );

  @override
  int get hashCode => Object.hash(
        processingState,
        updateTime,
        updatePosition,
        bufferedPosition,
        duration,
        icyMetadata,
        currentIndex,
        androidAudioSessionId,
        errorCode,
        errorMessage,
      );

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is PlaybackEvent &&
      processingState == other.processingState &&
      updateTime == other.updateTime &&
      updatePosition == other.updatePosition &&
      bufferedPosition == other.bufferedPosition &&
      duration == other.duration &&
      icyMetadata == other.icyMetadata &&
      currentIndex == other.currentIndex &&
      androidAudioSessionId == other.androidAudioSessionId &&
      errorCode == other.errorCode &&
      errorMessage == other.errorMessage;

  @override
  String toString() =>
      "{processingState=$processingState, updateTime=$updateTime, updatePosition=$updatePosition, bufferedPosition=$bufferedPosition, duration=$duration, currentIndex=$currentIndex}";
}

/// Enumerates the different processing states of a player.
enum ProcessingState {
  /// The player has not loaded an [AudioSource].
  idle,

  /// The player is loading an [AudioSource].
  loading,

  /// The player is buffering audio and unable to play.
  buffering,

  /// The player is has enough audio buffered and is able to play.
  ready,

  /// The player has reached the end of the audio.
  completed,
}

/// Encapsulates the playing and processing states. These two states vary
/// orthogonally, and so if [processingState] is [ProcessingState.buffering],
/// you can check [playing] to determine whether the buffering occurred while
/// the player was playing or while the player was paused.
class PlayerState {
  /// Whether the player will play when [processingState] is
  /// [ProcessingState.ready].
  final bool playing;

  /// The current processing state of the player.
  final ProcessingState processingState;

  PlayerState(this.playing, this.processingState);

  @override
  String toString() => 'playing=$playing,processingState=$processingState';

  @override
  int get hashCode => Object.hash(playing, processingState);

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is PlayerState &&
      other.playing == playing &&
      other.processingState == processingState;
}

class IcyInfo {
  final String? title;
  final String? url;

  static IcyInfo _fromMessage(IcyInfoMessage message) => IcyInfo(
        title: message.title,
        url: message.url,
      );

  IcyInfo({required this.title, required this.url});

  @override
  String toString() => 'title=$title,url=$url';

  @override
  int get hashCode => Object.hash(title, url);

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is IcyInfo &&
      other.title == title &&
      other.url == url;
}

class IcyHeaders {
  final int? bitrate;
  final String? genre;
  final String? name;
  final int? metadataInterval;
  final String? url;
  final bool? isPublic;

  static IcyHeaders _fromMessage(IcyHeadersMessage message) => IcyHeaders(
        bitrate: message.bitrate,
        genre: message.genre,
        name: message.name,
        metadataInterval: message.metadataInterval,
        url: message.url,
        isPublic: message.isPublic,
      );

  IcyHeaders({
    required this.bitrate,
    required this.genre,
    required this.name,
    required this.metadataInterval,
    required this.url,
    required this.isPublic,
  });

  @override
  String toString() =>
      'bitrate=$bitrate,genre=$genre,name=$name,metadataInterval=$metadataInterval,url=$url,isPublic=$isPublic';

  @override
  int get hashCode => toString().hashCode;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is IcyHeaders &&
      other.bitrate == bitrate &&
      other.genre == genre &&
      other.name == name &&
      other.metadataInterval == metadataInterval &&
      other.url == url &&
      other.isPublic == isPublic;
}

class IcyMetadata {
  final IcyInfo? info;
  final IcyHeaders? headers;

  static IcyMetadata _fromMessage(IcyMetadataMessage message) => IcyMetadata(
        info: message.info == null ? null : IcyInfo._fromMessage(message.info!),
        headers: message.headers == null
            ? null
            : IcyHeaders._fromMessage(message.headers!),
      );

  IcyMetadata({required this.info, required this.headers});

  @override
  int get hashCode => Object.hash(info, headers);

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is IcyMetadata &&
      other.info == info &&
      other.headers == headers;
}

/// Encapsulates the [sequence] and [currentIndex] state and ensures
/// consistency such that [currentIndex] is within the range of
/// `sequence.length`. If `sequence.length` is 0, then [currentIndex] is also
/// 0.
class SequenceState {
  static const _defaultInt = -9999999;

  /// The current sequence of [IndexedAudioSource]s.
  final List<IndexedAudioSource> sequence;

  /// The index of the current source in the sequence.
  int? get currentIndex =>
      sequence.isNotEmpty ? min(_currentIndex ?? 0, sequence.length - 1) : null;

  // The index of the current source in the sequence.
  final int? _currentIndex;

  /// The current shuffle order
  final List<int> shuffleIndices;

  /// Whether shuffle mode is enabled.
  final bool shuffleModeEnabled;

  /// The current loop mode.
  final LoopMode loopMode;

  SequenceState({
    required this.sequence,
    required int? currentIndex,
    required this.shuffleIndices,
    required this.shuffleModeEnabled,
    required this.loopMode,
  }) : _currentIndex = currentIndex;

  /// The current source in the sequence.
  IndexedAudioSource? get currentSource =>
      sequence.isEmpty || currentIndex == null ? null : sequence[currentIndex!];

  /// The effective sequence. This is equivalent to [sequence]. If
  /// [shuffleModeEnabled] is true, this is modulated by [shuffleIndices].
  List<IndexedAudioSource> get effectiveSequence => shuffleModeEnabled
      ? shuffleIndices.map((i) => sequence[i]).toList()
      : sequence;

  /// Returns a copy of this [SequenceState] with the given properties replaced.
  SequenceState copyWith({
    List<IndexedAudioSource>? sequence,
    int? currentIndex = _defaultInt,
    List<int>? shuffleIndices,
    bool? shuffleModeEnabled,
    LoopMode? loopMode,
  }) =>
      SequenceState(
        sequence: sequence ?? this.sequence,
        currentIndex:
            currentIndex != _defaultInt ? currentIndex : this.currentIndex,
        shuffleIndices: shuffleIndices ?? this.shuffleIndices,
        shuffleModeEnabled: shuffleModeEnabled ?? this.shuffleModeEnabled,
        loopMode: loopMode ?? this.loopMode,
      );
}

/// Configuration options to use when loading audio from a source.
class AudioLoadConfiguration {
  /// Bufferring and loading options for iOS/macOS.
  final DarwinLoadControl? darwinLoadControl;

  /// Buffering and loading options for Android.
  final AndroidLoadControl? androidLoadControl;

  /// Speed control for live streams on Android.
  final AndroidLivePlaybackSpeedControl? androidLivePlaybackSpeedControl;

  const AudioLoadConfiguration({
    this.darwinLoadControl,
    this.androidLoadControl,
    this.androidLivePlaybackSpeedControl,
  });

  AudioLoadConfigurationMessage _toMessage() => AudioLoadConfigurationMessage(
        darwinLoadControl: darwinLoadControl?._toMessage(),
        androidLoadControl: androidLoadControl?._toMessage(),
        androidLivePlaybackSpeedControl:
            androidLivePlaybackSpeedControl?._toMessage(),
      );
}

/// Buffering and loading options for iOS/macOS.
class DarwinLoadControl {
  /// (iOS/macOS) Whether the player will wait for sufficient data to be
  /// buffered before starting playback to avoid the likelihood of stalling.
  final bool automaticallyWaitsToMinimizeStalling;

  /// (iOS/macOS) The duration of audio that should be buffered ahead of the
  /// current position. If not set or `null`, the system will try to set an
  /// appropriate buffer duration.
  final Duration? preferredForwardBufferDuration;

  /// (iOS/macOS) Whether the player can continue downloading while paused to
  /// keep the state up to date with the live stream.
  final bool canUseNetworkResourcesForLiveStreamingWhilePaused;

  /// (iOS/macOS) If specified, limits the download bandwidth in bits per
  /// second.
  final double? preferredPeakBitRate;

  const DarwinLoadControl({
    this.automaticallyWaitsToMinimizeStalling = true,
    this.preferredForwardBufferDuration,
    this.canUseNetworkResourcesForLiveStreamingWhilePaused = false,
    this.preferredPeakBitRate,
  });

  DarwinLoadControlMessage _toMessage() => DarwinLoadControlMessage(
        automaticallyWaitsToMinimizeStalling:
            automaticallyWaitsToMinimizeStalling,
        preferredForwardBufferDuration: preferredForwardBufferDuration,
        canUseNetworkResourcesForLiveStreamingWhilePaused:
            canUseNetworkResourcesForLiveStreamingWhilePaused,
        preferredPeakBitRate: preferredPeakBitRate,
      );
}

/// Buffering and loading options for Android.
class AndroidLoadControl {
  /// (Android) The minimum duration of audio that should be buffered ahead of
  /// the current position.
  final Duration minBufferDuration;

  /// (Android) The maximum duration of audio that should be buffered ahead of
  /// the current position.
  final Duration maxBufferDuration;

  /// (Android) The duration of audio that must be buffered before starting
  /// playback after a user action.
  final Duration bufferForPlaybackDuration;

  /// (Android) The duration of audio that must be buffered before starting
  /// playback after a buffer depletion.
  final Duration bufferForPlaybackAfterRebufferDuration;

  /// (Android) The target buffer size in bytes.
  final int? targetBufferBytes;

  /// (Android) Whether to prioritize buffer time constraints over buffer size
  /// constraints.
  final bool prioritizeTimeOverSizeThresholds;

  /// (Android) The back buffer duration.
  final Duration backBufferDuration;

  const AndroidLoadControl({
    this.minBufferDuration = const Duration(seconds: 50),
    this.maxBufferDuration = const Duration(seconds: 50),
    this.bufferForPlaybackDuration = const Duration(milliseconds: 2500),
    this.bufferForPlaybackAfterRebufferDuration = const Duration(seconds: 5),
    this.targetBufferBytes,
    this.prioritizeTimeOverSizeThresholds = false,
    this.backBufferDuration = Duration.zero,
  });

  AndroidLoadControlMessage _toMessage() => AndroidLoadControlMessage(
        minBufferDuration: minBufferDuration,
        maxBufferDuration: maxBufferDuration,
        bufferForPlaybackDuration: bufferForPlaybackDuration,
        bufferForPlaybackAfterRebufferDuration:
            bufferForPlaybackAfterRebufferDuration,
        targetBufferBytes: targetBufferBytes,
        prioritizeTimeOverSizeThresholds: prioritizeTimeOverSizeThresholds,
        backBufferDuration: backBufferDuration,
      );
}

/// Speed control for live streams on Android.
class AndroidLivePlaybackSpeedControl {
  /// (Android) The minimum playback speed to use when adjusting playback speed
  /// to approach the target live offset, if none is defined by the media.
  final double fallbackMinPlaybackSpeed;

  /// (Android) The maximum playback speed to use when adjusting playback speed
  /// to approach the target live offset, if none is defined by the media.
  final double fallbackMaxPlaybackSpeed;

  /// (Android) The minimum interval between playback speed changes on a live
  /// stream.
  final Duration minUpdateInterval;

  /// (Android) The proportional control factor used to adjust playback speed on
  /// a live stream. The adjusted speed is calculated as: `1.0 +
  /// proportionalControlFactor * (currentLiveOffsetSec - targetLiveOffsetSec)`.
  final double proportionalControlFactor;

  /// (Android) The maximum difference between the current live offset and the
  /// target live offset within which the speed 1.0 is used.
  final Duration maxLiveOffsetErrorForUnitSpeed;

  /// (Android) The increment applied to the target live offset whenever the
  /// player rebuffers.
  final Duration targetLiveOffsetIncrementOnRebuffer;

  /// (Android) The factor for smoothing the minimum possible live offset
  /// achievable during playback.
  final double minPossibleLiveOffsetSmoothingFactor;

  const AndroidLivePlaybackSpeedControl({
    this.fallbackMinPlaybackSpeed = 0.97,
    this.fallbackMaxPlaybackSpeed = 1.03,
    this.minUpdateInterval = const Duration(seconds: 1),
    this.proportionalControlFactor = 1.0,
    this.maxLiveOffsetErrorForUnitSpeed = const Duration(milliseconds: 20),
    this.targetLiveOffsetIncrementOnRebuffer =
        const Duration(milliseconds: 500),
    this.minPossibleLiveOffsetSmoothingFactor = 0.999,
  });

  AndroidLivePlaybackSpeedControlMessage _toMessage() =>
      AndroidLivePlaybackSpeedControlMessage(
        fallbackMinPlaybackSpeed: fallbackMinPlaybackSpeed,
        fallbackMaxPlaybackSpeed: fallbackMaxPlaybackSpeed,
        minUpdateInterval: minUpdateInterval,
        proportionalControlFactor: proportionalControlFactor,
        maxLiveOffsetErrorForUnitSpeed: maxLiveOffsetErrorForUnitSpeed,
        targetLiveOffsetIncrementOnRebuffer:
            targetLiveOffsetIncrementOnRebuffer,
        minPossibleLiveOffsetSmoothingFactor:
            minPossibleLiveOffsetSmoothingFactor,
      );
}

/// Audio offload modes for Android.
enum AndroidAudioOffloadMode { disabled, enabled }

/// Audio offload preferences for Android.
///
/// IMPORTANT: activation of audio offload depends on a negotiation between
/// ExoPlayer and the device to determine whether offload can be supported for a
/// given format and with given constraints (gapless, speed change). However,
/// several instances have been reported where the device incorrectly confirms
/// support for audio offload when it doesn't, and this can result in buggy
/// audio playback. Therefore, it is advised that you programmatically enable
/// audio offload only on device/OS combinations that you have tested and
/// verified to work.
class AndroidAudioOffloadPreferences {
  /// The preferred audio offload mode.
  final AndroidAudioOffloadMode audioOffloadMode;

  /// Constrains enablement of audio offload to happen only if the device
  /// can fulfill any gapless transitions that might exist in the playlist
  /// during offload.
  final bool isGaplessSupportRequired;

  /// Constrains enablement of audio offload to happen only if the device
  /// can fulfill any speed change request during offload.
  final bool isSpeedChangeSupportRequired;

  const AndroidAudioOffloadPreferences({
    this.audioOffloadMode = AndroidAudioOffloadMode.disabled,
    this.isGaplessSupportRequired = false,
    this.isSpeedChangeSupportRequired = false,
  });

  AndroidAudioOffloadPreferencesMessage _toMessage() =>
      AndroidAudioOffloadPreferencesMessage(
        audioOffloadMode:
            AndroidAudioOffloadModeMessage.values[audioOffloadMode.index],
        isGaplessSupportRequired: isGaplessSupportRequired,
        isSpeedChangeSupportRequired: isSpeedChangeSupportRequired,
      );
}

class ProgressiveAudioSourceOptions {
  final AndroidExtractorOptions? androidExtractorOptions;
  final DarwinAssetOptions? darwinAssetOptions;

  const ProgressiveAudioSourceOptions({
    this.androidExtractorOptions,
    this.darwinAssetOptions,
  });

  ProgressiveAudioSourceOptionsMessage _toMessage() =>
      ProgressiveAudioSourceOptionsMessage(
        androidExtractorOptions: androidExtractorOptions?._toMessage(),
        darwinAssetOptions: darwinAssetOptions?._toMessage(),
      );
}

class DarwinAssetOptions {
  final bool preferPreciseDurationAndTiming;

  const DarwinAssetOptions({this.preferPreciseDurationAndTiming = false});

  DarwinAssetOptionsMessage _toMessage() => DarwinAssetOptionsMessage(
        preferPreciseDurationAndTiming: preferPreciseDurationAndTiming,
      );
}

class AndroidExtractorOptions {
  static const flagMp3EnableIndexSeeking = 1 << 2;
  static const flagMp3DisableId3Metadata = 1 << 3;

  final bool constantBitrateSeekingEnabled;
  final bool constantBitrateSeekingAlwaysEnabled;
  final int mp3Flags;

  const AndroidExtractorOptions({
    this.constantBitrateSeekingEnabled = true,
    this.constantBitrateSeekingAlwaysEnabled = false,
    this.mp3Flags = 0,
  });

  AndroidExtractorOptionsMessage _toMessage() => AndroidExtractorOptionsMessage(
        constantBitrateSeekingEnabled: constantBitrateSeekingEnabled,
        constantBitrateSeekingAlwaysEnabled:
            constantBitrateSeekingAlwaysEnabled,
        mp3Flags: mp3Flags,
      );
}

/// A local proxy HTTP server for making remote GET requests with headers.
class _ProxyHttpServer {
  late HttpServer _server;
  bool _running = false;

  /// Maps request keys to [_ProxyHandler]s.
  final Map<String, _ProxyHandler> _handlerMap = {};

  /// The port this server is bound to on localhost. This is set only after
  /// [start] has completed.
  int get port => _server.port;

  /// Registers a [UriAudioSource] to be served through this proxy. This may be
  /// called only after [start] has completed.
  Uri addUriAudioSource(UriAudioSource source) {
    final uri = source.uri;
    final headers = <String, String>{};
    if (source.headers != null) {
      headers.addAll(source.headers!.cast<String, String>());
    }
    final path = _requestKey(uri);
    _handlerMap[path] = _proxyHandlerForUri(
      uri,
      headers: headers,
      userAgent: source._player?._userAgent,
    );
    return uri.replace(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: port,
    );
  }

  /// Registers a [StreamAudioSource] to be served through this proxy. This may
  /// be called only after [start] has completed.
  Uri addStreamAudioSource(StreamAudioSource source) {
    final uri = _sourceUri(source);
    final path = _requestKey(uri);
    _handlerMap[path] = _proxyHandlerForSource(source);
    return uri;
  }

  Uri _sourceUri(StreamAudioSource source) => Uri.http(
      '${InternetAddress.loopbackIPv4.address}:$port', '/id/${source._id}');

  /// A unique key for each request that can be processed by this proxy,
  /// made up of the URL path and query string. It is not possible to
  /// simultaneously track requests that have the same URL path and query
  /// but differ in other respects such as the port or headers.
  String _requestKey(Uri uri) => '${uri.path}?${uri.query}';

  /// Starts the server if it is not already running.
  Future<dynamic> ensureRunning() async {
    if (_running) return;
    return await start();
  }

  /// Starts the server.
  Future<dynamic> start() async {
    _running = true;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      if (request.method == 'GET') {
        final uriPath = _requestKey(request.uri);
        final handler = _handlerMap[uriPath]!;
        handler(this, request);
      }
    }, onDone: () {
      _running = false;
    }, onError: (Object e, StackTrace st) {
      _running = false;
    });
  }

  /// Stops the server
  Future<dynamic> stop() async {
    if (!_running) return;
    _running = false;
    return await _server.close();
  }
}

/// Encapsulates the start and end of an HTTP range request.
class _HttpRangeRequest {
  /// The starting byte position of the range request.
  final int start;

  /// The last byte position of the range request, or `null` if requesting
  /// until the end of the media.
  final int? end;

  /// The end byte position (exclusive), defaulting to `null`.
  int? get endEx => end == null ? null : end! + 1;

  _HttpRangeRequest(this.start, this.end);

  /// Format a range header for this request.
  String get header =>
      'bytes=$start-${end != null ? (end! - 1).toString() : ""}';

  /// Creates an [_HttpRangeRequest] from [header].
  static _HttpRangeRequest? parse(List<String>? header) {
    if (header == null || header.isEmpty) return null;
    final match = RegExp(r'^bytes=(\d+)(-(\d+)?)?').firstMatch(header.first);
    if (match == null) return null;
    int? intGroup(int i) => match[i] != null ? int.parse(match[i]!) : null;
    return _HttpRangeRequest(intGroup(1)!, intGroup(3));
  }
}

/// Encapsulates the range information in an HTTP range response.
class _HttpRangeResponse {
  /// The starting byte position of the range.
  final int start;

  /// The last byte position of the range.
  final int end;

  /// The total number of bytes in the entire media.
  final int? fullLength;

  _HttpRangeResponse(this.start, this.end, this.fullLength);

  /// The end byte position (exclusive).
  int? get endEx => end + 1;

  /// The number of bytes requested.
  int? get length => endEx == null ? null : endEx! - start;

  /// The content-range header value to use in HTTP responses.
  String get header => 'bytes $start-$end/${fullLength?.toString() ?? "*"}';
}

/// Specifies a source of audio to be played. Audio sources are composable
/// using the subclasses of this class. The same [AudioSource] instance should
/// not be used simultaneously by more than one [AudioPlayer].
abstract class AudioSource {
  final String _id;
  AudioPlayer? _player;

  /// Creates an [AudioSource] from a [Uri] with optional headers by
  /// attempting to guess the type of stream. On iOS, this uses Apple's SDK to
  /// automatically detect the stream type. On Android, the type of stream will
  /// be guessed from the extension.
  ///
  /// If you are loading DASH or HLS streams that do not have standard "mpd" or
  /// "m3u8" extensions in their URIs, this method will fail to detect the
  /// stream type on Android. If you know in advance what type of audio stream
  /// it is, you should instantiate [DashAudioSource] or [HlsAudioSource]
  /// directly.
  ///
  /// If headers are set, just_audio will create a cleartext local HTTP proxy on
  /// your device to forward HTTP requests with headers included.
  ///
  /// The [tag] is for associating your app's own data with each audio source,
  /// e.g. title, cover art, a primary key for your DB. Such data can be
  /// conveniently retrieved from the tag while rendering the UI.
  ///
  /// When using just_audio_background, [tag] must be a MediaItem, a class
  /// provided by that package. If you wish to have more control over the tag
  /// for background audio purposes, consider using the plugin audio_service
  /// instead of just_audio_background.
  static UriAudioSource uri(Uri uri,
      {Map<String, String>? headers, dynamic tag}) {
    bool hasExtension(Uri uri, String extension) =>
        uri.path.toLowerCase().endsWith('.$extension') ||
        uri.fragment.toLowerCase().endsWith('.$extension');
    if (hasExtension(uri, 'mpd')) {
      return DashAudioSource(uri, headers: headers, tag: tag);
    } else if (hasExtension(uri, 'm3u8')) {
      return HlsAudioSource(uri, headers: headers, tag: tag);
    } else {
      return ProgressiveAudioSource(uri, headers: headers, tag: tag);
    }
  }

  /// Convenience method to create an audio source for a file.
  ///
  /// This is equivalent to:
  ///
  /// ```
  /// AudioSource.uri(Uri.file(filePath), tag: tag);
  /// ```
  static UriAudioSource file(String filePath, {dynamic tag}) {
    return AudioSource.uri(Uri.file(filePath), tag: tag);
  }

  /// Convenience method to create an audio source for an asset.
  ///
  /// For assets within the same package, this is equivalent to:
  ///
  /// ```
  /// AudioSource.uri(Uri.parse('asset:///$assetPath'), tag: tag);
  /// ```
  ///
  /// If the asset is to be loaded from a different package, the [package]
  /// parameter must be given to specify the package name.
  static UriAudioSource asset(String assetPath,
      {String? package, dynamic tag}) {
    final keyName =
        package == null ? assetPath : 'packages/$package/$assetPath';
    return AudioSource.uri(Uri.parse('asset:///$keyName'), tag: tag);
  }

  AudioSource({String? id}) : _id = id ?? _uuid.v4();

  @mustCallSuper
  void _onAttach(AudioPlayer player) {
    _player = player;
    player._registerAudioSource(this);
  }

  @mustCallSuper
  Future<void> _onLoad() async {}

  String? get _userAgent => _player?._userAgent;

  void _shuffle({int? initialIndex});

  @mustCallSuper
  void _dispose() {
    // Without this we might make _player "late".
    _player = null;
  }

  AudioSourceMessage _toMessage();

  List<IndexedAudioSource> get sequence;

  List<int> get shuffleIndices;

  @override
  int get hashCode => _id.hashCode;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is AudioSource &&
      other._id == _id;
}

/// An [AudioSource] that can appear in a sequence.
abstract class IndexedAudioSource extends AudioSource {
  final dynamic tag;
  Duration? duration;

  IndexedAudioSource({this.tag, this.duration});

  @override
  void _shuffle({int? initialIndex}) {}

  @override
  List<IndexedAudioSource> get sequence => [this];

  @override
  List<int> get shuffleIndices => [0];
}

/// An abstract class representing audio sources that are loaded from a URI.
abstract class UriAudioSource extends IndexedAudioSource {
  final Uri uri;
  final Map<String, String>? headers;
  Uri? _overrideUri;

  UriAudioSource(this.uri, {this.headers, dynamic tag, Duration? duration})
      : super(tag: tag, duration: duration);

  /// If [uri] points to an asset, this gives us [_overrideUri] which is the URI
  /// of the copied asset on the filesystem, otherwise it gives us the original
  /// [uri].
  Uri get _effectiveUri => _overrideUri ?? uri;

  Map<String, String>? get _mergedHeaders =>
      headers == null && _userAgent == null
          ? null
          : {
              if (headers != null)
                for (var key in headers!.keys) key: headers![key]!,
              if (_userAgent != null) 'User-Agent': _userAgent!,
            };

  @override
  Future<void> _onLoad() async {
    await super._onLoad();
    if (uri.scheme == 'asset') {
      _overrideUri = await _loadAsset(uri.pathSegments.join('/'));
    } else if (uri.scheme != 'file' &&
        !kIsWeb &&
        _player!._useProxyForRequestHeaders &&
        (headers != null || _player!._userAgent != null)) {
      await _player!._proxy.ensureRunning();
      _overrideUri = _player!._proxy.addUriAudioSource(this);
    }
  }

  Future<Uri> _loadAsset(String assetPath) async {
    if (kIsWeb) {
      // Mapping from extensions to content types for the web player. If an
      // extension is missing, please submit a pull request.
      const mimeTypes = {
        '.aac': 'audio/aac',
        '.mp3': 'audio/mpeg',
        '.ogg': 'audio/ogg',
        '.opus': 'audio/opus',
        '.wav': 'audio/wav',
        '.weba': 'audio/webm',
        '.mp4': 'audio/mp4',
        '.m4a': 'audio/mp4',
        '.aif': 'audio/x-aiff',
        '.aifc': 'audio/x-aiff',
        '.aiff': 'audio/x-aiff',
        '.m3u': 'audio/x-mpegurl',
      };
      // Default to 'audio/mpeg'
      final mimeType =
          mimeTypes[p.extension(assetPath).toLowerCase()] ?? 'audio/mpeg';
      return _encodeDataUrl(
          base64
              .encode((await rootBundle.load(assetPath)).buffer.asUint8List()),
          mimeType);
    } else {
      // For non-web platforms, extract the asset into a cache file and pass
      // that to the player.
      final file = await _getCacheFile(assetPath);
      // Not technically inter-isolate-safe, although low risk. Could consider
      // locking the file or creating a separate lock file.
      if (!file.existsSync()) {
        file.createSync(recursive: true);
        await file.writeAsBytes(
            (await rootBundle.load(assetPath)).buffer.asUint8List());
      }
      return Uri.file(file.path);
    }
  }

  /// Gets the cache file for an asset with the proper extension
  Future<File> _getCacheFile(final String assetPath) async => File(p.joinAll([
        (await _getCacheDir()).path,
        'assets',
        ...Uri.parse(assetPath).pathSegments,
      ]));
}

/// An [AudioSource] representing a regular media file such as an MP3 or M4A
/// file. The following URI schemes are supported:
///
/// * file: loads from a local file (provided you give your app permission to
/// access that file).
/// * asset: loads from a Flutter asset (not supported on Web).
/// * http(s): loads from an HTTP(S) resource.
///
/// On platforms except for the web, the supplied [headers] will be passed with
/// the HTTP(S) request.
///
/// If headers are set, just_audio will create a cleartext local HTTP proxy on
/// your device to forward HTTP requests with headers included.
class ProgressiveAudioSource extends UriAudioSource {
  final ProgressiveAudioSourceOptions? options;

  ProgressiveAudioSource(
    super.uri, {
    super.headers,
    super.tag,
    super.duration,
    this.options,
  });

  @override
  AudioSourceMessage _toMessage() => ProgressiveAudioSourceMessage(
        id: _id,
        uri: _effectiveUri.toString(),
        headers: _mergedHeaders,
        tag: tag,
        options: options?._toMessage(),
      );
}

/// An [AudioSource] representing a DASH stream. The following URI schemes are
/// supported:
///
/// * file: loads from a local file (provided you give your app permission to
/// access that file).
/// * asset: loads from a Flutter asset (not supported on Web).
/// * http(s): loads from an HTTP(S) resource.
///
/// On platforms except for the web, the supplied [headers] will be passed with
/// the HTTP(S) request. Currently headers are not recursively applied to items
/// the HTTP(S) request. Currently headers are not applied recursively.
///
/// If headers are set, just_audio will create a cleartext local HTTP proxy on
/// your device to forward HTTP requests with headers included.
class DashAudioSource extends UriAudioSource {
  DashAudioSource(Uri uri,
      {Map<String, String>? headers, dynamic tag, Duration? duration})
      : super(uri, headers: headers, tag: tag, duration: duration);

  @override
  AudioSourceMessage _toMessage() => DashAudioSourceMessage(
        id: _id,
        uri: _effectiveUri.toString(),
        headers: _mergedHeaders,
        tag: tag,
      );
}

/// An [AudioSource] representing an HLS stream. The following URI schemes are
/// supported:
///
/// * file: loads from a local file (provided you give your app permission to
/// access that file).
/// * asset: loads from a Flutter asset (not supported on Web).
/// * http(s): loads from an HTTP(S) resource.
///
/// On platforms except for the web, the supplied [headers] will be passed with
/// the HTTP(S) request. Currently headers are not applied recursively.
///
/// If headers are set, just_audio will create a cleartext local HTTP proxy on
/// your device to forward HTTP requests with headers included.
class HlsAudioSource extends UriAudioSource {
  HlsAudioSource(Uri uri,
      {Map<String, String>? headers, dynamic tag, Duration? duration})
      : super(uri, headers: headers, tag: tag, duration: duration);

  @override
  AudioSourceMessage _toMessage() => HlsAudioSourceMessage(
        id: _id,
        uri: _effectiveUri.toString(),
        headers: _mergedHeaders,
        tag: tag,
      );
}

/// An [AudioSource] for a period of silence.
///
/// NOTE: This is currently supported on Android only.
class SilenceAudioSource extends IndexedAudioSource {
  @override
  Duration get duration => super.duration!;

  @override
  set duration(covariant Duration duration) => super.duration = duration;

  SilenceAudioSource({
    dynamic tag,
    required Duration duration,
  }) : super(tag: tag, duration: duration);

  @override
  AudioSourceMessage _toMessage() =>
      SilenceAudioSourceMessage(id: _id, duration: duration);
}

/// An [AudioSource] representing a concatenation of multiple audio sources to
/// be played in succession. This can be used to create playlists. Playback
/// between items will be gapless on Android, iOS and macOS, while there will
/// be a slight gap on Web.
///
/// Audio sources can be dynamically added, removed and reordered while the
/// audio is playing.
@Deprecated('Use AudioPlayer.setAudioSources instead')
class ConcatenatingAudioSource extends AudioSource {
  final _lock = Lock();
  final List<AudioSource> children;
  final bool useLazyPreparation;
  ShuffleOrder _shuffleOrder;

  /// Creates a [ConcatenatingAudioSorce] with the specified [children]. If
  /// [useLazyPreparation] is `true`, children will be loaded/buffered as late
  /// as possible before needed for playback (currently supported on Android,
  /// iOS, MacOS). When [AudioPlayer.shuffleModeEnabled] is `true`,
  /// [shuffleOrder] will be used to determine the playback order (defaulting to
  /// [DefaultShuffleOrder]).
  ConcatenatingAudioSource({
    required this.children,
    this.useLazyPreparation = true,
    ShuffleOrder? shuffleOrder,
  }) : _shuffleOrder = shuffleOrder ?? DefaultShuffleOrder()
          ..insert(0, children.length);

  /// Creates the root playlist of a player.
  ConcatenatingAudioSource._playlist({
    required this.children,
    this.useLazyPreparation = true,
    ShuffleOrder? shuffleOrder,
  })  : _shuffleOrder = shuffleOrder ?? DefaultShuffleOrder()
          ..insert(0, children.length),
        super(id: '');

  @override
  void _onAttach(AudioPlayer player) {
    super._onAttach(player);
    for (var source in children) {
      source._onAttach(player);
    }
  }

  @override
  Future<void> _onLoad() async {
    await super._onLoad();
    for (var source in children) {
      await source._onLoad();
    }
  }

  @override
  void _shuffle({int? initialIndex}) {
    int? localInitialIndex;
    // si = index in [sequence]
    // ci = index in [children] array.
    for (var ci = 0, si = 0; ci < children.length; ci++) {
      final child = children[ci];
      final childLength = child.sequence.length;
      final initialIndexWithinThisChild = initialIndex != null &&
          initialIndex >= si &&
          initialIndex < si + childLength;
      if (initialIndexWithinThisChild) {
        localInitialIndex = ci;
      }
      final childInitialIndex =
          initialIndexWithinThisChild ? (initialIndex - si) : null;
      child._shuffle(initialIndex: childInitialIndex);
      si += childLength;
    }
    _shuffleOrder.shuffle(initialIndex: localInitialIndex);
  }

  /// Appends an [AudioSource].
  Future<void> add(AudioSource audioSource) {
    return _lock.synchronized(() async {
      final index = children.length;
      children.add(audioSource);
      _shuffleOrder.insert(index, 1);
      final player = _player;
      if (player != null) {
        audioSource._onAttach(player);
        await player._broadcastSequence();
        if (player._active) {
          await audioSource._onLoad();
        }
        await (await player._platform).concatenatingInsertAll(
            ConcatenatingInsertAllRequest(
                id: _id,
                index: index,
                children: [audioSource._toMessage()],
                shuffleOrder: List.of(_shuffleOrder.indices)));
      }
    });
  }

  /// Inserts an [AudioSource] at [index].
  Future<void> insert(int index, AudioSource audioSource) {
    return _lock.synchronized(() async {
      children.insert(index, audioSource);
      _shuffleOrder.insert(index, 1);
      final player = _player;
      if (player != null) {
        audioSource._onAttach(player);
        await player._broadcastSequence();
        if (player._active) {
          await audioSource._onLoad();
        }
        await (await player._platform).concatenatingInsertAll(
            ConcatenatingInsertAllRequest(
                id: _id,
                index: index,
                children: [audioSource._toMessage()],
                shuffleOrder: List.of(_shuffleOrder.indices)));
      }
    });
  }

  /// Appends multiple [AudioSource]s.
  Future<void> addAll(List<AudioSource> children) {
    return _lock.synchronized(() async {
      final index = this.children.length;
      this.children.addAll(children);
      _shuffleOrder.insert(index, children.length);
      final player = _player;
      if (player != null) {
        for (var child in children) {
          child._onAttach(player);
        }
        await player._broadcastSequence();
        if (player._active) {
          for (var child in children) {
            await child._onLoad();
          }
        }
        await (await player._platform).concatenatingInsertAll(
            ConcatenatingInsertAllRequest(
                id: _id,
                index: index,
                children: children.map((child) => child._toMessage()).toList(),
                shuffleOrder: List.of(_shuffleOrder.indices)));
      }
    });
  }

  /// Inserts multiple [AudioSource]s at [index].
  Future<void> insertAll(int index, List<AudioSource> children) {
    return _lock.synchronized(() async {
      this.children.insertAll(index, children);
      _shuffleOrder.insert(index, children.length);
      final player = _player;
      if (player != null) {
        for (var child in children) {
          child._onAttach(player);
        }
        await player._broadcastSequence();
        if (player._active) {
          for (var child in children) {
            await child._onLoad();
          }
        }
        await (await player._platform).concatenatingInsertAll(
            ConcatenatingInsertAllRequest(
                id: _id,
                index: index,
                children: children.map((child) => child._toMessage()).toList(),
                shuffleOrder: List.of(_shuffleOrder.indices)));
      }
    });
  }

  /// Dynamically removes an [AudioSource] at [index] after this
  /// [ConcatenatingAudioSource] has already been loaded.
  Future<void> removeAt(int index) {
    return _lock.synchronized(() async {
      children.removeAt(index);
      _shuffleOrder.removeRange(index, index + 1);
      final player = _player;
      if (player != null) {
        await player._broadcastSequence();
        await (await player._platform).concatenatingRemoveRange(
            ConcatenatingRemoveRangeRequest(
                id: _id,
                startIndex: index,
                endIndex: index + 1,
                shuffleOrder: List.of(_shuffleOrder.indices)));
      }
    });
  }

  /// Removes a range of [AudioSource]s from index [start] inclusive to [end]
  /// exclusive.
  Future<void> removeRange(int start, int end) {
    return _lock.synchronized(() async {
      children.removeRange(start, end);
      _shuffleOrder.removeRange(start, end);
      final player = _player;
      if (player != null) {
        await player._broadcastSequence();
        await (await player._platform).concatenatingRemoveRange(
            ConcatenatingRemoveRangeRequest(
                id: _id,
                startIndex: start,
                endIndex: end,
                shuffleOrder: List.of(_shuffleOrder.indices)));
      }
    });
  }

  /// Moves an [AudioSource] from [currentIndex] to [newIndex].
  Future<void> move(int currentIndex, int newIndex) {
    return _lock.synchronized(() async {
      children.insert(newIndex, children.removeAt(currentIndex));
      _shuffleOrder.removeRange(currentIndex, currentIndex + 1);
      _shuffleOrder.insert(newIndex, 1);
      final player = _player;
      if (player != null) {
        await player._broadcastSequence();
        await (await player._platform).concatenatingMove(
            ConcatenatingMoveRequest(
                id: _id,
                currentIndex: currentIndex,
                newIndex: newIndex,
                shuffleOrder: List.of(_shuffleOrder.indices)));
      }
    });
  }

  /// Removes all [AudioSource]s.
  Future<void> clear() {
    return _lock.synchronized(() async {
      final end = children.length;
      children.clear();
      _shuffleOrder.clear();
      final player = _player;
      if (player != null) {
        await player._broadcastSequence();
        await (await player._platform).concatenatingRemoveRange(
            ConcatenatingRemoveRangeRequest(
                id: _id,
                startIndex: 0,
                endIndex: end,
                shuffleOrder: List.of(_shuffleOrder.indices)));
      }
    });
  }

  /// Initialise without communicating with platform.
  Future<void> _init(List<AudioSource> children, ShuffleOrder shuffleOrder) {
    return _lock.synchronized(() async {
      this.children.replaceRange(0, this.children.length, children);
      _shuffleOrder = shuffleOrder;
      _shuffleOrder.clear();
      _shuffleOrder.insert(0, children.length);
      final player = _player;
      if (player != null) {
        for (var child in children) {
          child._onAttach(player);
        }
        await player._broadcastSequence();
        if (player._active) {
          for (var child in children) {
            await child._onLoad();
          }
        }
      }
    });
  }

  /// The number of [AudioSource]s.
  int get length => children.length;

  AudioSource operator [](int index) => children[index];

  @override
  List<IndexedAudioSource> get sequence =>
      children.expand((s) => s.sequence).toList();

  @override
  List<int> get shuffleIndices {
    var offset = 0;
    final childIndicesList = <List<int>>[];
    for (var child in children) {
      final childIndices = child.shuffleIndices.map((i) => i + offset).toList();
      childIndicesList.add(childIndices);
      offset += childIndices.length;
    }
    final indices = <int>[];
    for (var index in _shuffleOrder.indices) {
      indices.addAll(childIndicesList[index]);
    }
    return indices;
  }

  @override
  AudioSourceMessage _toMessage() => ConcatenatingAudioSourceMessage(
      id: _id,
      children: children.map((child) => child._toMessage()).toList(),
      useLazyPreparation: useLazyPreparation,
      shuffleOrder: _shuffleOrder.indices);
}

/// An [AudioSource] that clips the audio of a [UriAudioSource] between a
/// certain start and end time.
class ClippingAudioSource extends IndexedAudioSource {
  final UriAudioSource child;
  final Duration? start;
  final Duration? end;

  /// Creates an audio source that clips [child] to the range [start]..[end],
  /// where [start] and [end] default to the beginning and end of the original
  /// [child] source.
  ClippingAudioSource({
    required this.child,
    this.start,
    this.end,
    dynamic tag,
    Duration? duration,
  }) : super(tag: tag, duration: duration);

  @override
  void _onAttach(AudioPlayer player) {
    super._onAttach(player);
    child._onAttach(player);
  }

  @override
  Future<void> _onLoad() async {
    await super._onLoad();
    await child._onLoad();
  }

  @override
  AudioSourceMessage _toMessage() => ClippingAudioSourceMessage(
      id: _id,
      child: child._toMessage() as UriAudioSourceMessage,
      start: start,
      end: end,
      tag: tag);
}

// An [AudioSource] that loops a nested [AudioSource] a finite number of times.
// NOTE: this can be inefficient when using a large loop count. If you wish to
// loop an infinite number of times, use [AudioPlayer.setLoopMode].
@Deprecated('Use List.filled(N, audioSource) instead')
class LoopingAudioSource extends AudioSource {
  AudioSource child;
  final int count;

  LoopingAudioSource({
    required this.child,
    required this.count,
  }) : super();

  @override
  void _onAttach(AudioPlayer player) {
    super._onAttach(player);
    child._onAttach(player);
  }

  @override
  Future<void> _onLoad() async {
    await super._onLoad();
    await child._onLoad();
  }

  @override
  void _shuffle({int? initialIndex}) {}

  @override
  List<IndexedAudioSource> get sequence =>
      List.generate(count, (i) => child).expand((s) => s.sequence).toList();

  @override
  List<int> get shuffleIndices => List.generate(count, (i) => i);

  @override
  AudioSourceMessage _toMessage() => LoopingAudioSourceMessage(
      id: _id, child: child._toMessage(), count: count);
}

Uri _encodeDataUrl(String base64Data, String mimeType) =>
    Uri.parse('data:$mimeType;base64,$base64Data');

/// An [AudioSource] that provides audio dynamically. Subclasses must override
/// [request] to provide the encoded audio data. This API is experimental.
@experimental
abstract class StreamAudioSource extends IndexedAudioSource {
  Uri? _uri;
  StreamAudioSource({dynamic tag}) : super(tag: tag);

  @override
  Future<void> _onLoad() async {
    await super._onLoad();
    if (kIsWeb) {
      final response = await request();
      _uri ??= _encodeDataUrl(await base64.encoder.bind(response.stream).join(),
          response.contentType);
    } else {
      await _player!._proxy.ensureRunning();
      _uri = _player!._proxy.addStreamAudioSource(this);
    }
  }

  /// Used by the player to request a byte range of encoded audio data in small
  /// chunks, from byte position [start] inclusive (or from the beginning of the
  /// audio data if not specified) to [end] exclusive (or the end of the audio
  /// data if not specified). If the returned future completes with an error,
  /// a 500 response will be sent back to the player.
  Future<StreamAudioResponse> request([int? start, int? end]);

  @override
  AudioSourceMessage _toMessage() => ProgressiveAudioSourceMessage(
      id: _id, uri: _uri.toString(), headers: null, tag: tag);
}

/// The response for a [StreamAudioSource]. This API is experimental.
@experimental
class StreamAudioResponse {
  /// Indicates to the client whether or not range requests are supported for
  /// the requested media. If `true`, the client may make further requests
  /// specifying the `start` and possibly also the `end` parameters of the range
  /// request, otherwise these will both be null.
  final bool rangeRequestsSupported;

  /// When responding to a range request, this holds the byte length of the
  /// entire media, otherwise it holds `null`.
  final int? sourceLength;

  /// The number of bytes returned in this response, or `null` if unknown. Note:
  /// this may be different from the length of the entire media for a range
  /// request.
  final int? contentLength;

  /// The starting byte position of the response data if responding to a range
  /// request.
  final int? offset;

  /// The MIME type of the audio.
  final String contentType;

  /// The audio content returned by this response.
  final Stream<List<int>> stream;

  StreamAudioResponse({
    this.rangeRequestsSupported = true,
    required this.sourceLength,
    required this.contentLength,
    required this.offset,
    required this.stream,
    required this.contentType,
  });
}

/// This is an experimental audio source that caches the audio while it is being
/// downloaded and played. It is not supported on platforms that do not provide
/// access to the file system (e.g. web).
@experimental
class LockCachingAudioSource extends StreamAudioSource {
  Future<HttpClientResponse>? _response;
  final Uri uri;
  final Map<String, String>? headers;
  final Future<File> cacheFile;
  int _progress = 0;
  final _requests = <_StreamingByteRangeRequest>[];
  final _downloadProgressSubject = BehaviorSubject<double>();
  bool _downloading = false;

  /// Creates a [LockCachingAudioSource] to that provides [uri] to the player
  /// while simultaneously caching it to [cacheFile]. If no cache file is
  /// supplied, just_audio will allocate a cache file internally.
  ///
  /// If headers are set, just_audio will create a cleartext local HTTP proxy on
  /// your device to forward HTTP requests with headers included.
  LockCachingAudioSource(
    this.uri, {
    this.headers,
    File? cacheFile,
    dynamic tag,
  })  : cacheFile =
            cacheFile != null ? Future.value(cacheFile) : _getCacheFile(uri),
        super(tag: tag) {
    _init();
  }

  Future<void> _init() async {
    final cacheFile = await this.cacheFile;
    _downloadProgressSubject.add((await cacheFile.exists()) ? 1.0 : 0.0);
  }

  /// Returns a [UriAudioSource] resolving directly to the cache file if it
  /// exists, otherwise returns `this`. This can be
  Future<IndexedAudioSource> resolve() async {
    final file = await cacheFile;
    return await file.exists() ? AudioSource.uri(Uri.file(file.path)) : this;
  }

  /// Emits the current download progress as a double value from 0.0 (nothing
  /// downloaded) to 1.0 (download complete).
  Stream<double> get downloadProgressStream => _downloadProgressSubject.stream;

  /// Removes the underlying cache files. It is an error to clear the cache
  /// while a download is in progress.
  Future<void> clearCache() async {
    if (_downloading) {
      throw Exception("Cannot clear cache while download is in progress");
    }
    _response = null;
    final cacheFile = await this.cacheFile;
    if (await cacheFile.exists()) {
      await cacheFile.delete();
    }
    final mimeFile = await _mimeFile;
    if (await mimeFile.exists()) {
      await mimeFile.delete();
    }
    _progress = 0;
    _downloadProgressSubject.add(0.0);
  }

  /// Gets the cache file for [uri] with the proper extension.
  static Future<File> _getCacheFile(final Uri uri) async => File(p.joinAll([
        (await _getCacheDir()).path,
        'remote',
        sha256.convert(utf8.encode(uri.toString())).toString() +
            p.extension(uri.path),
      ]));

  Future<File> get _partialCacheFile async =>
      File('${(await cacheFile).path}.part');

  /// We use this to record the original content type of the downloaded audio.
  /// NOTE: We could instead rely on the cache file extension, but the original
  /// URL might not provide a correct extension. As a fallback, we could map the
  /// MIME type to an extension but we will need a complete dictionary.
  Future<File> get _mimeFile async => File('${(await cacheFile).path}.mime');

  Future<String> _readCachedMimeType() async {
    final file = await _mimeFile;
    if (file.existsSync()) {
      return (await _mimeFile).readAsString();
    } else {
      return 'audio/mpeg';
    }
  }

  /// Starts downloading the whole audio file to the cache and fulfill byte-range
  /// requests during the download. There are 3 scenarios:
  ///
  /// 1. If the byte range request falls entirely within the cache region, it is
  /// fulfilled from the cache.
  /// 2. If the byte range request overlaps the cached region, the first part is
  /// fulfilled from the cache, and the region beyond the cache is fulfilled
  /// from a memory buffer of the downloaded data.
  /// 3. If the byte range request is entirely outside the cached region, a
  /// separate HTTP request is made to fulfill it while the download of the
  /// entire file continues in parallel.
  Future<HttpClientResponse> _fetch() async {
    _downloading = true;
    final cacheFile = await this.cacheFile;
    final partialCacheFile = await _partialCacheFile;

    File getEffectiveCacheFile() =>
        partialCacheFile.existsSync() ? partialCacheFile : cacheFile;

    final httpClient = _createHttpClient(userAgent: _player?._userAgent);
    final httpRequest = await _getUrl(httpClient, uri, headers: headers);
    final response = await httpRequest.close();
    if (response.statusCode != 200) {
      httpClient.close();
      throw Exception('HTTP Status Error: ${response.statusCode}');
    }
    (await _partialCacheFile).createSync(recursive: true);
    // TODO: Should close sink after done, but it throws an error.
    // ignore: close_sinks
    final sink = (await _partialCacheFile).openWrite();
    final sourceLength =
        response.contentLength == -1 ? null : response.contentLength;
    final mimeType = response.headers.contentType.toString();
    final acceptRanges = response.headers.value(HttpHeaders.acceptRangesHeader);
    final originSupportsRangeRequests =
        acceptRanges != null && acceptRanges != 'none';
    final mimeFile = await _mimeFile;
    await mimeFile.writeAsString(mimeType);
    final inProgressResponses = <_InProgressCacheResponse>[];
    late StreamSubscription<List<int>> subscription;
    var percentProgress = 0;
    void updateProgress(int newPercentProgress) {
      if (newPercentProgress != percentProgress) {
        percentProgress = newPercentProgress;
        _downloadProgressSubject.add(percentProgress / 100);
      }
    }

    _progress = 0;
    subscription = response.listen((data) async {
      _progress += data.length;
      final newPercentProgress = (sourceLength == null)
          ? 0
          : (sourceLength == 0)
              ? 100
              : (100 * _progress ~/ sourceLength);
      updateProgress(newPercentProgress);
      sink.add(data);
      final readyRequests = _requests
          .where((request) =>
              !originSupportsRangeRequests ||
              request.start == null ||
              (request.start!) < _progress)
          .toList();
      final notReadyRequests = _requests
          .where((request) =>
              originSupportsRangeRequests &&
              request.start != null &&
              (request.start!) >= _progress)
          .toList();
      // Add this live data to any responses in progress.
      for (var cacheResponse in inProgressResponses) {
        final end = cacheResponse.end;
        if (end != null && _progress >= end) {
          // We've received enough data to fulfill the byte range request.
          final subEnd =
              min(data.length, max(0, data.length - (_progress - end)));
          cacheResponse.controller.add(data.sublist(0, subEnd));
          cacheResponse.controller.close();
        } else {
          cacheResponse.controller.add(data);
        }
      }
      inProgressResponses.removeWhere((element) => element.controller.isClosed);
      if (_requests.isEmpty) return;
      // Prevent further data coming from the HTTP source until we have set up
      // an entry in inProgressResponses to continue receiving live HTTP data.
      subscription.pause();
      await sink.flush();
      // Process any requests that start within the cache.
      for (var request in readyRequests) {
        _requests.remove(request);
        int? start, end;
        if (originSupportsRangeRequests) {
          start = request.start;
          end = request.end;
        } else {
          // If the origin doesn't support range requests, the proxy should also
          // ignore range requests and instead serve a complete 200 response
          // which the client (AV or exo player) should know how to deal with.
        }
        final effectiveStart = start ?? 0;
        final effectiveEnd = end ?? sourceLength;
        Stream<List<int>> responseStream;
        if (effectiveEnd != null && effectiveEnd <= _progress) {
          responseStream =
              getEffectiveCacheFile().openRead(effectiveStart, effectiveEnd);
        } else {
          final cacheResponse = _InProgressCacheResponse(end: effectiveEnd);
          inProgressResponses.add(cacheResponse);
          responseStream = Rx.concatEager([
            // NOTE: The cache file part of the stream must not overlap with
            // the live part. "_progress" should
            // to the cache file at the time
            getEffectiveCacheFile().openRead(effectiveStart, _progress),
            cacheResponse.controller.stream,
          ]);
        }
        request.complete(StreamAudioResponse(
          rangeRequestsSupported: originSupportsRangeRequests,
          sourceLength: start != null ? sourceLength : null,
          contentLength:
              effectiveEnd != null ? effectiveEnd - effectiveStart : null,
          offset: start,
          contentType: mimeType,
          stream: responseStream.asBroadcastStream(),
        ));
      }
      subscription.resume();
      // Process any requests that start beyond the cache.
      for (var request in notReadyRequests) {
        _requests.remove(request);
        final start = request.start!;
        final end = request.end ?? sourceLength;
        final httpClient = _createHttpClient(userAgent: _player?._userAgent);

        final rangeRequest = _HttpRangeRequest(start, end);
        _getUrl(httpClient, uri, headers: {
          if (headers != null) ...headers!,
          HttpHeaders.rangeHeader: rangeRequest.header,
        }).then((httpRequest) async {
          final response = await httpRequest.close();
          if (response.statusCode != 206) {
            httpClient.close();
            throw Exception('HTTP Status Error: ${response.statusCode}');
          }
          request.complete(StreamAudioResponse(
            rangeRequestsSupported: originSupportsRangeRequests,
            sourceLength: sourceLength,
            contentLength: end != null ? end - start : null,
            offset: start,
            contentType: mimeType,
            stream: response.asBroadcastStream(),
          ));
        }, onError: (dynamic e, StackTrace? stackTrace) {
          request.fail(e, stackTrace);
        }).onError((Object e, StackTrace st) {
          request.fail(e, st);
        });
      }
    }, onDone: () async {
      if (sourceLength == null) {
        updateProgress(100);
      }
      for (var cacheResponse in inProgressResponses) {
        if (!cacheResponse.controller.isClosed) {
          cacheResponse.controller.close();
        }
      }
      (await _partialCacheFile).renameSync(cacheFile.path);
      await subscription.cancel();
      httpClient.close();
      _downloading = false;
    }, onError: (Object e, StackTrace stackTrace) async {
      (await _partialCacheFile).deleteSync();
      httpClient.close();
      // Fail all pending requests
      for (final req in _requests) {
        req.fail(e, stackTrace);
      }
      _requests.clear();
      // Close all in progress requests
      for (final res in inProgressResponses) {
        res.controller.addError(e, stackTrace);
        res.controller.close();
      }
      _downloading = false;
    }, cancelOnError: true);
    return response;
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final cacheFile = await this.cacheFile;
    if (cacheFile.existsSync()) {
      final sourceLength = cacheFile.lengthSync();
      return StreamAudioResponse(
        rangeRequestsSupported: true,
        sourceLength: start != null ? sourceLength : null,
        contentLength: (end ?? sourceLength) - (start ?? 0),
        offset: start,
        contentType: await _readCachedMimeType(),
        stream: cacheFile.openRead(start, end).asBroadcastStream(),
      );
    }
    final byteRangeRequest = _StreamingByteRangeRequest(start, end);
    _requests.add(byteRangeRequest);
    _response ??=
        _fetch().catchError((dynamic error, StackTrace? stackTrace) async {
      // So that we can restart later
      _response = null;
      // Cancel any pending request
      for (final req in _requests) {
        req.fail(error, stackTrace);
      }
      return Future<HttpClientResponse>.error(error as Object, stackTrace);
    });
    return byteRangeRequest.future.then((response) {
      response.stream.listen((event) {}, onError: (Object e, StackTrace st) {
        // So that we can restart later
        _response = null;
        // Cancel any pending request
        for (final req in _requests) {
          req.fail(e, st);
        }
      });
      return response;
    });
  }
}

/// When a byte range request on a [LockCachingAudioSource] overlaps partially
/// with the cache file and partially with the live HTTP stream, the consumer
/// needs to first consume the cached part before the live part. This class
/// provides a place to buffer the live part until the consumer reaches it, and
/// also keeps track of the [end] of the byte range so that the producer knows
/// when to stop adding data.
class _InProgressCacheResponse {
  // NOTE: This isn't necessarily memory efficient. Since the entire audio file
  // will likely be downloaded at a faster rate than the rate at which the
  // player is consuming audio data, it is also likely that this buffered data
  // will never be used.
  // TODO: Improve this code.
  // ignore: close_sinks
  final controller = ReplaySubject<List<int>>();
  final int? end;
  _InProgressCacheResponse({
    required this.end,
  });
}

/// Request parameters for a [StreamAudioSource].
class _StreamingByteRangeRequest {
  /// The start of the range request.
  final int? start;

  /// The end of the range request.
  final int? end;

  /// Completes when the response is available.
  final _completer = Completer<StreamAudioResponse>();

  _StreamingByteRangeRequest(this.start, this.end);

  /// The response for this request.
  Future<StreamAudioResponse> get future => _completer.future;

  /// Completes this request with the given [response].
  void complete(StreamAudioResponse response) {
    if (_completer.isCompleted) {
      return;
    }
    _completer.complete(response);
  }

  /// Fails this request with the given [error] and [stackTrace].
  void fail(dynamic error, [StackTrace? stackTrace]) {
    if (_completer.isCompleted) {
      return;
    }
    _completer.completeError(error as Object, stackTrace);
  }
}

/// The type of functions that can handle HTTP requests sent to the proxy.
typedef _ProxyHandler = void Function(
    _ProxyHttpServer server, HttpRequest request);

/// A proxy handler for serving audio from a [StreamAudioSource].
_ProxyHandler _proxyHandlerForSource(StreamAudioSource source) {
  Future<void> handler(_ProxyHttpServer server, HttpRequest request) async {
    final rangeRequest =
        _HttpRangeRequest.parse(request.headers[HttpHeaders.rangeHeader]);

    request.response.headers.clear();

    StreamAudioResponse sourceResponse;
    Stream<List<int>> stream;
    try {
      sourceResponse =
          await source.request(rangeRequest?.start, rangeRequest?.endEx);
      stream = sourceResponse.stream;
    } catch (e, st) {
      // ignore: avoid_print
      print("Proxy request failed: $e\n$st");

      request.response.headers.clear();
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
      return;
    }

    request.response.headers
        .set(HttpHeaders.contentTypeHeader, sourceResponse.contentType);

    if (sourceResponse.rangeRequestsSupported) {
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    }

    if (rangeRequest != null && sourceResponse.offset != null) {
      final range = _HttpRangeResponse(
          sourceResponse.offset!,
          sourceResponse.offset! + sourceResponse.contentLength! - 1,
          sourceResponse.sourceLength);
      request.response.contentLength = range.length ?? -1;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, range.header);
      request.response.statusCode = 206;
    } else {
      request.response.contentLength = sourceResponse.contentLength ?? -1;
      request.response.statusCode = 200;
    }

    final completer = Completer<void>();
    final subscription = stream.listen(request.response.add,
        onError: (e, st) {}, onDone: completer.complete);

    request.response.done.then((dynamic value) {
      subscription.cancel();
    });

    await completer.future;

    await request.response.close();
  }

  return handler;
}

/// A proxy handler for serving audio from a URI with optional headers.
_ProxyHandler _proxyHandlerForUri(
  Uri uri, {
  Map<String, String>? headers,
  String? userAgent,
}) {
  // Keep redirected [Uri] to speed-up requests
  Uri? redirectedUri;
  Future<void> handler(_ProxyHttpServer server, HttpRequest request) async {
    final client = _createHttpClient(userAgent: userAgent);
    // Try to make normal request
    String? host;
    try {
      final requestHeaders = <String, String>{};
      request.headers
          .forEach((name, value) => requestHeaders[name] = value.join(', '));
      // write supplied headers last (to ensure supplied headers aren't overwritten)
      headers?.forEach((name, value) => requestHeaders[name] = value);
      final originRequest =
          await _getUrl(client, redirectedUri ?? uri, headers: requestHeaders);
      host = originRequest.headers.value(HttpHeaders.hostHeader);
      final originResponse = await originRequest.close();
      if (originResponse.redirects.isNotEmpty) {
        redirectedUri = originResponse.redirects.last.location;
      }

      request.response.headers.clear();
      originResponse.headers.forEach((name, value) {
        final filteredValue = value
            .map((e) => e.replaceAll(RegExp(r'[^\x09\x20-\x7F]'), '?'))
            .toList();
        request.response.headers.set(name, filteredValue);
      });
      request.response.statusCode = originResponse.statusCode;

      // Send response
      if (headers != null && request.uri.path.toLowerCase().endsWith('.m3u8') ||
          ['application/x-mpegURL', 'application/vnd.apple.mpegurl']
              .contains(request.headers.value(HttpHeaders.contentTypeHeader))) {
        // If this is an m3u8 file with headers, prepare the nested URIs.
        // TODO: Handle other playlist formats similarly?
        final m3u8 = await originResponse.transform(utf8.decoder).join();
        for (var line in const LineSplitter().convert(m3u8)) {
          line = line.replaceAllMapped(
              RegExp(r'#EXT-X-MEDIA:.*?URI="(.*?)".*'), (m) => m[1]!);
          line = line.replaceAll(RegExp(r'#.*$'), '').trim();
          if (line.isEmpty) continue;
          try {
            final rawNestedUri = Uri.parse(line);
            if (rawNestedUri.hasScheme) {
              // Don't propagate headers
              server.addUriAudioSource(AudioSource.uri(rawNestedUri));
            } else {
              // This is a resource on the same server, so propagate the headers.
              final basePath = rawNestedUri.path.startsWith('/')
                  ? ''
                  : uri.path.replaceAll(RegExp(r'/[^/]*$'), '/');
              final nestedUri =
                  uri.replace(path: '$basePath${rawNestedUri.path}');
              server.addUriAudioSource(
                  AudioSource.uri(nestedUri, headers: headers));
            }
          } catch (e) {
            // ignore malformed lines
          }
        }
        request.response.add(utf8.encode(m3u8));
      } else {
        request.response.bufferOutput = false;
        var done = false;
        request.response.done.then((dynamic _) => done = true);
        await for (var chunk in originResponse) {
          if (done) break;
          request.response.add(chunk);
          await request.response.flush();
        }
      }
      await request.response.flush();
      await request.response.close();
    } on HttpException {
      // We likely are dealing with a streaming protocol
      if (uri.scheme == 'http') {
        // Try parsing HTTP 0.9 response
        //request.response.headers.clear();
        final socket = await Socket.connect(uri.host, uri.port);
        final clientSocket =
            await request.response.detachSocket(writeHeaders: false);
        final done = Completer<dynamic>();
        socket.listen(
          clientSocket.add,
          onDone: () async {
            await clientSocket.flush();
            socket.close();
            clientSocket.close();
            done.complete();
          },
        );
        // Rewrite headers
        final headers = <String, String?>{};
        request.headers.forEach((name, value) {
          if (name.toLowerCase() != HttpHeaders.hostHeader) {
            headers[name] = value.join(",");
          }
        });
        for (var name in headers.keys) {
          headers[name] = headers[name];
        }
        socket.write("GET ${uri.path} HTTP/1.1\n");
        if (host != null) {
          socket.write("Host: $host\n");
        }
        for (var name in headers.keys) {
          socket.write("$name: ${headers[name]}\n");
        }
        socket.write("\n");
        await socket.flush();
        await done.future;
      }
    }
  }

  return handler;
}

Future<Directory> _getCacheDir() async =>
    Directory(p.join((await getTemporaryDirectory()).path, 'just_audio_cache'));

/// Defines the algorithm for shuffling the order of a playlist. See
/// [DefaultShuffleOrder] for a default implementation.
abstract class ShuffleOrder {
  /// The shuffled list of indices of [AudioSource]s to play. For example,
  /// [2,0,1] specifies to play the 3rd, then the 1st, then the 2nd item.
  List<int> get indices;

  /// Shuffles the [indices]. If specified, [initialIndex] will be the first
  /// item in the shuffle order.
  void shuffle({int? initialIndex});

  /// Inserts [count] new consecutive indices starting from [index] into
  /// [indices], at random positions.
  void insert(int index, int count);

  /// Removes the indices that are `>= start` and `< end`.
  void removeRange(int start, int end);

  /// Removes all indices.
  void clear();
}

/// The default implementation of [ShuffleOrder] which shuffles items with the
/// currently playing item at the head of the order.
class DefaultShuffleOrder extends ShuffleOrder {
  final Random _random;
  @override
  final indices = <int>[];

  DefaultShuffleOrder({Random? random}) : _random = random ?? Random();

  @override
  void shuffle({int? initialIndex}) {
    assert(initialIndex == null || indices.contains(initialIndex));
    if (indices.length <= 1) return;
    indices.shuffle(_random);
    if (initialIndex == null) return;

    const initialPos = 0;
    final swapPos = indices.indexOf(initialIndex);
    // Swap the indices at initialPos and swapPos.
    final swapIndex = indices[initialPos];
    indices[initialPos] = initialIndex;
    indices[swapPos] = swapIndex;
  }

  @override
  void insert(int index, int count) {
    // Offset indices after insertion point.
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) {
        indices[i] += count;
      }
    }
    // Insert new indices at random positions after currentIndex.
    final newIndices = List.generate(count, (i) => index + i);
    for (var newIndex in newIndices) {
      final insertionIndex = _random.nextInt(indices.length + 1);
      indices.insert(insertionIndex, newIndex);
    }
  }

  @override
  void removeRange(int start, int end) {
    final count = end - start;
    // Remove old indices.
    final oldIndices = List.generate(count, (i) => start + i).toSet();
    indices.removeWhere(oldIndices.contains);
    // Offset indices after deletion point.
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= end) {
        indices[i] -= count;
      }
    }
  }

  @override
  void clear() {
    indices.clear();
  }
}

/// An enumeration of modes that can be passed to [AudioPlayer.setLoopMode].
enum LoopMode { off, one, all }

/// Possible values that can be passed to [AudioPlayer.setWebCrossOrigin].
enum WebCrossOrigin { anonymous, useCredentials }

/// The stand-in platform implementation to use when the player is in the idle
/// state and the native platform is deallocated.
class _IdleAudioPlayer extends AudioPlayerPlatform {
  final _eventSubject = BehaviorSubject<PlaybackEventMessage>();
  Duration _position = Duration.zero;
  int? _index;
  List<IndexedAudioSource> _sequence = [];
  int? errorCode;
  String? errorMessage;
  StreamSubscription<List<IndexedAudioSource>>? _sequenceSubscription;

  /// Holds a pending request.
  SetAndroidAudioAttributesRequest? setAndroidAudioAttributesRequest;

  _IdleAudioPlayer({
    required String id,
    required Stream<List<IndexedAudioSource>> sequenceStream,
    required this.errorCode,
    required this.errorMessage,
  }) : super(id) {
    _sequenceSubscription =
        sequenceStream.listen((sequence) => _sequence = sequence);
  }

  void _broadcastPlaybackEvent() {
    var updateTime = DateTime.now();
    _eventSubject.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.idle,
      updatePosition: _position,
      updateTime: updateTime,
      bufferedPosition: Duration.zero,
      icyMetadata: null,
      duration: _getDurationAtIndex(_index),
      currentIndex: _index,
      androidAudioSessionId: null,
      errorCode: errorCode,
      errorMessage: errorMessage,
    ));
  }

  Duration? _getDurationAtIndex(int? index) =>
      index != null && index < _sequence.length
          ? _sequence[index].duration
          : null;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventSubject.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _index = request.initialIndex ?? 0;
    _position = request.initialPosition ?? Duration.zero;
    errorCode = null;
    errorMessage = null;
    _broadcastPlaybackEvent();
    return LoadResponse(duration: _getDurationAtIndex(_index));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    return SetSpeedResponse();
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    return SetPitchResponse();
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
      SetSkipSilenceRequest request) async {
    return SetSkipSilenceResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
      SetShuffleOrderRequest request) async {
    return SetShuffleOrderResponse();
  }

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
      SetWebCrossOriginRequest request) async {
    return SetWebCrossOriginResponse();
  }

  @override
  Future<SetWebSinkIdResponse> setWebSinkId(SetWebSinkIdRequest request) async {
    return SetWebSinkIdResponse();
  }

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async {
    return SetAutomaticallyWaitsToMinimizeStallingResponse();
  }

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
              request) async {
    return SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  }

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
      SetPreferredPeakBitRateRequest request) async {
    return SetPreferredPeakBitRateResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _position = request.position ?? Duration.zero;
    _index = request.index ?? _index;
    errorCode = null;
    errorMessage = null;
    _broadcastPlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
      SetAndroidAudioAttributesRequest request) async {
    setAndroidAudioAttributesRequest = request;
    return SetAndroidAudioAttributesResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    await _sequenceSubscription?.cancel();
    return DisposeResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    if (request.id == '') {
      if (_index == null) {
        if (request.children.isNotEmpty) {
          _index = 0;
          _broadcastPlaybackEvent();
        }
      } else {
        if (request.index <= _index!) {
          _index = _index! + request.children.length;
          _broadcastPlaybackEvent();
        }
      }
    }
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    if (request.id == '' && _index != null) {
      if (request.startIndex <= _index!) {
        _index = min(request.shuffleOrder.length - 1,
            _index! - (min(_index!, request.endIndex) - request.startIndex));
        if (_index! < 0) _index = null;
        _broadcastPlaybackEvent();
      }
    }
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
      ConcatenatingMoveRequest request) async {
    if (request.id == '' &&
        _index != null &&
        request.currentIndex != request.newIndex) {
      if (request.currentIndex == _index!) {
        _index = request.newIndex;
        _broadcastPlaybackEvent();
      } else if (request.currentIndex < _index! &&
          request.newIndex >= _index!) {
        _index = _index! - 1;
        _broadcastPlaybackEvent();
      } else if (request.currentIndex > _index! &&
          request.newIndex <= _index!) {
        _index = _index! + 1;
        _broadcastPlaybackEvent();
      }
    }
    return ConcatenatingMoveResponse();
  }

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(
      AudioEffectSetEnabledRequest request) async {
    return AudioEffectSetEnabledResponse();
  }

  @override
  Future<AndroidLoudnessEnhancerSetTargetGainResponse>
      androidLoudnessEnhancerSetTargetGain(
          AndroidLoudnessEnhancerSetTargetGainRequest request) async {
    return AndroidLoudnessEnhancerSetTargetGainResponse();
  }

  @override
  Future<AndroidEqualizerBandSetGainResponse> androidEqualizerBandSetGain(
      AndroidEqualizerBandSetGainRequest request) async {
    return AndroidEqualizerBandSetGainResponse();
  }

  @override
  Future<AndroidEqualizerGetParametersResponse> androidEqualizerGetParameters(
      AndroidEqualizerGetParametersRequest request) async {
    return AndroidEqualizerGetParametersResponse(
      parameters: AndroidEqualizerParametersMessage(
        minDecibels: 0.0,
        maxDecibels: 10.0,
        bands: [],
      ),
    );
  }

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(
      SetAllowsExternalPlaybackRequest request) async {
    return SetAllowsExternalPlaybackResponse();
  }
}

/// Encapsulates the arguments passed to the current invocation of
/// `AudioSource.setAudioSources`.
class _PluginLoadRequest {
  List<AudioSource> audioSources;
  bool preload;
  int? initialIndex;
  Duration? initialPosition;
  ShuffleOrder shuffleOrder;
  bool interrupted = false;

  _PluginLoadRequest({
    required this.audioSources,
    this.preload = true,
    this.initialIndex,
    this.initialPosition,
    required this.shuffleOrder,
  });

  _InitialSeekValues get initialSeekValues =>
      (index: initialIndex, position: initialPosition);

  void resetInitialSeekValues() {
    initialIndex = null;
    initialPosition = null;
  }

  void checkInterruption() {
    if (!interrupted) return;
    throw PlayerInterruptedException('Loading interrupted');
  }
}

/// Holds the initial requested position and index for a newly loaded audio
/// source.
typedef _InitialSeekValues = ({int? index, Duration? position});

/// THe pipeline of audio effects to be appliet to an [AudioPlayer].
class AudioPipeline {
  final List<AndroidAudioEffect> androidAudioEffects;
  final List<DarwinAudioEffect> darwinAudioEffects;

  AudioPipeline({
    List<AndroidAudioEffect>? androidAudioEffects,
    List<DarwinAudioEffect>? darwinAudioEffects,
  })  : assert(androidAudioEffects == null ||
            androidAudioEffects.toSet().length == androidAudioEffects.length),
        assert(darwinAudioEffects == null ||
            darwinAudioEffects.toSet().length == darwinAudioEffects.length),
        androidAudioEffects = androidAudioEffects ?? const [],
        darwinAudioEffects = darwinAudioEffects ?? const [];

  List<AudioEffect> get _audioEffects =>
      <AudioEffect>[...androidAudioEffects, ...darwinAudioEffects];

  void _setup(AudioPlayer player) {
    for (var effect in _audioEffects) {
      effect._setup(player);
    }
  }
}

/// Subclasses of [AudioEffect] can be inserted into an [AudioPipeline] to
/// modify the audio signal outputted by an [AudioPlayer]. The same audio effect
/// instance cannot be set on multiple players at the same time.
///
/// An [AudioEffect] is disabled by default. For an [AudioEffect] to take
/// effect, in addition to being part of an [AudioPipeline] attached to an
/// [AudioPlayer] you must also enable the effect via [setEnabled].
abstract class AudioEffect {
  AudioPlayer? _player;
  final _enabledSubject = BehaviorSubject.seeded(false);

  AudioEffect();

  /// Called when an [AudioEffect] is attached to an [AudioPlayer].
  void _setup(AudioPlayer player) {
    assert(_player == null);
    _player = player;
  }

  /// Called when [_player] is connected to the platform.
  Future<void> _activate(AudioPlayerPlatform platform) async {}

  /// Whether the effect is enabled. When `true`, and if the effect is part
  /// of an [AudioPipeline] attached to an [AudioPlayer], the effect will modify
  /// the audio player's output. When `false`, the audio pipeline will still
  /// reserve platform resources for the effect but the effect will be bypassed.
  bool get enabled => _enabledSubject.nvalue!;

  /// A stream of the current [enabled] value.
  Stream<bool> get enabledStream => _enabledSubject.stream;

  bool get _active => _player?._active ?? false;

  String get _type;

  /// Sets the [enabled] status of this audio effect.
  Future<void> setEnabled(bool enabled) async {
    _enabledSubject.add(enabled);
    if (_active) {
      await (await _player!._platform).audioEffectSetEnabled(
          AudioEffectSetEnabledRequest(type: _type, enabled: enabled));
    }
  }

  AudioEffectMessage _toMessage();
}

/// An [AudioEffect] that supports Android.
mixin AndroidAudioEffect on AudioEffect {}

/// An [AudioEffect] that supports iOS and macOS.
mixin DarwinAudioEffect on AudioEffect {}

/// An Android [AudioEffect] that boosts the volume of the audio signal to a
/// target gain, which defaults to zero.
class AndroidLoudnessEnhancer extends AudioEffect with AndroidAudioEffect {
  final _targetGainSubject = BehaviorSubject.seeded(0.0);

  @override
  String get _type => 'AndroidLoudnessEnhancer';

  /// The target gain in decibels.
  double get targetGain => _targetGainSubject.nvalue!;

  /// A stream of the current target gain in decibels.
  Stream<double> get targetGainStream => _targetGainSubject.stream;

  /// Sets the target gain to a value in decibels.
  Future<void> setTargetGain(double targetGain) async {
    _targetGainSubject.add(targetGain);
    if (_active) {
      await (await _player!._platform).androidLoudnessEnhancerSetTargetGain(
          AndroidLoudnessEnhancerSetTargetGainRequest(targetGain: targetGain));
    }
  }

  @override
  AudioEffectMessage _toMessage() => AndroidLoudnessEnhancerMessage(
        enabled: enabled,
        targetGain: targetGain,
      );
}

/// A frequency band within an [AndroidEqualizer].
class AndroidEqualizerBand {
  final AudioPlayer _player;

  /// A zero-based index of the position of this band within its [AndroidEqualizer].
  final int index;

  /// The lower frequency of this band in hertz.
  final double lowerFrequency;

  /// The upper frequency of this band in hertz.
  final double upperFrequency;

  /// The center frequency of this band in hertz.
  final double centerFrequency;
  final _gainSubject = BehaviorSubject<double>();

  AndroidEqualizerBand._({
    required AudioPlayer player,
    required this.index,
    required this.lowerFrequency,
    required this.upperFrequency,
    required this.centerFrequency,
    required double gain,
  }) : _player = player {
    _gainSubject.add(gain);
  }

  /// The gain for this band in decibels.
  double get gain => _gainSubject.nvalue!;

  /// A stream of the current gain for this band in decibels.
  Stream<double> get gainStream => _gainSubject.stream;

  /// Sets the gain for this band in decibels.
  Future<void> setGain(double gain) async {
    _gainSubject.add(gain);
    if (_player._active) {
      await (await _player._platform).androidEqualizerBandSetGain(
          AndroidEqualizerBandSetGainRequest(bandIndex: index, gain: gain));
    }
  }

  /// Restores the gain after reactivating.
  Future<void> _restore(AudioPlayerPlatform platform) async {
    await (platform).androidEqualizerBandSetGain(
        AndroidEqualizerBandSetGainRequest(bandIndex: index, gain: gain));
  }

  static AndroidEqualizerBand _fromMessage(
          AudioPlayer player, AndroidEqualizerBandMessage message) =>
      AndroidEqualizerBand._(
        player: player,
        index: message.index,
        lowerFrequency: message.lowerFrequency,
        upperFrequency: message.upperFrequency,
        centerFrequency: message.centerFrequency,
        gain: message.gain,
      );
}

/// The parameter values of an [AndroidEqualizer].
class AndroidEqualizerParameters {
  /// The minimum gain value supported by the equalizer.
  final double minDecibels;

  /// The maximum gain value supported by the equalizer.
  final double maxDecibels;

  /// The frequency bands of the equalizer.
  final List<AndroidEqualizerBand> bands;

  AndroidEqualizerParameters({
    required this.minDecibels,
    required this.maxDecibels,
    required this.bands,
  });

  /// Restores platform state after reactivating.
  Future<void> _restore(AudioPlayerPlatform platform) async {
    for (var band in bands) {
      await band._restore(platform);
    }
  }

  static AndroidEqualizerParameters _fromMessage(
          AudioPlayer player, AndroidEqualizerParametersMessage message) =>
      AndroidEqualizerParameters(
        minDecibels: message.minDecibels,
        maxDecibels: message.maxDecibels,
        bands: message.bands
            .map((bandMessage) =>
                AndroidEqualizerBand._fromMessage(player, bandMessage))
            .toList(),
      );
}

/// An [AudioEffect] for Android that can adjust the gain for different
/// frequency bands of an [AudioPlayer]'s audio signal.
class AndroidEqualizer extends AudioEffect with AndroidAudioEffect {
  final Completer<AndroidEqualizerParameters> _parametersCompleter =
      Completer<AndroidEqualizerParameters>();

  @override
  String get _type => 'AndroidEqualizer';

  @override
  Future<void> _activate(AudioPlayerPlatform platform) async {
    await super._activate(platform);
    if (_parametersCompleter.isCompleted) {
      await (await parameters)._restore(platform);
      return;
    }
    final response = await platform
        .androidEqualizerGetParameters(AndroidEqualizerGetParametersRequest());
    final receivedParameters =
        AndroidEqualizerParameters._fromMessage(_player!, response.parameters);
    _parametersCompleter.complete(receivedParameters);
  }

  /// The parameter values of this equalizer.
  Future<AndroidEqualizerParameters> get parameters =>
      _parametersCompleter.future;

  @override
  AudioEffectMessage _toMessage() => AndroidEqualizerMessage(
        enabled: enabled,
        // Parameters are only communicated from the platform.
        parameters: null,
      );
}

bool _isAndroid() => !kIsWeb && Platform.isAndroid;
bool _isDarwin() => !kIsWeb && (Platform.isIOS || Platform.isMacOS);
bool _isUnitTest() => !kIsWeb && Platform.environment['FLUTTER_TEST'] == 'true';

/// Backwards compatible extensions on rxdart's ValueStream
extension _ValueStreamExtension<T> on ValueStream<T> {
  /// Backwards compatible version of valueOrNull.
  T? get nvalue => hasValue ? value : null;
}

/// Information collected when a position discontinuity occurs.
class PositionDiscontinuity {
  /// The reason for the position discontinuity.
  final PositionDiscontinuityReason reason;

  /// The previous event before the position discontinuity.
  final PlaybackEvent previousEvent;

  /// The event that caused the position discontinuity.
  final PlaybackEvent event;

  const PositionDiscontinuity(this.reason, this.previousEvent, this.event);
}

/// The reasons for position discontinuities.
enum PositionDiscontinuityReason {
  /// The position discontinuity was initiated by a seek.
  seek,

  /// The position discontinuity occurred because the player reached the end of
  /// the current item and auto-advanced to the next item.
  autoAdvance,
}

Future<HttpClientRequest> _getUrl(HttpClient client, Uri uri,
    {Map<String, String>? headers}) async {
  final request = await client.getUrl(uri);
  if (headers != null) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    request.headers.clear();
    request.headers.set(HttpHeaders.contentLengthHeader, '0');
    headers.forEach((name, value) => request.headers.set(name, value));
    if (host != null) {
      request.headers.set(HttpHeaders.hostHeader, host);
    }
    if (client.userAgent != null) {
      request.headers.set(HttpHeaders.userAgentHeader, client.userAgent!);
    }
  }
  // Match ExoPlayer's native behavior
  request.maxRedirects = 20;
  return request;
}

HttpClient _createHttpClient({String? userAgent}) {
  final client = HttpClient();
  if (userAgent != null) {
    client.userAgent = userAgent;
  }
  return client;
}
