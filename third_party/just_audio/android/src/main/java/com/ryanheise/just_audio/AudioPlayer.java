package com.ryanheise.just_audio;

import android.content.Context;
import android.media.audiofx.AudioEffect;
import android.media.audiofx.Equalizer;
import android.media.audiofx.LoudnessEnhancer;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.C;
import androidx.media3.exoplayer.DefaultLivePlaybackSpeedControl;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.LivePlaybackSpeedControl;
import androidx.media3.exoplayer.LoadControl;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.Player;
import androidx.media3.common.Player.PositionInfo;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.common.Timeline;
import androidx.media3.common.Tracks;
import androidx.media3.common.TrackSelectionParameters;
import androidx.media3.common.TrackSelectionParameters.AudioOffloadPreferences;
import androidx.media3.common.AudioAttributes;
import androidx.media3.exoplayer.NoSampleRenderer;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.RenderersFactory;
import androidx.media3.extractor.DefaultExtractorsFactory;
import androidx.media3.common.Metadata;
import androidx.media3.exoplayer.metadata.MetadataOutput;
import androidx.media3.extractor.metadata.icy.IcyHeaders;
import androidx.media3.extractor.metadata.icy.IcyInfo;
import androidx.media3.exoplayer.source.ClippingMediaSource; // Deprecated
// For some reason, this import triggers the [deprecation] warning, despite the
// warnings being suppressed at each use.
// import androidx.media3.exoplayer.source.ConcatenatingMediaSource; // Deprecated
import androidx.media3.exoplayer.source.MediaSource; // Deprecated
import androidx.media3.exoplayer.source.ProgressiveMediaSource; // Deprecated
import androidx.media3.exoplayer.source.ShuffleOrder;
import androidx.media3.exoplayer.source.ShuffleOrder.DefaultShuffleOrder;
import androidx.media3.exoplayer.source.SilenceMediaSource; // Deprecated
import androidx.media3.common.TrackGroup;
import androidx.media3.exoplayer.dash.DashMediaSource; // Deprecated
import androidx.media3.exoplayer.hls.HlsMediaSource; // Deprecated
import androidx.media3.exoplayer.trackselection.TrackSelectionArray;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.Util;
import io.flutter.Log;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.EventChannel.EventSink;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Random;

public class AudioPlayer implements MethodCallHandler, Player.Listener, MetadataOutput {
    public static final int ERROR_ABORT = 10000000;

    static final String TAG = "AudioPlayer";

    private static Random random = new Random();

    private final Context context;
    private final MethodChannel methodChannel;
    private final BetterEventChannel eventChannel;
    private final BetterEventChannel dataEventChannel;

    private ProcessingState processingState;
    private long updatePosition;
    private long updateTime;
    private long bufferedPosition;
    private Long seekPos;
    private Result prepareResult;
    private Result playResult;
    private Result seekResult;
    private Map<String, MediaSource> mediaSources = new HashMap<String, MediaSource>();
    private IcyInfo icyInfo;
    private IcyHeaders icyHeaders;
    private AudioAttributes pendingAudioAttributes;
    private LoadControl loadControl;
    private boolean offloadSchedulingEnabled;
    private AudioOffloadPreferences audioOffloadPreferences;
    private boolean useLazyPreparation;
    private LivePlaybackSpeedControl livePlaybackSpeedControl;
    private List<Object> rawAudioEffects;
    private List<AudioEffect> audioEffects = new ArrayList<AudioEffect>();
    private Map<String, AudioEffect> audioEffectsMap = new HashMap<String, AudioEffect>();
    private int lastPlaylistLength = 0;
    private Map<String, Object> pendingPlaybackEvent;

    private ExoPlayer player;
    private Integer audioSessionId;
    private Integer errorCode;
    private String errorMessage;
    private Integer currentIndex;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable bufferWatcher = new Runnable() {
        @Override
        public void run() {
            if (player == null) {
                return;
            }

            long newBufferedPosition = player.getBufferedPosition();
            if (newBufferedPosition != bufferedPosition) {
                // This method updates bufferedPosition.
                broadcastImmediatePlaybackEvent();
            }
            switch (player.getPlaybackState()) {
            case Player.STATE_BUFFERING:
                handler.postDelayed(this, 200);
                break;
            case Player.STATE_READY:
                if (player.getPlayWhenReady()) {
                    handler.postDelayed(this, 500);
                } else {
                    handler.postDelayed(this, 1000);
                }
                break;
            default:
                // Stop watching buffer
            }
        }
    };

