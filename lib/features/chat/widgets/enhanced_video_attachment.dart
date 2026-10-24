import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../core/network/image_header_utils.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../services/native_image_viewer_bridge.dart';

/// Inline video player for chat attachments (generated clips, tool output).
///
/// Accepts a full URL, a server-relative path, or a bare file ID. Every
/// source is fetched through the server-configured HTTP client (same-origin
/// requests reuse ApiService.dio so self-signed certificates and client
/// certificates from ServerConfig apply) and played from a local cached
/// copy, so playback and export share one transport. Falls back to a compact
/// card with open-in-browser and download actions when playback is
/// unavailable.
class EnhancedVideoAttachment extends ConsumerStatefulWidget {
  const EnhancedVideoAttachment({
    super.key,
    required this.attachmentId,
    this.httpHeaders,
    this.constraints,
    this.filenameHint,
    this.contentType,
  });

  final String attachmentId;
  final Map<String, String>? httpHeaders;
  final BoxConstraints? constraints;
  final String? filenameHint;
  final String? contentType;

  @override
  ConsumerState<EnhancedVideoAttachment> createState() =>
      _EnhancedVideoAttachmentState();
}

class _EnhancedVideoAttachmentState extends ConsumerState<EnhancedVideoAttachment>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _initializing = true;
  bool _playbackFailed = false;
  bool _lastPlayed = false;
  int _lastPositionSeconds = -1;
  bool _saving = false;
  String? _openUrl;
  int _openRequestId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _openVideo();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    controller?.dispose();
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

  Future<void> _openVideo() async {
    final requestId = ++_openRequestId;
    final idOrUrl = widget.attachmentId.trim();
    VideoPlayerController? controller;
    String? openUrl;

    try {
      if (idOrUrl.isEmpty) {
        throw StateError('Empty video attachment id');
      }

      final api = ref.read(apiServiceProvider);
      if (idOrUrl.startsWith('http://') || idOrUrl.startsWith('https://')) {
        openUrl = idOrUrl;
      } else if (idOrUrl.startsWith('/')) {
        final baseUrl = api?.baseUrl;
        if (baseUrl == null) {
          throw StateError('No server origin for relative video path');
        }
        openUrl = '$baseUrl$idOrUrl';
      } else {
        // Bare file id: resolve through the Files API content endpoint.
        final baseUrl = api?.baseUrl;
        if (baseUrl == null) {
          throw StateError('API service unavailable for video attachment');
        }
        openUrl = '$baseUrl/api/v1/files/$idOrUrl/content';
      }

      // Fetch through the server-configured client and play a local copy:
      // VideoPlayerController.networkUrl would bypass the TLS settings
      // (self-signed / client certs) that ApiService.dio already applies,
      // and streamed playback would leak the whole fetch into memory.
      final file = await _downloadToLocalVideo(api, openUrl).timeout(
        const Duration(seconds: 90),
      );
      controller = VideoPlayerController.file(file);

      await controller.initialize().timeout(const Duration(seconds: 30));

      if (!mounted || requestId != _openRequestId) {
        unawaited(controller.dispose());
        return;
      }

      controller.setVolume(0);
      _tempCacheKey = file.path;
      _lastPositionSeconds = -1;
      _lastPlayed = false;
      _attachController(controller);
      setState(() {
        _initializing = false;
        _playbackFailed = false;
        _openUrl = openUrl;
      });
    } catch (error) {
      if (controller != null) {
        unawaited(controller.dispose());
      }
      if (!mounted || requestId != _openRequestId) return;
      setState(() {
        _initializing = false;
        _playbackFailed = true;
        _openUrl = openUrl;
      });
    }
  }

  /// Streams the video into the attachment cache. The transfer lands on a
  /// scratch path and is renamed only after a complete download, so a
  /// canceled request never leaves a half-written file that a later
  /// length() > 0 cache hit would accept.
  Future<File> _downloadToLocalVideo(ApiService? api, String url) async {
    final extension = _videoExtension();
    final dir = await getTemporaryDirectory();
    final target = File(
      '${dir.path}/conduit_attachments/'
      'video_${_cacheNameFor(url)}.$extension',
    );
    if (await target.exists() && await target.length() > 0) {
      return target;
    }
    await target.parent.create(recursive: true);

    final part = File('${target.path}.part');
    final (client, headers, ownsClient) = _transportFor(api, url);
    try {
      await client.download(
        url,
        part.path,
        options: dio.Options(
          headers: headers,
          responseType: dio.ResponseType.stream,
        ),
      );
      await part.rename(target.path);
      return target;
    } finally {
      if (ownsClient) {
        client.close(force: true);
      }
      try {
        if (await part.exists()) {
          await part.delete();
        }
      } catch (_) {}
    }
  }

  /// Picks the HTTP transport for [url]: same-origin requests reuse
  /// ApiService.dio so its auth interceptors and ServerConfig TLS (including
  /// self-signed certificates and client certificates) apply; foreign URLs
  /// get a throwaway client carrying the eligible image headers.
  (dio.Dio, Map<String, String>, bool) _transportFor(ApiService? api, String url) {
    final baseUrl = api?.baseUrl;
    final sameOrigin =
        api != null && baseUrl != null && imageUrlIsServerOrigin(baseUrl, url);
    if (sameOrigin) {
      return (api.dio, widget.httpHeaders ?? const <String, String>{}, false);
    }
    final headers =
        widget.httpHeaders ??
        readImageHeadersForUrlFromWidgetRef(ref, url) ??
        const <String, String>{};
    return (dio.Dio(), headers, true);
  }

  String _cacheNameFor(String url) {
    final uri = Uri.tryParse(url);
    final segments = uri == null
        ? const <String>[]
        : uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    final label = segments.isEmpty
        ? 'video'
        : segments.last.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final trimmed = label.length > 48 ? label.substring(0, 48) : label;
    return '${trimmed}_${url.hashCode.toRadixString(16)}';
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

  /// Returns the file to hand to the exporter plus whether this call created
  /// it. The playback cache is reused (and must not be deleted while the
  /// player may still reference it); only freshly downloaded scratch copies
  /// are cleaned up by the caller.
  Future<(File, bool)> _localVideoForExport() async {
    final cached = _tempCacheKey;
    if (cached != null) {
      final cachedFile = File(cached);
      if (await cachedFile.exists() && await cachedFile.length() > 0) {
        return (cachedFile, false);
      }
    }
    final url = _openUrl;
    if (url == null || url.isEmpty) {
      throw StateError('Video source unavailable');
    }
    final api = ref.read(apiServiceProvider);
    final dir = await getTemporaryDirectory();
    final target = File(
      '${dir.path}/conduit_attachments/export_'
      '${DateTime.now().millisecondsSinceEpoch}.${_videoExtension()}',
    );
    await target.parent.create(recursive: true);
    final (client, headers, ownsClient) = _transportFor(api, url);
    try {
      await client.download(
        url,
        target.path,
        options: dio.Options(
          headers: headers,
          responseType: dio.ResponseType.stream,
        ),
      );
    } finally {
      // Never close ApiService.dio: it is shared with the rest of the app.
      if (ownsClient) {
        client.close(force: true);
      }
    }
    return (target, true);
  }

  Future<void> _exportVideoFile(File file, String displayName) async {
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
        return;
      }
    }
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[
          XFile(file.path, mimeType: mimeType, name: displayName),
        ],
        fileNameOverrides: <String>[displayName],
      ),
    );
  }

  Future<void> _downloadVideo() async {
    if (_saving) return;
    setState(() => _saving = true);
    final l10n = AppLocalizations.of(context)!;
    String message;
    var failed = false;
    File? exported;
    var createdNew = false;
    try {
      final (file, created) = await _localVideoForExport();
      exported = file;
      createdNew = created;
      await _exportVideoFile(file, _saveFileName());
      message = l10n.videoSaved;
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
    if (createdNew && exported != null) {
      // Scratch downloads belong to us; the playback cache may still be in
      // use by the player, so it stays put.
      try {
        await exported.delete();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _saving = false);
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: failed ? AdaptiveSnackBarType.error : AdaptiveSnackBarType.success,
    );
  }

  void _openFullscreen() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.volume == 0) {
      controller.setVolume(1);
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            _FullscreenVideoPage(controller: controller, label: _displayLabel()),
      ),
    );
  }

  String _displayLabel() {
    final hint = widget.filenameHint?.trim();
    if (hint != null && hint.isNotEmpty) return hint;
    final idOrUrl = widget.attachmentId;
    try {
      final parts = Uri.parse(idOrUrl).path.split('/').where((part) => part.isNotEmpty).toList();
      if (parts.isNotEmpty) return parts.last;
    } catch (_) {}
    return 'video';
  }

  String _formatDuration(Duration duration) => _formatVideoDuration(duration);

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final constraints =
        (widget.constraints ?? const BoxConstraints(maxWidth: 520)).copyWith(
          maxHeight: 460,
        );

    if (_initializing) {
      return ConstrainedBox(
        constraints: constraints.copyWith(minHeight: 140),
        child: Container(
          decoration: BoxDecoration(
            color: theme.cardBackground,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
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
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: _openExternally,
                ),
              if (_openUrl != null || _tempCacheKey != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: l10n.videoDownload,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded, size: 18),
                  onPressed: _saving ? null : _downloadVideo,
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
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
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
                  padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.55),
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: Icon(
                          controller.value.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                        ),
                        onPressed: _togglePlay,
                      ),
                      Expanded(
                        child: VideoProgressIndicator(
                          controller,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: Colors.white70,
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.white12,
                          ),
                        ),
                      ),
                      Text(
                        _formatDuration(controller.value.position),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: Icon(
                          muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                          color: Colors.white,
                        ),
                        onPressed: _toggleMute,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        tooltip: l10n.videoFullscreen,
                        icon: const Icon(
                          Icons.fullscreen_rounded,
                          color: Colors.white,
                        ),
                        onPressed: _openFullscreen,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        tooltip: l10n.videoDownload,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.download_rounded,
                                color: Colors.white,
                              ),
                        onPressed: _saving ? null : _downloadVideo,
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
  const _FullscreenVideoPage({required this.controller, required this.label});

  final VideoPlayerController controller;
  final String label;

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
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    final muted = controller.value.volume == 0;
    final size = controller.value.size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
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
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() {}),
              child: const SizedBox.expand(),
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
                        Colors.black.withValues(alpha: 0.6),
                        Colors.transparent,
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
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: Colors.white,
                        ),
                        onPressed: _toggleMute,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white),
                        tooltip: MaterialLocalizations.of(context)
                            .closeButtonTooltip,
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
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.6),
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          controller.value.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                        ),
                        onPressed: _togglePlay,
                      ),
                      Expanded(
                        child: VideoProgressIndicator(
                          controller,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: Colors.white70,
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.white12,
                          ),
                        ),
                      ),
                      Text(
                        _formatVideoDuration(controller.value.position),
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
