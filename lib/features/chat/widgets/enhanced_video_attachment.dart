import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../core/network/image_header_utils.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/utils/locale_display_formatters.dart';
import '../../../shared/utils/platform_page_route.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../services/native_image_viewer_bridge.dart';
import '../services/video_attachment_cache.dart';

/// Inline video player for chat attachments (generated clips, tool output).
///
/// Shows a placeholder card until the user taps Play: nothing is downloaded
/// and no player starts before then. Accepts a full URL, a server-relative
/// path, or a bare file ID. Every source is fetched through the
/// server-configured HTTP client (same-origin requests reuse ApiService.dio
/// so self-signed certificates and client certificates from ServerConfig
/// apply) and played from a local cached copy, so playback and export share
/// one transport. Falls back to a compact card with open-in-browser and
/// download actions when playback is unavailable.
class EnhancedVideoAttachment extends ConsumerStatefulWidget {
  const EnhancedVideoAttachment({
    super.key,
    required this.attachmentId,
    this.httpHeaders,
    this.constraints,
    this.filenameHint,
    this.contentType,
    this.sizeBytes,
  });

  final String attachmentId;
  final Map<String, String>? httpHeaders;
  final BoxConstraints? constraints;
  final String? filenameHint;
  final String? contentType;

  /// Shown on the placeholder card when known.
  final int? sizeBytes;

  @override
  ConsumerState<EnhancedVideoAttachment> createState() =>
      _EnhancedVideoAttachmentState();
}