    public AudioPlayer(
        final Context applicationContext,
        final BinaryMessenger messenger,
        final String id,
        Map<?, ?> audioLoadConfiguration,
        List<Object> rawAudioEffects,
        Map<?, ?> audioOffloadPreferences,
        Boolean offloadSchedulingEnabled,
        boolean useLazyPreparation
    ) {
        this.context = applicationContext;
        this.rawAudioEffects = rawAudioEffects;
        this.offloadSchedulingEnabled = offloadSchedulingEnabled != null ? offloadSchedulingEnabled : false;
        this.useLazyPreparation = useLazyPreparation;

        if (audioOffloadPreferences != null) {
            this.audioOffloadPreferences = new AudioOffloadPreferences.Builder()
                .setIsGaplessSupportRequired((Boolean)audioOffloadPreferences.get("isGaplessSupportRequired"))
                .setIsSpeedChangeSupportRequired((Boolean)audioOffloadPreferences.get("isSpeedChangeSupportRequired"))
                .setAudioOffloadMode((Integer)audioOffloadPreferences.get("audioOffloadMode"))
                .build();
        } else {
            final int offloadMode = offloadSchedulingEnabled
                ? AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_ENABLED
                : AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_DISABLED;
            this.audioOffloadPreferences = new AudioOffloadPreferences.Builder()
                .setIsGaplessSupportRequired(!offloadSchedulingEnabled)
                .setIsSpeedChangeSupportRequired(!offloadSchedulingEnabled)
                .setAudioOffloadMode(offloadMode)
                .build();
        }

        methodChannel = new MethodChannel(messenger, "com.ryanheise.just_audio.methods." + id);
        methodChannel.setMethodCallHandler(this);
        eventChannel = new BetterEventChannel(messenger, "com.ryanheise.just_audio.events." + id);
        dataEventChannel = new BetterEventChannel(messenger, "com.ryanheise.just_audio.data." + id);
        processingState = ProcessingState.idle;
        if (audioLoadConfiguration != null) {
            Map<?, ?> loadControlMap = (Map<?, ?>)audioLoadConfiguration.get("androidLoadControl");
            if (loadControlMap != null) {
                DefaultLoadControl.Builder builder = new DefaultLoadControl.Builder()
                    .setBufferDurationsMs(
                        (int)((getLong(loadControlMap.get("minBufferDuration")))/1000),
                        (int)((getLong(loadControlMap.get("maxBufferDuration")))/1000),
                        (int)((getLong(loadControlMap.get("bufferForPlaybackDuration")))/1000),
                        (int)((getLong(loadControlMap.get("bufferForPlaybackAfterRebufferDuration")))/1000)
                    )
                    .setPrioritizeTimeOverSizeThresholds((Boolean)loadControlMap.get("prioritizeTimeOverSizeThresholds"))
                    .setBackBuffer((int)((getLong(loadControlMap.get("backBufferDuration")))/1000), false);
                if (loadControlMap.get("targetBufferBytes") != null) {
                    builder.setTargetBufferBytes((Integer)loadControlMap.get("targetBufferBytes"));
                }
                loadControl = builder.build();
            }
            Map<?, ?> livePlaybackSpeedControlMap = (Map<?, ?>)audioLoadConfiguration.get("androidLivePlaybackSpeedControl");
            if (livePlaybackSpeedControlMap != null) {
                DefaultLivePlaybackSpeedControl.Builder builder = new DefaultLivePlaybackSpeedControl.Builder()
                    .setFallbackMinPlaybackSpeed((float)((double)((Double)livePlaybackSpeedControlMap.get("fallbackMinPlaybackSpeed"))))
                    .setFallbackMaxPlaybackSpeed((float)((double)((Double)livePlaybackSpeedControlMap.get("fallbackMaxPlaybackSpeed"))))
                    .setMinUpdateIntervalMs(((getLong(livePlaybackSpeedControlMap.get("minUpdateInterval")))/1000))
                    .setProportionalControlFactor((float)((double)((Double)livePlaybackSpeedControlMap.get("proportionalControlFactor"))))
                    .setMaxLiveOffsetErrorMsForUnitSpeed(((getLong(livePlaybackSpeedControlMap.get("maxLiveOffsetErrorForUnitSpeed")))/1000))
                    .setTargetLiveOffsetIncrementOnRebufferMs(((getLong(livePlaybackSpeedControlMap.get("targetLiveOffsetIncrementOnRebuffer")))/1000))
                    .setMinPossibleLiveOffsetSmoothingFactor((float)((double)((Double)livePlaybackSpeedControlMap.get("minPossibleLiveOffsetSmoothingFactor"))));
                livePlaybackSpeedControl = builder.build();
            }
        }
    }

    private void startWatchingBuffer() {
        handler.removeCallbacks(bufferWatcher);
        handler.post(bufferWatcher);
    }

    private void setAudioSessionId(int audioSessionId) {
        if (audioSessionId == C.AUDIO_SESSION_ID_UNSET) {
            this.audioSessionId = null;
        } else {
            this.audioSessionId = audioSessionId;
        }
        clearAudioEffects();
        if (this.audioSessionId != null) {
            for (Object rawAudioEffect : rawAudioEffects) {
                Map<?, ?> json = (Map<?, ?>)rawAudioEffect;
                AudioEffect audioEffect = decodeAudioEffect(rawAudioEffect, this.audioSessionId);
                if ((Boolean)json.get("enabled")) {
                    audioEffect.setEnabled(true);
                }
                audioEffects.add(audioEffect);
                audioEffectsMap.put((String)json.get("type"), audioEffect);
            }
        }
        enqueuePlaybackEvent();
    }

    @Override
    public void onAudioSessionIdChanged(int audioSessionId) {
        setAudioSessionId(audioSessionId);
        broadcastPendingPlaybackEvent();
    }

    @Override
    public void onMetadata(Metadata metadata) {
        for (int i = 0; i < metadata.length(); i++) {
            final Metadata.Entry entry = metadata.get(i);
            if (entry instanceof IcyInfo) {
                icyInfo = (IcyInfo) entry;
                broadcastImmediatePlaybackEvent();
            }
        }
    }

    @Override
    public void onTracksChanged(Tracks tracks) {
        for (int i = 0; i < tracks.getGroups().size(); i++) {
            TrackGroup trackGroup = tracks.getGroups().get(i).getMediaTrackGroup();

            for (int j = 0; j < trackGroup.length; j++) {
                Metadata metadata = trackGroup.getFormat(j).metadata;

                if (metadata != null) {
                    for (int k = 0; k < metadata.length(); k++) {
                        final Metadata.Entry entry = metadata.get(k);
                        if (entry instanceof IcyHeaders) {
                            icyHeaders = (IcyHeaders) entry;
                            broadcastImmediatePlaybackEvent();
                        }
                    }
                }
            }
        }
    }

