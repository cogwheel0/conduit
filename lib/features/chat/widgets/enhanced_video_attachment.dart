import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';

import '../../../core/network/image_header_utils.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';

/// Inline video player for chat attachments (generated clips, tool output).
///
/// Accepts a full URL, a server-relative path, or a bare file ID. Full URLs
/// stream directly with auth headers when available; bare IDs resolve through
/// the Files API and play from a local cached copy. Falls back to a compact
/// open-in-browser card when playback is unavailable.
class EnhancedVideoAttachment extends ConsumerStatefulWidget {
  const EnhancedVideoAttachment({
    super.key,
    required this.attachmentId,
    this.httpHeaders,
    this.constraints,
    this.filenameHint,
  });

  final String attachmentId;
  final Map<String, String>? httpHeaders;
  final BoxConstraints? constraints;
  final String? filenameHint;

  @override
  ConsumerState<EnhancedVideoAttachment> createState() =>
      _EnhancedVideoAttachmentState();
}

class _EnhancedVideoAttachmentState extends ConsumerState<EnhancedVideoAttachment>
    with WidgetsBindingObserver {
  // Keep shared temp copies alive while any player still references them.
  static final Set<String> _activeCacheKeys = <String>{};

  VideoPlayerController? _controller;
  bool _initializing = true;
  bool _playbackFailed = false;
  bool _lastPlayed = false;
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
    final cacheKey = _tempCacheKey;
    _controller = null;
    if (cacheKey != null) {
      _activeCacheKeys.remove(cacheKey);
    }
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
    if (controller != null &&
        controller.value.isInitialized &&
        controller.value.isPlaying != _lastPlayed) {
      _lastPlayed = controller.value.isPlaying;
      setState(() {});
    }
  }

  Future<void> _openVideo() async {
    final requestId = ++_openRequestId;
    final idOrUrl = widget.attachmentId.trim();
    VideoPlayerController? controller;
    String? openUrl;
    String? cacheKey;

    try {
      if (idOrUrl.isEmpty) {
        throw StateError('Empty video attachment id');
      }

      if (idOrUrl.startsWith('http://') || idOrUrl.startsWith('https://')) {
        final headers =
            (widget.httpHeaders ??
                readImageHeadersForUrlFromWidgetRef(ref, idOrUrl)) ??
            const <String, String>{};
        controller = VideoPlayerController.networkUrl(
          Uri.parse(idOrUrl),
          httpHeaders: headers,
        );
        openUrl = idOrUrl;
      } else if (idOrUrl.startsWith('/')) {
        final api = ref.read(apiServiceProvider);
        final baseUrl = api?.baseUrl;
        if (baseUrl == null) {
          throw StateError('No server origin for relative video path');
        }
        final fullUrl = '$baseUrl$idOrUrl';
        final headers =
            (widget.httpHeaders ??
                readImageHeadersForUrlFromWidgetRef(ref, fullUrl)) ??
            const <String, String>{};
        controller = VideoPlayerController.networkUrl(
          Uri.parse(fullUrl),
          httpHeaders: headers,
        );
        openUrl = fullUrl;
      } else {
        // Bare file id: resolve through the Files API and play locally.
        final api = ref.read(apiServiceProvider);
        if (api == null) {
          throw StateError('API service unavailable for video attachment');
        }
        final file = await _ensureLocalVideoFile(api, idOrUrl);
        cacheKey = file.path;
        controller = VideoPlayerController.file(file);
        openUrl = '${api.baseUrl}/api/v1/files/$idOrUrl/content';
      }

      await controller.initialize().timeout(const Duration(seconds: 30));

      if (!mounted || requestId != _openRequestId) {
        unawaited(controller.dispose());
        return;
      }

      controller.setVolume(0);
      _tempCacheKey = cacheKey;
      if (cacheKey != null) {
        _activeCacheKeys.add(cacheKey);
      }
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

  Future<File> _ensureLocalVideoFile(ApiService api, String fileId) async {
    final dir = await getTemporaryDirectory();
    final safeId = fileId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${dir.path}/conduit_attachments/video_$safeId.mp4');
    if (await file.exists() && await file.length() > 0) {
      return file;
    }

    final content = await api.getFileContent(fileId);
    List<int> bytes;
    if (_looksLikeBase64(content)) {
      bytes = base64.decode(content);
    } else {
      bytes = utf8.encode(content);
    }

    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  bool _looksLikeBase64(String value) {
    if (value.startsWith('data:')) return true;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    final candidate = trimmed.replaceAll(RegExp(r'\s+'), '');
    if (candidate.length % 4 != 0) return false;
    final binary = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
    if (!binary.hasMatch(candidate)) return false;
    if (candidate.length >= 1024) return true;
    return utf8.decode(base64.decode(candidate), allowMalformed: true).codeUnits.any(
      (unit) => unit == 0,
    );
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

  String _formatDuration(Duration duration) {
    final total = duration.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
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
