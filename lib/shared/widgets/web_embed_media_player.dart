import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/web_embed/web_embed_media.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/network/image_header_utils.dart';
import '../../features/chat/services/video_attachment_cache.dart';
import '../../features/chat/widgets/enhanced_video_attachment.dart';
import '../../l10n/app_localizations.dart';
import '../theme/theme_extensions.dart';
import 'conduit_components.dart';
import 'platform_ui/platform_ui.dart';
import 'platform_ui/vocabulary.dart';

/// The app's own player for media a web embed names on the account's server
/// ([extractWebEmbedServerMedia]). It fetches [item]'s addresses and nothing
/// else, in turn until one plays, with the account's credentials on a client
/// of its own, and only once Play is pressed.
class WebEmbedMediaPlayer extends ConsumerWidget {
  const WebEmbedMediaPlayer({super.key, required this.item});

  final WebEmbedMediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (item.kind) {
      WebEmbedMediaKind.audio => _AudioRow(item: item),
      WebEmbedMediaKind.video => Align(
        alignment: AlignmentDirectional.centerStart,
        child: EnhancedVideoAttachment(
          attachmentId: item.url.toString(),
          alternativeSources: [
            for (final source in item.sources.skip(1)) '$source',
          ],
          filenameHint: item.label,
          transport: (url) => (
            client: _mediaClient(ref, url),
            headers: const <String, String>{},
            ownsClient: true,
          ),
        ),
      ),
    };
  }
}

/// A [webEmbedMediaClient] carrying the active account's credentials for
/// [url], which must be on its server.
Dio _mediaClient(WidgetRef ref, String url) {
  final api = ref.read(apiServiceProvider);
  final headers = readImageHeadersForUrlFromWidgetRef(ref, url);
  if (api == null || headers == null) {
    throw StateError('Embed media is not on the active server');
  }
  return webEmbedMediaClient(api.serverConfig, headers);
}

class _AudioRow extends ConsumerStatefulWidget {
  const _AudioRow({required this.item});

  final WebEmbedMediaItem item;

  @override
  ConsumerState<_AudioRow> createState() => _AudioRowState();
}

enum _AudioStatus { idle, loading, ready, failed }