    private boolean updatePositionIfChanged() {
        if (player == null) return false;
        if (!player.getPlayWhenReady() || processingState != ProcessingState.ready) {
            if (getCurrentPosition() == updatePosition) return false;
        }
        updatePosition = getCurrentPosition();
        updateTime = System.currentTimeMillis();
        return true;
    }

    private void updatePosition() {
        updatePosition = getCurrentPosition();
        updateTime = System.currentTimeMillis();
    }

    @Override
    public void onPositionDiscontinuity(PositionInfo oldPosition, PositionInfo newPosition, int reason) {
        updatePosition();
        switch (reason) {
        case Player.DISCONTINUITY_REASON_AUTO_TRANSITION:
        case Player.DISCONTINUITY_REASON_SEEK:
            updateCurrentIndex();
            break;
        }
        broadcastImmediatePlaybackEvent();
    }

    @Override
    public void onTimelineChanged(Timeline timeline, int reason) {
        if (updateCurrentIndex()) {
            broadcastImmediatePlaybackEvent();
        }
        if (player.getPlaybackState() == Player.STATE_ENDED) {
            try {
                if (player.getPlayWhenReady()) {
                    if (lastPlaylistLength == 0 && player.getMediaItemCount() > 0) {
                        player.seekTo(0, 0L);
                    } else if (player.hasNextMediaItem()) {
                        player.seekToNextMediaItem();
                    }
                } else {
                    if (player.getCurrentMediaItemIndex() < player.getMediaItemCount()) {
                        player.seekTo(player.getCurrentMediaItemIndex(), 0L);
                    }
                }
            } catch (Exception e) {
                e.printStackTrace();
            }
        }
        lastPlaylistLength = player.getMediaItemCount();
    }

    private boolean updateCurrentIndex() {
        Integer newIndex = player.getCurrentMediaItemIndex();
        // newIndex is never null.
        // currentIndex is sometimes null.
        if (!newIndex.equals(currentIndex)) {
            currentIndex = newIndex;
            return true;
        }
        return false;
    }

    @Override
    public void onPlaybackStateChanged(int playbackState) {
        switch (playbackState) {
        case Player.STATE_READY:
            if (player.getPlayWhenReady())
                updatePosition();
            processingState = ProcessingState.ready;
            errorCode = null;
            errorMessage = null;
            broadcastImmediatePlaybackEvent();
            if (prepareResult != null) {
                Map<String, Object> response = new HashMap<>();
                response.put("duration", getDuration() == C.TIME_UNSET ? null : (1000 * getDuration()));
                prepareResult.success(response);
                prepareResult = null;
                if (pendingAudioAttributes != null) {
                    player.setAudioAttributes(pendingAudioAttributes, false);
                    pendingAudioAttributes = null;
                }
            }
            if (seekResult != null) {
                completeSeek();
            }
            break;
        case Player.STATE_BUFFERING:
            updatePositionIfChanged();
            if (processingState != ProcessingState.buffering && processingState != ProcessingState.loading) {
                processingState = ProcessingState.buffering;
                errorCode = null;
                errorMessage = null;
                broadcastImmediatePlaybackEvent();
            }
            startWatchingBuffer();
            break;
        case Player.STATE_ENDED:
            if (processingState != ProcessingState.completed) {
                updatePosition();
                processingState = ProcessingState.completed;
                errorCode = null;
                errorMessage = null;
                broadcastImmediatePlaybackEvent();
            }
            if (prepareResult != null) {
                Map<String, Object> response = new HashMap<>();
                response.put("duration", getDuration() == C.TIME_UNSET ? null : (1000 * getDuration()));
                prepareResult.success(response);
                prepareResult = null;
                if (pendingAudioAttributes != null) {
                    player.setAudioAttributes(pendingAudioAttributes, false);
                    pendingAudioAttributes = null;
                }
            }
            if (playResult != null) {
                playResult.success(new HashMap<String, Object>());
                playResult = null;
            }
            break;
        }
    }

    @Override
    public void onPlayerError(PlaybackException error) {
        if (error instanceof ExoPlaybackException) {
            final ExoPlaybackException exoError = (ExoPlaybackException)error;
            switch (exoError.type) {
            case ExoPlaybackException.TYPE_SOURCE:
                Log.e(TAG, "TYPE_SOURCE: " + exoError.getSourceException().getMessage());
                break;

            case ExoPlaybackException.TYPE_RENDERER:
                Log.e(TAG, "TYPE_RENDERER: " + exoError.getRendererException().getMessage());
                break;

            case ExoPlaybackException.TYPE_UNEXPECTED:
                Log.e(TAG, "TYPE_UNEXPECTED: " + exoError.getUnexpectedException().getMessage());
                break;

            default:
                Log.e(TAG, "default ExoPlaybackException: " + exoError.getUnexpectedException().getMessage());
            }
            // TODO: send both errorCode and type
            sendError(exoError.type, exoError.getMessage(), mapOf("index", currentIndex));
        } else {
            Log.e(TAG, "default PlaybackException: " + error.getMessage());
            sendError(error.errorCode, error.getMessage(), mapOf("index", currentIndex));
        }
    }

    private void completeSeek() {
        seekPos = null;
        seekResult.success(new HashMap<String, Object>());
        seekResult = null;
    }