class _EnhancedVideoAttachmentState
    extends ConsumerState<EnhancedVideoAttachment>
    with WidgetsBindingObserver {
  late final VideoAttachmentCache _cache;
  final VideoDownloadClaim _downloadClaim = VideoDownloadClaim();
  VideoPlayerController? _controller;
  // Nothing is downloaded and no player starts until the user taps Play.
  bool _requested = false;
  bool _initializing = false;
  bool _playbackFailed = false;
  bool _lastPlayed = false;
  int _lastPositionSeconds = -1;
  bool _saving = false;
  String? _openUrl;
  int _openRequestId = 0;
  PageRoute<void>? _fullscreenRoute;
  NavigatorState? _fullscreenNav;
  // Controllers retired while the fullscreen viewer still renders them; the
  // viewer disposes them as it closes.
  final Set<VideoPlayerController> _viewerOwnedControllers = {};
  dio.CancelToken? _exportToken;

  @override
  void initState() {
    super.initState();
    _cache = ref.read(videoAttachmentCacheProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant EnhancedVideoAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentId == widget.attachmentId &&
        mapEquals(oldWidget.httpHeaders, widget.httpHeaders)) {
      return;
    }
    // A replaced message can change the source under this state. Drop the
    // old player and transfer so the old clip is neither shown nor exported.
    _cache.releaseDownload(_downloadClaim);
    _exportToken?.cancel('video source changed');
    final previous = _controller;
    previous?.removeListener(_onControllerChanged);
    _controller = null;
    _cache.releaseCachePath(_tempCacheKey);
    _tempCacheKey = null;
    _openUrl = null;
    _initializing = _requested;
    _playbackFailed = false;
    _retireController(previous);
    // A video the user already started loads its new source; any other
    // keeps waiting for a tap.
    if (_requested) {
      _openVideo();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cache.releaseDownload(_downloadClaim);
    _exportToken?.cancel('video widget disposed');
    final controller = _controller;
    controller?.removeListener(_onControllerChanged);
    _controller = null;
    _cache.releaseCachePath(_tempCacheKey);
    _retireController(controller);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (controller.value.isPlaying) {
        controller.pause();
      }
    }
  }

  String? _tempCacheKey;

  /// Disposes [controller] once nothing renders it. While the fullscreen
  /// viewer shows it, the viewer is removed after this frame, since popping
  /// during build or unmount asserts, and disposes the controller as it
  /// closes.
  void _retireController(VideoPlayerController? controller) {
    if (controller == null) return;
    final route = _fullscreenRoute;
    final nav = _fullscreenNav;
    _fullscreenRoute = null;
    _fullscreenNav = null;
    if (route == null || nav == null || !route.isActive) {
      unawaited(controller.dispose());
      return;
    }
    _viewerOwnedControllers.add(controller);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (nav.mounted && route.isActive) nav.removeRoute(route);
    });
  }

  void _attachController(VideoPlayerController controller) {
    _controller?.removeListener(_onControllerChanged);
    controller.addListener(_onControllerChanged);
    _controller = controller;
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final seconds = controller.value.position.inSeconds;
    if (seconds != _lastPositionSeconds ||
        controller.value.isPlaying != _lastPlayed) {
      _lastPositionSeconds = seconds;
      _lastPlayed = controller.value.isPlaying;
      setState(() {});
    }
  }

  void _startPlayback() {
    if (_requested) return;
    setState(() {
      _requested = true;
      _initializing = true;
    });
    _openVideo();
  }

  Future<void> _openVideo() async {
    final requestId = ++_openRequestId;
    final idOrUrl = widget.attachmentId.trim();
    VideoPlayerController? controller;
    String? openUrl;
    String? downloadedPath;

    try {
      if (idOrUrl.isEmpty) {
        throw StateError('Empty video attachment id');
      }

      final api = ref.read(apiServiceProvider);
      if (idOrUrl.startsWith('http://') || idOrUrl.startsWith('https://')) {
        openUrl = idOrUrl;
      } else {
        // A server-relative path, or a bare file id resolved through the
        // Files API content endpoint.
        final path = idOrUrl.startsWith('/')
            ? idOrUrl
            : '/api/v1/files/$idOrUrl/content';
        final resolved = resolveServerRelativeImageUrl(api?.baseUrl, path);
        if (resolved == path) {
          throw StateError('No server origin for video path');
        }
        openUrl = resolved;
      }

      // Fetch through the server-configured client and play a local copy:
      // VideoPlayerController.networkUrl would bypass the TLS settings
      // (self-signed / client certs) that ApiService.dio already applies,
      // and streamed playback would leak the whole fetch into memory.
      // No fixed total-download deadline: large videos are fine as long as
      // data keeps arriving (a stall watchdog inside the transfer handles
      // dead connections).
      final file = await _fetchVideo(api, openUrl, requestId);
      downloadedPath = file.path;
      controller = VideoPlayerController.file(file);

      await controller.initialize().timeout(const Duration(seconds: 30));

      if (!mounted || requestId != _openRequestId) {
        // Nobody will hold this path: give the reservation back to the prune.
        _cache.releaseCachePath(file.path);
        unawaited(controller.dispose());
        return;
      }

      controller.setVolume(0);
      // Reserved by fetchForPlayback; dispose() releases this handle.
      _tempCacheKey = file.path;
      _lastPositionSeconds = -1;
      _lastPlayed = false;
      _attachController(controller);
      setState(() {
        _initializing = false;
        _playbackFailed = false;
        _openUrl = openUrl;
      });
      // The user pressed Play to get here.
      controller.play();
    } catch (error) {
      if (controller != null) {
        unawaited(controller.dispose());
      }
      // A full download can succeed while the player still fails to
      // initialize; keep the completed cache copy so the fallback export
      // reuses it instead of fetching the same video again.
      if (downloadedPath != null) {
        if (mounted && requestId == _openRequestId) {
          // fetchForPlayback already reserved the path; keep the handle so
          // the fallback export reuses the completed cache copy.
          _tempCacheKey = downloadedPath;
        } else {
          // Disposed mid-initialize: dispose() had no handle to release, so
          // drop the reservation here instead of leaking it forever.
          _cache.releaseCachePath(downloadedPath);
        }
      }
      if (!mounted || requestId != _openRequestId) return;
      setState(() {
        _initializing = false;
        _playbackFailed = true;
        _openUrl = openUrl;
      });
    }
  }

  Future<File> _fetchVideo(ApiService? api, String url, int requestId) {
    // Open WebUI file URLs are the same for every account on a server, so
    // the cache name carries the account-scoped key the image cache uses.
    final cacheIdentity =
        buildImageCacheKeyForUrlFromContainer(
          ProviderScope.containerOf(context, listen: false),
          url,
          effectiveHeaders: widget.httpHeaders,
        ) ??
        url;
    return _cache.fetchForPlayback(
      claim: _downloadClaim,
      url: url,
      cacheIdentity: cacheIdentity,
      extension: _videoExtension(),
      transport: (source) => _transportFor(api, source),
      isCurrent: () => mounted && requestId == _openRequestId,
    );
  }

  /// Picks the HTTP transport for [url]: same-origin requests reuse
  /// ApiService.dio so its auth interceptors and ServerConfig TLS (including
  /// self-signed certificates and client certificates) apply; foreign URLs
  /// get a throwaway client carrying the eligible image headers.
  VideoTransport _transportFor(ApiService? api, String url) {
    final baseUrl = api?.baseUrl;
    final sameOrigin =
        api != null && baseUrl != null && imageUrlIsServerOrigin(baseUrl, url);
    if (sameOrigin) {
      return (
        client: api.dio,
        headers: widget.httpHeaders ?? const <String, String>{},
        ownsClient: false,
      );
    }
    final headers =
        widget.httpHeaders ??
        readImageHeadersForUrlFromWidgetRef(ref, url) ??
        const <String, String>{};
    return (client: dio.Dio(), headers: headers, ownsClient: true);
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  void _toggleMute() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    controller.setVolume(controller.value.volume > 0 ? 0 : 1);
    setState(() {});
  }

  void _openExternally() {
    final url = _openUrl;
    if (url == null || url.isEmpty) return;
    launchExternalLink(url, scope: 'chat/video_attachment');
  }

  static const Map<String, String> _videoMimeByExtension = {
    'mp4': 'video/mp4',
    'm4v': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
    'avi': 'video/x-msvideo',
  };

  static const Map<String, String> _videoExtensionByMime = {
    'video/mp4': 'mp4',
    'video/quicktime': 'mov',
    'video/webm': 'webm',
    'video/x-matroska': 'mkv',
    'video/avi': 'avi',
    'video/x-msvideo': 'avi',
  };

  /// Server-declared video MIME type, when present, wins over name guessing
  /// so extensionless Files API URLs still download in the right container.
  String _declaredContentType() {
    final declared = widget.contentType?.toLowerCase().trim() ?? '';
    return declared.startsWith('video/') ? declared : '';
  }

  String _videoExtension() {
    final fromMime = _videoExtensionByMime[_declaredContentType()];
    if (fromMime != null) return fromMime;
    final candidates = <String>[
      widget.filenameHint ?? '',
      widget.attachmentId,
      _openUrl ?? '',
    ];
    final pattern = RegExp(r'\.([A-Za-z0-9]{2,5})(?=$|[?&#])');
    for (final candidate in candidates) {
      final match = pattern.firstMatch(candidate.split('#').first);
      final extension = match?.group(1)?.toLowerCase();
      if (extension != null && _videoMimeByExtension.containsKey(extension)) {
        return extension;
      }
    }
    return 'mp4';
  }

  String _saveFileName() {
    final label = _displayLabel().replaceAll(
      RegExp(r'\.[A-Za-z0-9]{2,5}$'),
      '',
    );
    final safe = label.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_').trim();
    final base = safe.isEmpty ? 'conduit_video' : safe;
    return '$base.${_videoExtension()}';
  }

  /// Opens the file to hand to the exporter: the playback cache copy while
  /// it is complete, else a scratch download that dispose can cancel.
  Future<VideoExportFile> _localVideoForExport() async {
    final api = ref.read(apiServiceProvider);
    final token = dio.CancelToken();
    _exportToken = token;
    try {
      return await _cache.openForExport(
        cachedPath: _tempCacheKey,
        url: _openUrl,
        extension: _videoExtension(),
        transport: (source) => _transportFor(api, source),
        token: token,
        isCurrent: () => mounted,
      );
    } finally {
      if (_exportToken == token) {
        _exportToken = null;
      }
    }
  }

  Future<bool> _exportVideoFile(File file, String displayName) async {
    final declaredType = _declaredContentType();
    final mimeType = declaredType.isNotEmpty
        ? declaredType
        : _videoMimeByExtension[_videoExtension()] ?? 'video/mp4';
    if (Platform.isAndroid) {
      final bridge = NativeImageViewerBridge.instance;
      if (await bridge.canSaveImages()) {
        // The native bridge routes video mime types into the Movies
        // collection; images keep going to Pictures.
        await bridge.saveImage(
          path: file.path,
          mimeType: mimeType,
          displayName: displayName,
        );
        return true;
      }
    }
    final result = await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(file.path, mimeType: mimeType, name: displayName)],
        fileNameOverrides: <String>[displayName],
      ),
    );
    switch (result.status) {
      case ShareResultStatus.success:
        return true;
      case ShareResultStatus.dismissed:
      case ShareResultStatus.unavailable:
        // Closed, or the platform does not report what the user picked: the
        // sheet still opened, so this is unconfirmed, not a failure.
        return false;
    }
  }

  Future<void> _downloadVideo() async {
    if (_saving) return;
    setState(() => _saving = true);
    final l10n = AppLocalizations.of(context)!;
    String? message;
    var failed = false;
    VideoExportFile? exported;
    final sourceUrlAtStart = _openUrl;
    try {
      exported = await _localVideoForExport();
      // Disposed while fetching, or a replaced source changed under the
      // export: the selected file belongs to the previous clip and must not
      // be delivered under the new filename. Scratch cleanup still runs.
      if (!mounted || _openUrl != sourceUrlAtStart) {
        throw StateError('Video source changed during export');
      }
      final confirmed = await _exportVideoFile(exported.file, _saveFileName());
      // A dismissed share sheet saved nothing; stay silent instead of
      // reporting a save the user never performed.
      message = confirmed ? l10n.videoSaved : null;
    } catch (error, stackTrace) {
      failed = true;
      message = l10n.videoSaveFailed;
      DebugLogger.error(
        'video-save-failed',
        scope: 'chat/video_attachment',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await exported?.close();
    if (!mounted) return;
    setState(() => _saving = false);
    if (message != null) {
      AdaptiveSnackBar.show(
        context,
        message: message,
        type: failed
            ? AdaptiveSnackBarType.error
            : AdaptiveSnackBarType.success,
      );
    }
  }

  void _openFullscreen() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.volume == 0) {
      controller.setVolume(1);
    }
    final nav = Navigator.of(context);
    final route = buildPlatformPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _FullscreenVideoPage(
        controller: controller,
        label: _displayLabel(),
        onClosed: () {
          if (_viewerOwnedControllers.remove(controller)) {
            unawaited(controller.dispose());
          }
        },
      ),
    );
    _fullscreenNav = nav;
    _fullscreenRoute = route;
    unawaited(
      nav.push(route).whenComplete(() {
        if (_fullscreenRoute == route) {
          _fullscreenRoute = null;
          _fullscreenNav = null;
        }
      }),
    );
  }

  String _displayLabel() {
    final hint = widget.filenameHint?.trim();
    if (hint != null && hint.isNotEmpty) return hint;
    final idOrUrl = widget.attachmentId;
    try {
      final parts = Uri.parse(idOrUrl).path
          .split('/')
          .where((part) => part.isNotEmpty)
          .toList();
      if (parts.isNotEmpty) return parts.last;
    } catch (_) {}
    return 'video';
  }

  String _formatDuration(Duration duration) => _formatVideoDuration(duration);

  /// The card shown until the user taps Play, and while the video loads.
  Widget _buildPlaceholder(
    ConduitThemeExtension theme,
    AppLocalizations l10n,
    BoxConstraints constraints,
  ) {
    final size = widget.sizeBytes;
    return ConstrainedBox(
      constraints: constraints,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: _startPlayback,
        child: Container(
          decoration: BoxDecoration(
            color: theme.cardBackground,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.ondemand_video, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _displayLabel(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: theme.textPrimary),
                    ),
                    if (size != null && size > 0)
                      Text(
                        LocaleDisplayFormatters.bytes(context, size),
                        style: AppTypography.labelMediumStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              _initializing
                  ? const _VideoBusyIndicator()
                  : ConduitIconButton(
                      icon: Icons.play_arrow_rounded,
                      tooltip: l10n.videoPlay,
                      isCompact: true,
                      onPressed: _startPlayback,
                    ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final constraints =
        (widget.constraints ?? const BoxConstraints(maxWidth: 520)).copyWith(
          maxHeight: 460,
        );

    if (!_requested || _initializing) {
      return _buildPlaceholder(theme, l10n, constraints);
    }

    if (_playbackFailed || _controller == null) {
      return ConstrainedBox(
        constraints: constraints,
        child: Container(
          decoration: BoxDecoration(
            color: theme.cardBackground,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.ondemand_video, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _displayLabel(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.textPrimary),
                ),
              ),
              if (_openUrl != null)
                ConduitIconButton(
                  icon: Icons.open_in_new,
                  tooltip: l10n.videoOpenInBrowser,
                  isCompact: true,
                  onPressed: _openExternally,
                ),
              if (_openUrl != null || _tempCacheKey != null)
                _saving
                    ? const _VideoBusyIndicator()
                    : ConduitIconButton(
                        icon: Icons.download_rounded,
                        tooltip: l10n.videoDownload,
                        isCompact: true,
                        onPressed: _downloadVideo,
                      ),
            ],
          ),
        ),
      );
    }

    final controller = _controller!;
    final aspectRatio = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
    final muted = controller.value.volume == 0;

    return ConstrainedBox(
      constraints: constraints,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(controller),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _togglePlay,
                  child: const SizedBox.expand(),
                ),
              ),
              AnimatedOpacity(
                opacity: controller.value.isPlaying ? 0 : 1,
                duration: const Duration(milliseconds: 160),
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _videoBackdrop.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: _videoForeground,
                        size: 34,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _videoBackdrop.withValues(alpha: 0),
                        _videoBackdrop.withValues(alpha: 0.55),
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      ConduitIconButton(
                        icon: controller.value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        tooltip: controller.value.isPlaying
                            ? l10n.videoPause
                            : l10n.videoPlay,
                        iconColor: _videoForeground,
                        isCompact: true,
                        onPressed: _togglePlay,
                      ),
                      Expanded(
                        child: VideoProgressIndicator(
                          controller,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: _videoSecondaryForeground,
                            bufferedColor: _videoBufferedTrack,
                            backgroundColor: _videoTrack,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _formatDuration(controller.value.position),
                        style: const TextStyle(
                          color: _videoSecondaryForeground,
                          fontSize: 11,
                        ),
                      ),
                      ConduitIconButton(
                        icon: muted
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        tooltip: muted ? l10n.unmute : l10n.mute,
                        iconColor: _videoForeground,
                        isCompact: true,
                        onPressed: _toggleMute,
                      ),
                      ConduitIconButton(
                        icon: Icons.fullscreen_rounded,
                        tooltip: l10n.videoFullscreen,
                        iconColor: _videoForeground,
                        isCompact: true,
                        onPressed: _openFullscreen,
                      ),
                      _saving
                          ? const _VideoBusyIndicator(color: _videoForeground)
                          : ConduitIconButton(
                              icon: Icons.download_rounded,
                              tooltip: l10n.videoDownload,
                              iconColor: _videoForeground,
                              isCompact: true,
                              onPressed: _downloadVideo,
                            ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatVideoDuration(Duration duration) {
  final total = duration.inSeconds;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Immersive full-screen viewer for an inline chat video.
///
/// Reuses the inline player's controller: the chat card stays mounted under
/// the route, so the texture survives the trip. Orientation follows the
/// device, and system chrome returns when the viewer closes.
class _FullscreenVideoPage extends StatefulWidget {
  const _FullscreenVideoPage({
    required this.controller,
    required this.label,
    required this.onClosed,
  });

  final VideoPlayerController controller;
  final String label;

  /// Runs once the viewer no longer renders [controller].
  final VoidCallback onClosed;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!widget.controller.value.isPlaying) {
      widget.controller.play();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.controller.pause();
    // MainActivity enables edge-to-edge; manual mode would drop it on
    // Android 14 and older. An empty list restores the app's orientations.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    widget.onClosed();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _togglePlay() {
    final controller = widget.controller;
    if (!controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  void _toggleMute() {
    final controller = widget.controller;
    if (!controller.value.isInitialized) return;
    controller.setVolume(controller.value.volume > 0 ? 0 : 1);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.value.isInitialized) {
      return const ColoredBox(
        color: _videoBackdrop,
        child: Center(
          child: AdaptiveProgressIndicator(color: _videoForeground),
        ),
      );
    }
    final l10n = AppLocalizations.of(context)!;
    final muted = controller.value.volume == 0;
    final size = controller.value.size;

    // No Material ancestor on this route, so text needs its own base style.
    return ColoredBox(
      color: _videoBackdrop,
      child: DefaultTextStyle(
        style: AppTypography.bodyMediumStyle.copyWith(
          color: _videoSecondaryForeground,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: FittedBox(
                child: SizedBox(
                  width: size.width > 0 ? size.width : 16 / 9,
                  height: size.height > 0 ? size.height : 1,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          _videoBackdrop.withValues(alpha: 0.6),
                          _videoBackdrop.withValues(alpha: 0),
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(8, 2, 4, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        ConduitIconButton(
                          icon: muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          tooltip: muted ? l10n.unmute : l10n.mute,
                          iconColor: _videoForeground,
                          onPressed: _toggleMute,
                        ),
                        ConduitIconButton(
                          icon: Icons.close_rounded,
                          tooltip: l10n.close,
                          iconColor: _videoForeground,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          _videoBackdrop.withValues(alpha: 0),
                          _videoBackdrop.withValues(alpha: 0.6),
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: Row(
                      children: [
                        ConduitIconButton(
                          icon: controller.value.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          tooltip: controller.value.isPlaying
                              ? l10n.videoPause
                              : l10n.videoPlay,
                          iconColor: _videoForeground,
                          onPressed: _togglePlay,
                        ),
                        Expanded(
                          child: VideoProgressIndicator(
                            controller,
                            allowScrubbing: true,
                            colors: const VideoProgressColors(
                              playedColor: _videoSecondaryForeground,
                              bufferedColor: _videoBufferedTrack,
                              backgroundColor: _videoTrack,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(_formatVideoDuration(controller.value.position)),
                      ],
                    ),
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

// Video chrome is light-on-dark in every theme.
const _videoBackdrop = Color(0xFF000000);
const _videoForeground = Color(0xFFFFFFFF);
const _videoSecondaryForeground = Color(0xB3FFFFFF);
const _videoBufferedTrack = Color(0x3DFFFFFF);
const _videoTrack = Color(0x1FFFFFFF);

/// Stands in for an icon button while its work runs, at the same size.
class _VideoBusyIndicator extends StatelessWidget {
  const _VideoBusyIndicator({this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: TouchTarget.minimum,
      child: Center(
        child: SizedBox.square(
          dimension: 16,
          child: AdaptiveProgressIndicator(strokeWidth: 2, color: color),
        ),
      ),
    );
  }
}
