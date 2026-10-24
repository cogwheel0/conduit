import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
import '../../../shared/utils/platform_page_route.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
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

class _EnhancedVideoAttachmentState
    extends ConsumerState<EnhancedVideoAttachment>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _initializing = true;
  bool _playbackFailed = false;
  bool _lastPlayed = false;
  int _lastPositionSeconds = -1;
  bool _saving = false;
  String? _openUrl;
  int _openRequestId = 0;
  PageRoute<void>? _fullscreenRoute;
  NavigatorState? _fullscreenNav;
  _SharedVideoDownload? _activeDownload;
  dio.CancelToken? _exportToken;

  // One shared transfer per cache path, joined by every player rendering the
  // same URL; refs tracks how many live widgets still care, so the download
  // is canceled only when the last one is gone.
  static final Map<String, _SharedVideoDownload> _sharedDownloads = {};
  static int _scratchSeq = 0;
  static const Duration _downloadStallTimeout = Duration(seconds: 45);
  // Markdown links download before Play is pressed, from any host.
  static const int _maxVideoBytes = 512 * 1024 * 1024;
  // Aggregate playback cache ceiling: each distinct clip keeps a persistent
  // cache file, so the oldest unreferenced files are evicted once the video
  // cache passes this budget instead of accumulating until the OS clears it.
  static const int _maxVideoCacheBytes = 1024 * 1024 * 1024;
  static final Map<String, int> _cacheRefs = {};
  static bool _pruning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _openVideo();
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
    // The fullscreen page renders this controller, so close it first.
    _retireFullscreen();
    _releaseSharedDownload();
    _exportToken?.cancel('video source changed');
    final previous = _controller;
    previous?.removeListener(_onControllerChanged);
    _controller = null;
    _releaseCachePath(_tempCacheKey);
    _tempCacheKey = null;
    _openUrl = null;
    _initializing = true;
    _playbackFailed = false;
    if (previous != null) unawaited(previous.dispose());
    _openVideo();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retireFullscreen();
    _releaseSharedDownload();
    _exportToken?.cancel('video widget disposed');
    final controller = _controller;
    _controller = null;
    _releaseCachePath(_tempCacheKey);
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

  void _retireFullscreen() {
    final route = _fullscreenRoute;
    if (route == null || !route.isActive) return;
    // The fullscreen viewer renders this widget's controller; close it before
    // the controller is disposed out from under the open route.
    _fullscreenNav?.pop();
  }

  void _retainCachePath(String? path) {
    if (path == null) return;
    _cacheRefs[path] = (_cacheRefs[path] ?? 0) + 1;
  }

  void _releaseCachePath(String? path) {
    if (path == null) return;
    final refs = (_cacheRefs[path] ?? 1) - 1;
    if (refs <= 0) {
      _cacheRefs.remove(path);
    } else {
      _cacheRefs[path] = refs;
    }
  }

  /// Evicts the oldest completed playback files once the video cache passes
  /// the aggregate budget, skipping files live players or in-flight shared
  /// transfers still reference.
  static Future<void> _pruneVideoCache(Directory dir) async {
    if (_pruning) return;
    _pruning = true;
    try {
      if (!dir.existsSync()) return;
      final candidates = <({File file, int size, DateTime modified})>[];
      int total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('video_')) continue;
        if (_cacheRefs.containsKey(entity.path) ||
            _sharedDownloads.containsKey(entity.path)) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.size <= 0) continue;
        candidates.add((
          file: entity,
          size: stat.size,
          modified: stat.modified,
        ));
        total += stat.size;
      }
      if (total <= _maxVideoCacheBytes) return;
      candidates.sort((a, b) => a.modified.compareTo(b.modified));
      for (final candidate in candidates) {
        if (total <= _maxVideoCacheBytes) break;
        // A player may have opened (or a transfer may have finished into)
        // this file after the scan; re-verify before deleting it.
        if (_cacheRefs.containsKey(candidate.file.path) ||
            _sharedDownloads.containsKey(candidate.file.path)) {
          continue;
        }
        try {
          await candidate.file.delete();
          total -= candidate.size;
        } catch (_) {}
      }
    } catch (_) {
      // Cache bookkeeping must never break playback.
    } finally {
      _pruning = false;
    }
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
      // No fixed total-download deadline: large videos are fine as long as
      // data keeps arriving (a stall watchdog inside the transfer handles
      // dead connections).
      final file = await _downloadToLocalVideo(api, openUrl, requestId);
      downloadedPath = file.path;
      controller = VideoPlayerController.file(file);

      await controller.initialize().timeout(const Duration(seconds: 30));

      if (!mounted || requestId != _openRequestId) {
        // Nobody will hold this path: give the reservation back to the prune.
        _releaseCachePath(file.path);
        unawaited(controller.dispose());
        return;
      }

      controller.setVolume(0);
      // Reserved by _downloadToLocalVideo; dispose() releases this handle.
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
      // A full download can succeed while the player still fails to
      // initialize; keep the completed cache copy so the fallback export
      // reuses it instead of fetching the same video again.
      if (downloadedPath != null) {
        if (mounted && requestId == _openRequestId) {
          // _downloadToLocalVideo already reserved the path; keep the handle
          // so the fallback export reuses the completed cache copy.
          _tempCacheKey = downloadedPath;
        } else {
          // Disposed mid-initialize: dispose() had no handle to release, so
          // drop the reservation here instead of leaking it forever.
          _releaseCachePath(downloadedPath);
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

  /// Returns the local cache copy for [url], sharing one in-flight transfer
  /// per cache key: two players rendering the same clip join the same
  /// download instead of racing on the same scratch file. The transfer
  /// lands on a transfer-unique scratch path and is renamed only after a
  /// complete download, so a canceled or stale request never clobbers a
  /// live one and never leaves a half-written file that a later length() > 0
  /// cache hit would accept.
  Future<File> _downloadToLocalVideo(
    ApiService? api,
    String url,
    int requestId,
  ) async {
    final extension = _videoExtension();
    // Open WebUI file URLs are the same for every account on a server, so
    // the cache name carries the account-scoped key the image cache uses.
    final cacheIdentity =
        buildImageCacheKeyForUrlFromContainer(
          ProviderScope.containerOf(context, listen: false),
          url,
          effectiveHeaders: widget.httpHeaders,
        ) ??
        url;
    final dir = await getTemporaryDirectory();
    final target = File(
      '${dir.path}/conduit_attachments/'
      'video_${_cacheNameFor(url, cacheIdentity)}.$extension',
    );
    if (await target.exists() && await target.length() > 0) {
      // Reserve before returning: player initialization awaits afterwards,
      // and a prune from another widget must not evict this file mid-open.
      _retainCachePath(target.path);
      return target;
    }
    await target.parent.create(recursive: true);

    // If the widget was disposed during the awaits above, `dispose` could
    // not have released anything (no download was tracked yet). Stop before
    // joining or starting a transfer nobody would ever release; `_openVideo`
    // ignores errors for unmounted widgets.
    if (!mounted || requestId != _openRequestId) {
      // Disposed, or a replaced source already started a newer open: never
      // release or join transfers on behalf of a stale attempt.
      throw dio.DioException(
        requestOptions: dio.RequestOptions(path: url),
        message: 'Video open attempt is no longer current',
      );
    }

    // This widget can only be interested in one playback transfer at a
    // time; drop interest in any earlier attempt before joining a new one.
    _releaseSharedDownload();
    final key = target.path;
    var entry = _sharedDownloads[key];
    if (entry != null && entry.token.isCancelled) {
      // A canceled transfer is never reusable: a player reopening the video
      // must start a fresh download, not join the dying one.
      _sharedDownloads.remove(key);
      entry = null;
    }
    if (entry == null) {
      entry = _SharedVideoDownload(dio.CancelToken(), key);
      entry.refs = 1;
      final created = entry;
      created.future = _runVideoDownload(api, url, target, created.token)
          .whenComplete(() {
            if (_sharedDownloads[key] == created) {
              _sharedDownloads.remove(key);
            }
          });
      _sharedDownloads[key] = entry;
    } else {
      entry.refs += 1;
    }
    _activeDownload = entry;
    File downloaded;
    try {
      downloaded = await entry.future;
    } finally {
      // This attempt's transfer is finished; forget it so a later dispose
      // cannot decrement references on a newer transfer for the same key.
      if (_activeDownload == entry) {
        _activeDownload = null;
      }
    }
    // Reserve before handing the file to the player: the shared transfer
    // is gone from the registry, and _openVideo awaits initialize().
    _retainCachePath(downloaded.path);
    return downloaded;
  }

  Future<File> _runVideoDownload(
    ApiService? api,
    String url,
    File target,
    dio.CancelToken token,
  ) async {
    final part = File('${target.path}.${_scratchSeq++}.part');
    final (client, headers, ownsClient) = _transportFor(api, url);
    try {
      await _streamToFile(client, url, part.path, headers, token);
      await part.rename(target.path);
      unawaited(_pruneVideoCache(target.parent));
      return target;
    } finally {
      // Never close ApiService.dio: it is shared with the rest of the app.
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

  /// Downloads [url] to [path] with a stalled-transfer watchdog instead of a
  /// fixed total-transfer deadline: the request is aborted only when no data
  /// arrives for [_downloadStallTimeout] (45s) or the headers never arrive
  /// (60s), not because the file is large. Cancelable via [token].
  Future<void> _streamToFile(
    dio.Dio client,
    String url,
    String path,
    Map<String, String> headers,
    dio.CancelToken token,
  ) async {
    var lastChunkAt = DateTime.now();
    final watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (DateTime.now().difference(lastChunkAt) > _downloadStallTimeout) {
        token.cancel('video download stalled');
      }
    });
    try {
      await client.download(
        url,
        path,
        cancelToken: token,
        onReceiveProgress: (received, total) {
          lastChunkAt = DateTime.now();
          if (received > _maxVideoBytes) {
            token.cancel('video exceeds size limit');
          }
        },
        options: dio.Options(
          headers: headers,
          responseType: dio.ResponseType.stream,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );
    } finally {
      watchdog.cancel();
    }
  }

  /// Drops this widget's interest in its shared download; the transfer is
  /// canceled only when the last interested player is gone. The shared
  /// Dio client is never closed here.
  void _releaseSharedDownload() {
    final entry = _activeDownload;
    if (entry == null) return;
    _activeDownload = null;
    entry.refs -= 1;
    if (entry.refs <= 0) {
      // Retire the entry immediately so a reopening player cannot join a
      // transfer that is about to be canceled.
      if (_sharedDownloads[entry.key] == entry) {
        _sharedDownloads.remove(entry.key);
      }
      entry.token.cancel('video player disposed');
    }
  }

  /// Picks the HTTP transport for [url]: same-origin requests reuse
  /// ApiService.dio so its auth interceptors and ServerConfig TLS (including
  /// self-signed certificates and client certificates) apply; foreign URLs
  /// get a throwaway client carrying the eligible image headers.
  (dio.Dio, Map<String, String>, bool) _transportFor(
    ApiService? api,
    String url,
  ) {
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

  String _cacheNameFor(String url, String cacheIdentity) {
    final uri = Uri.tryParse(url);
    final segments = uri == null
        ? const <String>[]
        : uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    final label = segments.isEmpty
        ? 'video'
        : segments.last.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final trimmed = label.length > 48 ? label.substring(0, 48) : label;
    final digest = sha256.convert(utf8.encode(cacheIdentity)).toString();
    return '${trimmed}_${digest.substring(0, 32)}';
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
    // Disposed during the awaits above: dispose had no token to cancel, so a
    // transfer started now could never be stopped.
    if (!mounted) {
      throw dio.DioException(
        requestOptions: dio.RequestOptions(path: url),
        message: 'Video widget was disposed',
      );
    }
    final token = dio.CancelToken();
    _exportToken = token;
    final (client, headers, ownsClient) = _transportFor(api, url);
    try {
      await _streamToFile(client, url, target.path, headers, token);
    } catch (error) {
      // A stall, network error, or dispose-time cancel can leave a partial
      // copy of a potentially large video; delete it instead of leaving it
      // for the OS to clear.
      try {
        if (await target.exists()) {
          await target.delete();
        }
      } catch (_) {}
      rethrow;
    } finally {
      // Never close ApiService.dio: it is shared with the rest of the app.
      if (ownsClient) {
        client.close(force: true);
      }
      if (_exportToken == token) {
        _exportToken = null;
      }
    }
    return (target, true);
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
        // The user closed the share sheet: nothing was saved, but this is
        // not a failure either — the caller must not claim success.
        return false;
      case ShareResultStatus.unavailable:
        throw StateError('Video share is unavailable on this platform');
    }
  }

  Future<void> _downloadVideo() async {
    if (_saving) return;
    setState(() => _saving = true);
    final l10n = AppLocalizations.of(context)!;
    String? message;
    var failed = false;
    File? exported;
    var createdNew = false;
    final sourceUrlAtStart = _openUrl;
    try {
      final (file, created) = await _localVideoForExport();
      exported = file;
      createdNew = created;
      // Disposed while fetching, or a replaced source changed under the
      // export: the selected file belongs to the previous clip and must not
      // be delivered under the new filename. Scratch cleanup still runs.
      if (!mounted || _openUrl != sourceUrlAtStart) {
        throw StateError('Video source changed during export');
      }
      final confirmed = await _exportVideoFile(file, _saveFileName());
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
    if (createdNew && exported != null) {
      // Scratch downloads belong to us; the playback cache may still be in
      // use by the player, so it stays put.
      try {
        await exported.delete();
      } catch (_) {}
    }
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
      builder: (_) =>
          _FullscreenVideoPage(controller: controller, label: _displayLabel()),
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
            child: AdaptiveProgressIndicator(strokeWidth: 2),
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
                ConduitIconButton(
                  icon: Icons.open_in_new,
                  tooltip: l10n.videoOpenInBrowser,
                  isCompact: true,
                  onPressed: _openExternally,
                ),
              if (_openUrl != null || _tempCacheKey != null)
                _saving
                    ? const _VideoSavingIndicator()
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
                          ? const _VideoSavingIndicator(color: _videoForeground)
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
    // MainActivity enables edge-to-edge; manual mode would drop it on
    // Android 14 and older. An empty list restores the app's orientations.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
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

/// Stands in for a download button while its save runs, at the same size.
class _VideoSavingIndicator extends StatelessWidget {
  const _VideoSavingIndicator({this.color});

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

/// One in-flight video download shared by every player that requested the
/// same cache path. Cancel happens only when the last interested widget is
/// disposed; the shared Dio client itself is never closed.
class _SharedVideoDownload {
  _SharedVideoDownload(this.token, this.key);

  final dio.CancelToken token;
  final String key;
  late final Future<File> future;
  int refs = 0;
}