    @Override
    public void onMethodCall(final MethodCall call, final Result result) {
        ensurePlayerInitialized();

        try {
            switch (call.method) {
            case "load":
                Long initialPosition = getLong(call.argument("initialPosition"));
                Integer initialIndex = call.argument("initialIndex");
                Map<?, ?> audioSourceMap = call.argument("audioSource");
                MediaSource[] children = getAudioSourcesArray(audioSourceMap.get("children"));
                ShuffleOrder shuffleOrder = decodeShuffleOrder(mapGet(audioSourceMap, "shuffleOrder"));
                load(Arrays.asList(children), shuffleOrder,
                        initialPosition == null ? C.TIME_UNSET : initialPosition / 1000,
                        initialIndex, result);
                break;
            case "play":
                play(result);
                break;
            case "pause":
                pause();
                result.success(new HashMap<String, Object>());
                break;
            case "setVolume":
                setVolume((float) ((double) ((Double) call.argument("volume"))));
                result.success(new HashMap<String, Object>());
                break;
            case "setSpeed":
                setSpeed((float) ((double) ((Double) call.argument("speed"))));
                result.success(new HashMap<String, Object>());
                break;
            case "setPitch":
                setPitch((float) ((double) ((Double) call.argument("pitch"))));
                result.success(new HashMap<String, Object>());
                break;
            case "setSkipSilence":
                setSkipSilenceEnabled((Boolean) call.argument("enabled"));
                result.success(new HashMap<String, Object>());
                break;
            case "setLoopMode":
                setLoopMode((Integer) call.argument("loopMode"));
                result.success(new HashMap<String, Object>());
                break;
            case "setShuffleMode":
                setShuffleModeEnabled((Integer) call.argument("shuffleMode") == 1);
                result.success(new HashMap<String, Object>());
                break;
            case "setShuffleOrder":
                setShuffleOrder(call.argument("audioSource"));
                result.success(new HashMap<String, Object>());
                break;
            case "setAutomaticallyWaitsToMinimizeStalling":
                result.success(new HashMap<String, Object>());
                break;
            case "setCanUseNetworkResourcesForLiveStreamingWhilePaused":
                result.success(new HashMap<String, Object>());
                break;
            case "setPreferredPeakBitRate":
                result.success(new HashMap<String, Object>());
                break;
            case "seek":
                Long position = getLong(call.argument("position"));
                Integer index = call.argument("index");
                seek(position == null ? C.TIME_UNSET : position / 1000, index, result);
                break;
            case "concatenatingInsertAll":
                if (((String)call.argument("id")).length() == 0) {
                    player.addMediaSources(call.argument("index"), getAudioSources(call.argument("children"))); 
                    player.setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                    result.success(new HashMap<String, Object>());
                } else {
                    concatenating(call.argument("id"))
                        .addMediaSources(call.argument("index"), getAudioSources(call.argument("children")), handler, () -> result.success(new HashMap<String, Object>()));
                    concatenating(call.argument("id"))
                        .setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                }
                break;
            case "concatenatingRemoveRange":
                if (((String)call.argument("id")).length() == 0) {
                    player.removeMediaItems(call.argument("startIndex"), call.argument("endIndex"));
                    player.setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                    result.success(new HashMap<String, Object>());
                } else {
                    concatenating(call.argument("id"))
                        .removeMediaSourceRange(call.argument("startIndex"), call.argument("endIndex"), handler, () -> result.success(new HashMap<String, Object>()));
                    concatenating(call.argument("id"))
                        .setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                }
                break;
            case "concatenatingMove":
                if (((String)call.argument("id")).length() == 0) {
                    player.moveMediaItem(call.argument("currentIndex"), call.argument("newIndex"));
                    player.setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                    result.success(new HashMap<String, Object>());
                } else {
                    concatenating(call.argument("id"))
                        .moveMediaSource(call.argument("currentIndex"), call.argument("newIndex"), handler, () -> result.success(new HashMap<String, Object>()));
                    concatenating(call.argument("id"))
                        .setShuffleOrder(decodeShuffleOrder(call.argument("shuffleOrder")));
                }
                break;
            case "setAndroidAudioAttributes":
                setAudioAttributes(call.argument("contentType"), call.argument("flags"), call.argument("usage"));
                result.success(new HashMap<String, Object>());
                break;
            case "audioEffectSetEnabled":
                audioEffectSetEnabled(call.argument("type"), call.argument("enabled"));
                result.success(new HashMap<String, Object>());
                break;
            case "androidLoudnessEnhancerSetTargetGain":
                loudnessEnhancerSetTargetGain(call.argument("targetGain"));
                result.success(new HashMap<String, Object>());
                break;
            case "androidEqualizerGetParameters":
                result.success(equalizerAudioEffectGetParameters());
                break;
            case "androidEqualizerBandSetGain":
                equalizerBandSetGain(call.argument("bandIndex"), call.argument("gain"));
                result.success(new HashMap<String, Object>());
                break;
            default:
                result.notImplemented();
                break;
            }
        } catch (IllegalStateException e) {
            e.printStackTrace();
            result.error("Illegal state: " + e.getMessage(), e.toString(), null);
        } catch (Exception e) {
            e.printStackTrace();
            result.error("Error: " + e, e.toString(), null);
        } finally {
            broadcastPendingPlaybackEvent();
        }
    }

    private ShuffleOrder decodeShuffleOrder(List<Integer> indexList) {
        int[] shuffleIndices = new int[indexList.size()];
        for (int i = 0; i < shuffleIndices.length; i++) {
            shuffleIndices[i] = indexList.get(i);
        }
        return new DefaultShuffleOrder(shuffleIndices, random.nextLong());
    }