class _AudioRowState extends ConsumerState<_AudioRow> {
  late final VideoAttachmentCache _cache;
  final VideoDownloadClaim _download = VideoDownloadClaim();
  AudioPlayer? _player;
  String? _file;
  WebEmbedMediaLoad? _current;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  _AudioStatus _status = _AudioStatus.idle;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    _cache = ref.read(videoAttachmentCacheProvider);
  }

  @override
  void didUpdateWidget(covariant _AudioRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item != widget.item) {
      _release();
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    _current?.cancel();
    _current = null;
    _cache.releaseDownload(_download);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final player = _player;
    final file = _file;
    _player = null;
    _file = null;
    // The cache keeps the file until the player has let go of it.
    unawaited(
      (player?.dispose() ?? Future<void>.value()).whenComplete(
        () => _cache.releaseCachePath(file),
      ),
    );
    _status = _AudioStatus.idle;
    _playing = false;
    _position = Duration.zero;
    _duration = null;
    _dragValue = null;
  }

  /// Plays the item from its source [from] on; Play and Retry start again
  /// from the first. Each source is downloaded into the media cache first,
  /// as a chat video is, and played from there.
  Future<void> _load({int from = 0}) async {
    _release();
    setState(() => _status = _AudioStatus.loading);
    final load = _current = WebEmbedMediaLoad(
      widget.item.sources,
      index: from,
      onFailure: _failed,
    );
    final source = load.source;
    final url = source.toString();
    final File file;
    try {
      file = await _cache.fetchForPlayback(
        claim: _download,
        url: url,
        // Open WebUI file addresses are the same for every account on a
        // server; the image cache's key is scoped to the account.
        cacheIdentity:
            buildImageCacheKeyForUrlFromContainer(
              ProviderScope.containerOf(context, listen: false),
              url,
            ) ??
            url,
        extension: webEmbedAudioExtension(source),
        extensionForReply: (mediaType, {contentDisposition}) =>
            webEmbedAudioExtension(
              source,
              mediaType: mediaType,
              contentDisposition: contentDisposition,
            ),
        transport: (url) => (
          client: _mediaClient(ref, url),
          headers: const <String, String>{},
          ownsClient: true,
        ),
        isCurrent: () => mounted && load.isCurrent,
      );
    } catch (error, stackTrace) {
      load.fail(error, stackTrace);
      return;
    }
    if (!mounted || !load.isCurrent) {
      _cache.releaseCachePath(file.path);
      return;
    }
    final player = AudioPlayer();
    _player = player;
    _file = file.path;
    _subscriptions
      // A failure after the load, such as a read error mid-file, arrives
      // only here: just_audio sends no error on its playback events.
      ..add(
        player.errorStream.listen(
          (error) => load.fail(error, StackTrace.current),
        ),
      )
      ..add(
        player.playerStateStream.listen((state) {
          if (!mounted || !load.isCurrent) return;
          setState(() {
            _playing =
                state.playing &&
                state.processingState != ProcessingState.completed;
          });
        }),
      )
      ..add(
        player.positionStream.listen((position) {
          if (!mounted || !load.isCurrent) return;
          setState(() => _position = position);
        }),
      )
      ..add(
        player.durationStream.listen((duration) {
          if (!mounted || !load.isCurrent) return;
          setState(() => _duration = duration);
        }),
      );
    try {
      await player.setFilePath(file.path);
    } catch (error, stackTrace) {
      load.fail(error, stackTrace);
      return;
    }
    if (!mounted || !load.isCurrent) return;
    load.markReady();
    setState(() => _status = _AudioStatus.ready);
    unawaited(player.play());
  }

  /// Plays from [retryFrom] when given ([WebEmbedMediaLoad]); otherwise
  /// shows the failure, with Retry.
  void _failed(int? retryFrom, Object error, StackTrace stackTrace) {
    if (!mounted) return;
    DebugLogger.error(
      'embed-audio-failed',
      scope: 'embeds/media',
      error: error,
      stackTrace: stackTrace,
    );
    if (retryFrom != null) {
      unawaited(_load(from: retryFrom));
      return;
    }
    setState(() {
      _release();
      _status = _AudioStatus.failed;
    });
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null || _status != _AudioStatus.ready) {
      await _load();
      return;
    }
    if (player.processingState == ProcessingState.completed) {
      await player.seek(Duration.zero);
      if (!player.playing) unawaited(player.play());
    } else if (player.playing) {
      await player.pause();
    } else {
      unawaited(player.play());
    }
  }

  void _seek(double fraction) {
    final duration = _duration;
    setState(() => _dragValue = null);
    if (duration == null) return;
    unawaited(_player?.seek(duration * fraction));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final label = widget.item.label ?? l10n.audioFileType;
    final isIOS = PlatformUiCapabilities.isIOS;
    final duration = _duration;
    final canSeek =
        _status == _AudioStatus.ready &&
        duration != null &&
        duration > Duration.zero;
    final progress = canSeek
        ? (_dragValue ?? _position.inMilliseconds / duration.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0.0;

    final Widget control = switch (_status) {
      _AudioStatus.loading => SizedBox.square(
        dimension: TouchTarget.minimum,
        child: Center(
          child: SizedBox.square(
            dimension: 16,
            child: AdaptiveProgressIndicator(
              strokeWidth: 2,
              semanticLabel: l10n.loadingAudio,
            ),
          ),
        ),
      ),
      _AudioStatus.failed => ConduitIconButton(
        icon: isIOS ? CupertinoIcons.arrow_clockwise : Icons.refresh_rounded,
        tooltip: l10n.retry,
        onPressed: _load,
      ),
      _ => ConduitIconButton(
        icon: _playing
            ? (isIOS ? CupertinoIcons.pause_fill : Icons.pause_rounded)
            : (isIOS ? CupertinoIcons.play_fill : Icons.play_arrow_rounded),
        tooltip: _playing ? l10n.videoPause : l10n.playAudio,
        onPressed: _toggle,
      ),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border.all(color: theme.cardBorder),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xs,
          vertical: Spacing.xxs,
        ),
        child: Row(
          children: [
            control,
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_status == _AudioStatus.failed)
                    Text(
                      l10n.failedToLoadAudio,
                      style: AppTypography.captionStyle.copyWith(
                        color: theme.error,
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: AdaptiveSlider(
                            value: progress,
                            onChanged: canSeek
                                ? (value) => setState(() => _dragValue = value)
                                : null,
                            onChangeEnd: canSeek ? _seek : null,
                            thumbless: true,
                            seekOnTap: true,
                            semanticLabel: label,
                          ),
                        ),
                        const SizedBox(width: Spacing.xs),
                        Text(
                          duration == null
                              ? _clock(_position)
                              : '${_clock(_position)} / ${_clock(duration)}',
                          style: AppTypography.captionStyle.copyWith(
                            color: theme.textSecondary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _clock(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