    @SuppressWarnings("deprecation")
    private androidx.media3.exoplayer.source.ConcatenatingMediaSource concatenating(final Object index) {
        return (androidx.media3.exoplayer.source.ConcatenatingMediaSource)mediaSources.get((String)index);
    }

    @SuppressWarnings("deprecation")
    private void setShuffleOrder(final Object json) {
        Map<?, ?> map = (Map<?, ?>)json;
        String id = mapGet(map, "id");
        MediaSource mediaSource = mediaSources.get(id);
        if (mediaSource == null) return;
        switch ((String)mapGet(map, "type")) {
        case "concatenating":
            androidx.media3.exoplayer.source.ConcatenatingMediaSource concatenatingMediaSource = (androidx.media3.exoplayer.source.ConcatenatingMediaSource)mediaSource;
            concatenatingMediaSource.setShuffleOrder(decodeShuffleOrder(mapGet(map, "shuffleOrder")));
            List<Object> children = mapGet(map, "children");
            for (Object child : children) {
                setShuffleOrder(child);
            }
            break;
        case "looping":
            setShuffleOrder(mapGet(map, "child"));
            break;
        }
    }

    private MediaSource getAudioSource(final Object json) {
        Map<?, ?> map = (Map<?, ?>)json;
        String id = (String)map.get("id");
        MediaSource mediaSource = mediaSources.get(id);
        if (mediaSource == null) {
            mediaSource = decodeAudioSource(map);
            mediaSources.put(id, mediaSource);
        }
        return mediaSource;
    }

    private DefaultExtractorsFactory buildExtractorsFactory(Map<?, ?> options) {
        DefaultExtractorsFactory extractorsFactory = new DefaultExtractorsFactory();
        boolean constantBitrateSeekingEnabled = true;
        boolean constantBitrateSeekingAlwaysEnabled = false;
        int mp3Flags = 0;
        if (options != null) {
            Map<?, ?> androidExtractorOptions = (Map<?, ?>)options.get("androidExtractorOptions");
            if (androidExtractorOptions != null) {
                constantBitrateSeekingEnabled = (Boolean)androidExtractorOptions.get("constantBitrateSeekingEnabled");
                constantBitrateSeekingAlwaysEnabled = (Boolean)androidExtractorOptions.get("constantBitrateSeekingAlwaysEnabled");
                mp3Flags = (Integer)androidExtractorOptions.get("mp3Flags");
            }
        }
        extractorsFactory.setConstantBitrateSeekingEnabled(constantBitrateSeekingEnabled);
        extractorsFactory.setConstantBitrateSeekingAlwaysEnabled(constantBitrateSeekingAlwaysEnabled);
        extractorsFactory.setMp3ExtractorFlags(mp3Flags);
        return extractorsFactory;
    }

    @SuppressWarnings("deprecation")
    private MediaSource decodeAudioSource(final Object json) {
        Map<?, ?> map = (Map<?, ?>)json;
        String id = (String)map.get("id");
        switch ((String)map.get("type")) {
        case "progressive":
            return new ProgressiveMediaSource.Factory(buildDataSourceFactory(mapGet(map, "headers")), buildExtractorsFactory(mapGet(map, "options")))
                    .createMediaSource(new MediaItem.Builder()
                            .setUri(Uri.parse((String)map.get("uri")))
                            .setTag(id)
                            .build());
        case "dash":
            return new DashMediaSource.Factory(buildDataSourceFactory(mapGet(map, "headers")))
                    .createMediaSource(new MediaItem.Builder()
                            .setUri(Uri.parse((String)map.get("uri")))
                            .setMimeType(MimeTypes.APPLICATION_MPD)
                            .setTag(id)
                            .build());
        case "hls":
            return new HlsMediaSource.Factory(buildDataSourceFactory(mapGet(map, "headers")))
                    .createMediaSource(new MediaItem.Builder()
                            .setUri(Uri.parse((String)map.get("uri")))
                            .setMimeType(MimeTypes.APPLICATION_M3U8)
                            .build());
        case "silence":
            return new SilenceMediaSource.Factory()
                    .setDurationUs(getLong(map.get("duration")))
                    .setTag(id)
                    .createMediaSource();
        case "concatenating":
            return new androidx.media3.exoplayer.source.ConcatenatingMediaSource(
                    false, // isAtomic
                    (Boolean)map.get("useLazyPreparation"),
                    decodeShuffleOrder(mapGet(map, "shuffleOrder")),
                    getAudioSourcesArray(map.get("children")));
        case "clipping":
            Long start = getLong(map.get("start"));
            Long end = getLong(map.get("end"));
            return new ClippingMediaSource(getAudioSource(map.get("child")),
                    start != null ? start : 0,
                    end != null ? end : C.TIME_END_OF_SOURCE);
        case "looping":
            Integer count = (Integer)map.get("count");
            MediaSource looperChild = getAudioSource(map.get("child"));
            MediaSource[] looperChildren = new MediaSource[count];
            for (int i = 0; i < looperChildren.length; i++) {
                looperChildren[i] = looperChild;
            }
            return new androidx.media3.exoplayer.source.ConcatenatingMediaSource(looperChildren);
        default:
            throw new IllegalArgumentException("Unknown AudioSource type: " + map.get("type"));
        }
    }

    private MediaSource[] getAudioSourcesArray(final Object json) {
        List<MediaSource> mediaSources = getAudioSources(json);
        MediaSource[] mediaSourcesArray = new MediaSource[mediaSources.size()];
        mediaSources.toArray(mediaSourcesArray);
        return mediaSourcesArray;
    }

    private List<MediaSource> getAudioSources(final Object json) {
        if (!(json instanceof List)) throw new RuntimeException("List expected: " + json);
        List<?> audioSources = (List<?>)json;
        List<MediaSource> mediaSources = new ArrayList<MediaSource>();
        for (int i = 0 ; i < audioSources.size(); i++) {
            mediaSources.add(getAudioSource(audioSources.get(i)));
        }
        return mediaSources;
    }

    private AudioEffect decodeAudioEffect(final Object json, int audioSessionId) {
        Map<?, ?> map = (Map<?, ?>)json;
        String type = (String)map.get("type");
        switch (type) {
        case "AndroidLoudnessEnhancer":
            if (Build.VERSION.SDK_INT < 19)
                throw new RuntimeException("AndroidLoudnessEnhancer requires minSdkVersion >= 19");
            int targetGain = (int)Math.round((((Double)map.get("targetGain")) * 100.0)); // target gain needs to be provided in milliBel, the user provides the value in deciBel
            LoudnessEnhancer loudnessEnhancer = new LoudnessEnhancer(audioSessionId);
            loudnessEnhancer.setTargetGain(targetGain);
            return loudnessEnhancer;
        case "AndroidEqualizer":
            Equalizer equalizer = new Equalizer(0, audioSessionId);
            return equalizer;
        default:
            throw new IllegalArgumentException("Unknown AudioEffect type: " + map.get("type"));
        }
    }

    private void clearAudioEffects() {
        for (Iterator<AudioEffect> it = audioEffects.iterator(); it.hasNext();) {
            AudioEffect audioEffect = it.next();
            audioEffect.release();
            it.remove();
        }
        audioEffectsMap.clear();
    }

    private DataSource.Factory buildDataSourceFactory(Map<?, ?> headers) {
        final Map<String, String> stringHeaders = castToStringMap(headers);
        String userAgent = null;
        if (stringHeaders != null) {
            userAgent = stringHeaders.remove("User-Agent");
            if (userAgent == null) {
                userAgent = stringHeaders.remove("user-agent");
            }
        }
        if (userAgent == null) {
            userAgent = Util.getUserAgent(context, "just_audio");
        }
        DefaultHttpDataSource.Factory httpDataSourceFactory = new DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setAllowCrossProtocolRedirects(true);
        if (stringHeaders != null && stringHeaders.size() > 0) {
            httpDataSourceFactory.setDefaultRequestProperties(stringHeaders);
        }
        return new DefaultDataSource.Factory(context, httpDataSourceFactory);
    }

    private void load(final List<MediaSource> mediaSources, ShuffleOrder shuffleOrder, final long initialPosition, final Integer initialIndex, final Result result) {
        currentIndex = initialIndex != null ? initialIndex : 0;
        switch (processingState) {
        case idle:
            break;
        case loading:
            abortExistingConnection(false);
            player.stop();
            break;
        default:
            player.stop();
            break;
        }
        prepareResult = result;
        updatePosition();
        processingState = ProcessingState.loading;
        errorCode = null;
        errorMessage = null;
        enqueuePlaybackEvent();
        int windowIndex = initialIndex != null ? initialIndex : 0;
        player.setMediaSources(mediaSources, windowIndex, initialPosition);
        player.setShuffleOrder(shuffleOrder);
        player.prepare();
    }

    private void ensurePlayerInitialized() {
        if (player == null) {
            RenderersFactory renderersFactory = (eventHandler, videoListener, audioListener, textOutput, metadataOutput) -> {
                Renderer[] defaultRenderers = new DefaultRenderersFactory(context)
                    .createRenderers(eventHandler, videoListener, audioListener, textOutput, metadataOutput);
                Renderer[] allRenderers = Arrays.copyOf(defaultRenderers, defaultRenderers.length + 1);
                allRenderers[defaultRenderers.length] = new ObserverRenderer();
                return allRenderers;
            };
            ExoPlayer.Builder builder = new ExoPlayer.Builder(context, renderersFactory);
            builder.setUseLazyPreparation(useLazyPreparation);
            if (loadControl != null) {
                builder.setLoadControl(loadControl);
            }
            if (livePlaybackSpeedControl != null) {
                builder.setLivePlaybackSpeedControl(livePlaybackSpeedControl);
            }
            player = builder.build();
            player.setTrackSelectionParameters(
                player.getTrackSelectionParameters()
                    .buildUpon()
                    .setAudioOffloadPreferences(audioOffloadPreferences)
                    .build()
            );
            setAudioSessionId(player.getAudioSessionId());
            player.addListener(this);
        }
    }

    private void setAudioAttributes(int contentType, int flags, int usage) {
        AudioAttributes.Builder builder = new AudioAttributes.Builder();
        builder.setContentType(contentType);
        builder.setFlags(flags);
        builder.setUsage(usage);
        //builder.setAllowedCapturePolicy((Integer)json.get("allowedCapturePolicy"));
        AudioAttributes audioAttributes = builder.build();
        if (processingState == ProcessingState.loading) {
            // audio attributes should be set either before or after loading to
            // avoid an ExoPlayer glitch.
            pendingAudioAttributes = audioAttributes;
        } else {
            player.setAudioAttributes(audioAttributes, false);
        }
    }

    private void audioEffectSetEnabled(String type, boolean enabled) {
        audioEffectsMap.get(type).setEnabled(enabled);
    }

    private void loudnessEnhancerSetTargetGain(double targetGain) {
        int targetGainMillibels = (int)Math.round(targetGain * 100.0); // target gain needs to be provided in milliBel, the user provides the value in deciBel
        ((LoudnessEnhancer)audioEffectsMap.get("AndroidLoudnessEnhancer")).setTargetGain(targetGainMillibels);
    }

    private Map<String, Object> equalizerAudioEffectGetParameters() {
        Equalizer equalizer = (Equalizer)audioEffectsMap.get("AndroidEqualizer");
        ArrayList<Object> rawBands = new ArrayList<>();
        for (short i = 0; i < equalizer.getNumberOfBands(); i++) {
            rawBands.add(mapOf(
                "index", i,
                "lowerFrequency", (double)equalizer.getBandFreqRange(i)[0] / 1000.0, // returns a value in milliHertz, we want Hertz
                "upperFrequency", (double)equalizer.getBandFreqRange(i)[1] / 1000.0, // returns a value in milliHertz, we want Hertz
                "centerFrequency", (double)equalizer.getCenterFreq(i) / 1000.0, // returns a value in milliHertz, we want Hertz
                "gain", equalizer.getBandLevel(i) / 100.0 // returns a value in milliBel, we want deciBel
            ));
        }
        return mapOf(
            "parameters", mapOf(
                "minDecibels", equalizer.getBandLevelRange()[0] / 100.0, // returns a value in milliBel, we want deciBel
                "maxDecibels", equalizer.getBandLevelRange()[1] / 100.0, // returns a value in milliBel, we want deciBel
                "bands", rawBands
            )
        );
    }

    private void equalizerBandSetGain(int bandIndex, double gain) {
        ((Equalizer)audioEffectsMap.get("AndroidEqualizer")).setBandLevel((short)bandIndex, (short)(Math.round(gain * 100.0))); // target gain needs to be provided in milliBel, the user provides the value in deciBel
    }

    /// Creates an event based on the current state.
    private Map<String, Object> createPlaybackEvent() {
        final Map<String, Object> event = new HashMap<String, Object>();
        Long duration = getDuration() == C.TIME_UNSET ? null : (1000 * getDuration());
        bufferedPosition = player != null ? player.getBufferedPosition() : 0L;
        event.put("processingState", processingState.ordinal());
        event.put("updatePosition", 1000 * updatePosition);
        event.put("updateTime", updateTime);
        event.put("bufferedPosition", 1000 * Math.max(updatePosition, bufferedPosition));
        event.put("icyMetadata", collectIcyMetadata());
        event.put("duration", duration);
        event.put("currentIndex", currentIndex);
        event.put("androidAudioSessionId", audioSessionId);
        event.put("errorCode", errorCode);
        event.put("errorMessage", errorMessage);
        return event;
    }

    // Broadcast the pending playback event if it was set.
    private void broadcastPendingPlaybackEvent() {
        if (pendingPlaybackEvent != null) {
            eventChannel.success(pendingPlaybackEvent);
            pendingPlaybackEvent = null;
        }
    }

    // Set a pending playback event that should be broadcast at
    // a later time. If we're in a Flutter method call, it will
    // be broadcast just before that method call returns. If
    // we're in an asynchronous callback, it is up to the caller
    // to eventually broadcast that event via
    // broadcastPendingPlaybackEvent.
    //
    // If this is called multiple times before
    // broadcastPendingPlaybackEvent, only the last event is
    // broadcast.
    private void enqueuePlaybackEvent() {
        pendingPlaybackEvent = createPlaybackEvent();
    }

    // Broadcasts a new event immediately.
    private void broadcastImmediatePlaybackEvent() {
        enqueuePlaybackEvent();
        broadcastPendingPlaybackEvent();
    }

    private Map<String, Object> collectIcyMetadata() {
        final Map<String, Object> icyData = new HashMap<>();
        if (icyInfo != null) {
            final Map<String, String> info = new HashMap<>();
            info.put("title", icyInfo.title);
            info.put("url", icyInfo.url);
            icyData.put("info", info);
        }
        if (icyHeaders != null) {
            final Map<String, Object> headers = new HashMap<>();
            headers.put("bitrate", icyHeaders.bitrate);
            headers.put("genre", icyHeaders.genre);
            headers.put("name", icyHeaders.name);
            headers.put("metadataInterval", icyHeaders.metadataInterval);
            headers.put("url", icyHeaders.url);
            headers.put("isPublic", icyHeaders.isPublic);
            icyData.put("headers", headers);
        }
        return icyData;
    }

    private long getCurrentPosition() {
        if (processingState == ProcessingState.idle || processingState == ProcessingState.loading) {
            long pos = player.getCurrentPosition();
            if (pos < 0) pos = 0;
            return pos;
        } else if (seekPos != null && seekPos != C.TIME_UNSET) {
            return seekPos;
        } else {
            return player.getCurrentPosition();
        }
    }

    private long getDuration() {
        if (processingState == ProcessingState.idle || processingState == ProcessingState.loading || player == null) {
            return C.TIME_UNSET;
        } else {
            return player.getDuration();
        }
    }

    private void sendError(int errorCode, String errorMsg, Object details) {
        sendError(errorCode, errorMsg, details, true);
    }

    private void sendError(int errorCode, String errorMsg, Object details, boolean switchToIdle) {
        eventChannel.error(String.valueOf(errorCode), errorMsg, details);
        this.errorCode = errorCode;
        this.errorMessage = errorMsg;
        if (switchToIdle) {
            processingState = ProcessingState.idle;
        }
        broadcastImmediatePlaybackEvent();
        if (prepareResult != null) {
            prepareResult.error(String.valueOf(errorCode), errorMsg, details);
            prepareResult = null;
        }
    }

    private String getLowerCaseExtension(Uri uri) {
        // Until ExoPlayer provides automatic detection of media source types, we
        // rely on the file extension. When this is absent, as a temporary
        // workaround we allow the app to supply a fake extension in the URL
        // fragment. e.g.  https://somewhere.com/somestream?x=etc#.m3u8
        String fragment = uri.getFragment();
        String filename = fragment != null && fragment.contains(".") ? fragment : uri.getPath();
        return filename.replaceAll("^.*\\.", "").toLowerCase();
    }

    public void play(Result result) {
        if (player.getPlayWhenReady()) {
            result.success(new HashMap<String, Object>());
            return;
        }
        if (playResult != null) {
            playResult.success(new HashMap<String, Object>());
        }
        playResult = result;
        player.setPlayWhenReady(true);
        updatePosition();
        if (processingState == ProcessingState.completed && playResult != null) {
            playResult.success(new HashMap<String, Object>());
            playResult = null;
        }
    }

    public void pause() {
        if (!player.getPlayWhenReady()) return;
        player.setPlayWhenReady(false);
        updatePosition();
        enqueuePlaybackEvent();
        if (playResult != null) {
            playResult.success(new HashMap<String, Object>());
            playResult = null;
        }
    }

    public void setVolume(final float volume) {
        player.setVolume(volume);
    }

    public void setSpeed(final float speed) {
        PlaybackParameters params = player.getPlaybackParameters();
        if (params.speed == speed) return;
        player.setPlaybackParameters(new PlaybackParameters(speed, params.pitch));
        if (player.getPlayWhenReady())
            updatePosition();
        enqueuePlaybackEvent();
    }

    public void setPitch(final float pitch) {
        PlaybackParameters params = player.getPlaybackParameters();
        if (params.pitch == pitch) return;
        player.setPlaybackParameters(new PlaybackParameters(params.speed, pitch));
        enqueuePlaybackEvent();
    }

    public void setSkipSilenceEnabled(final boolean enabled) {
        player.setSkipSilenceEnabled(enabled);
    }

    public void setLoopMode(final int mode) {
        player.setRepeatMode(mode);
    }

    public void setShuffleModeEnabled(final boolean enabled) {
        player.setShuffleModeEnabled(enabled);
    }

    public void seek(final long position, final Integer index, final Result result) {
        if (processingState == ProcessingState.idle || processingState == ProcessingState.loading) {
            result.success(new HashMap<String, Object>());
            return;
        }
        abortSeek();
        seekPos = position;
        seekResult = result;
        try {
            int windowIndex = index != null ? index : player.getCurrentMediaItemIndex();
            player.seekTo(windowIndex, position);
        } catch (RuntimeException e) {
            seekResult = null;
            seekPos = null;
            throw e;
        }
    }

    public void dispose() {
        if (processingState == ProcessingState.loading) {
            abortExistingConnection(true);
        }
        if (playResult != null) {
            playResult.success(new HashMap<String, Object>());
            playResult = null;
        }
        mediaSources.clear();
        clearAudioEffects();
        if (player != null) {
            player.release();
            player = null;
            processingState = ProcessingState.idle;
            broadcastImmediatePlaybackEvent();
        }
        eventChannel.endOfStream();
        dataEventChannel.endOfStream();
    }

    private void abortSeek() {
        if (seekResult != null) {
            try {
                seekResult.success(new HashMap<String, Object>());
            } catch (RuntimeException e) {
                // Result already sent
            }
            seekResult = null;
            seekPos = null;
        }
    }

    private void abortExistingConnection(boolean switchToIdle) {
        sendError(ERROR_ABORT, "Connection aborted", null, switchToIdle);
    }

    // Dart can't distinguish between int sizes so
    // Flutter may send us a Long or an Integer
    // depending on the number of bits required to
    // represent it.
    public static Long getLong(Object o) {
        return (o == null || o instanceof Long) ? (Long)o : Long.valueOf(((Integer)o).intValue());
    }

    @SuppressWarnings("unchecked")
    static <T> T mapGet(Object o, String key) {
        if (o instanceof Map) {
            return (T) ((Map<?, ?>)o).get(key);
        } else {
            return null;
        }
    }

    static Map<String, Object> mapOf(Object... args) {
        Map<String, Object> map = new HashMap<>();
        for (int i = 0; i < args.length; i += 2) {
            map.put((String)args[i], args[i + 1]);
        }
        return map;
    }

    static Map<String, String> castToStringMap(Map<?, ?> map) {
        if (map == null) return null;
        Map<String, String> map2 = new HashMap<>();
        for (Object key : map.keySet()) {
            map2.put((String)key, (String)map.get(key));
        }
        return map2;
    }

    enum ProcessingState {
        idle,
        loading,
        buffering,
        ready,
        completed
    }

    public class ObserverRenderer extends NoSampleRenderer {
        private long lastPosUs = 0L;
        private int consecutivePosCount = 0;

        @Override
        public void render(long positionUs, long elapsedRealtimeUs) {
            if (positionUs == lastPosUs) {
                consecutivePosCount++;
            } else {
                if (consecutivePosCount >= 3) {
                    handler.post(() -> {
                        if (updatePositionIfChanged()) {
                            broadcastImmediatePlaybackEvent();
                        }
                    });
                }
                consecutivePosCount = 0;
            }
            lastPosUs = positionUs;
        }

        @Override
        public String getName() {
            return "ObserverRenderer";
        }
    }
}
