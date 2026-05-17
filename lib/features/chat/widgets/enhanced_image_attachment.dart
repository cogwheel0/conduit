import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:dio/dio.dart' as dio;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_page_route.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/providers/app_providers.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/network/self_signed_image_cache_manager.dart';
import '../../../core/network/image_header_utils.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/performance_profiler.dart';
import '../../../core/services/worker_manager.dart';

final _base64WhitespacePattern = RegExp(r'\s');
final _imageAttachmentCaches = _ImageAttachmentCaches();

/// Pre-cache image bytes for instant display after upload.
/// Call this with the server file ID and image bytes after successful upload.
void preCacheImageBytes(String fileId, Uint8List bytes) {
  if (fileId.isEmpty || bytes.isEmpty) return;
  _imageAttachmentCaches.cacheBytes(fileId, bytes);
}

@visibleForTesting
void debugResetImageAttachmentCaches() => _imageAttachmentCaches.clear();

@visibleForTesting
void debugSeedResolvedImageAttachment(
  String attachmentId,
  String resolvedData,
) {
  _imageAttachmentCaches.debugSeedResolvedData(attachmentId, resolvedData);
}

@visibleForTesting
bool debugHasResolvedImageAttachment(String attachmentId) {
  return _imageAttachmentCaches.hasResolvedData(attachmentId);
}

@visibleForTesting
bool debugHasDecodedImageAttachment(String attachmentId) {
  return _imageAttachmentCaches.hasDecodedBytes(attachmentId);
}

@visibleForTesting
Future<void> debugDecodeCachedResolvedImageAttachment({
  required String attachmentId,
  required WorkerManager workerManager,
}) async {
  await _imageAttachmentCaches.decodeCachedResolvedDataForTesting(
    attachmentId: attachmentId,
    workerManager: workerManager,
  );
}

@visibleForTesting
Future<String?> debugDecodeCachedResolvedImageAttachmentError({
  required String attachmentId,
  required WorkerManager workerManager,
  required AppLocalizations l10n,
}) async {
  final result = await _guardImageLoadFailure(
    attachmentId: attachmentId,
    l10n: l10n,
    load: () async {
      await _imageAttachmentCaches.decodeCachedResolvedDataForTesting(
        attachmentId: attachmentId,
        workerManager: workerManager,
      );
      return _imageAttachmentCaches.readCached(attachmentId) ??
          const _ImageLoadResult(isSvg: false);
    },
  );
  return result.error;
}

@visibleForTesting
Future<String?> debugLoadImageAttachmentError({
  required String attachmentId,
  required WorkerManager workerManager,
  required AppLocalizations l10n,
}) async {
  final result = await _guardImageLoadFailure(
    attachmentId: attachmentId,
    l10n: l10n,
    load: () => _imageAttachmentCaches.load(
      attachmentId: attachmentId,
      workerManager: workerManager,
      api: null,
      l10n: l10n,
    ),
  );
  return result.error;
}

@visibleForTesting
int debugResolvedImageAttachmentCount() {
  return _imageAttachmentCaches.resolvedDataCount;
}

Uint8List _decodeImageData(String data) {
  var payload = data;
  if (payload.startsWith('data:')) {
    final commaIndex = payload.indexOf(',');
    if (commaIndex == -1) {
      throw FormatException('Invalid data URI');
    }
    payload = payload.substring(commaIndex + 1);
  }
  payload = payload.replaceAll(_base64WhitespacePattern, '');
  return base64.decode(payload);
}

/// Checks if data URL or content indicates SVG format.
bool _isSvgDataUrl(String data) {
  final lower = data.toLowerCase();
  return lower.startsWith('data:image/svg+xml');
}

/// Checks if a URL points to an SVG file.
bool _isSvgUrl(String url) {
  final lowerUrl = url.toLowerCase();

  // Check for .svg file extension (with or without query string)
  final queryIndex = lowerUrl.indexOf('?');
  final pathPart = queryIndex >= 0
      ? lowerUrl.substring(0, queryIndex)
      : lowerUrl;
  if (pathPart.endsWith('.svg')) return true;

  // Check for SVG MIME type in query parameters only (not in path)
  // This handles cases like ?format=image/svg+xml or &type=image/svg+xml
  if (queryIndex >= 0) {
    final queryPart = lowerUrl.substring(queryIndex);
    if (queryPart.contains('image/svg+xml')) return true;
  }

  return false;
}

/// Checks if decoded bytes represent SVG content by looking for the SVG tag.
bool _isSvgBytes(Uint8List bytes) {
  // Check first 1KB for SVG tag (not just XML declaration, which is too broad)
  final checkLength = bytes.length < 1024 ? bytes.length : 1024;
  final header = utf8.decode(
    bytes.sublist(0, checkLength),
    allowMalformed: true,
  );
  return header.toLowerCase().contains('<svg');
}

bool _isRemoteContentValue(String data) => data.startsWith('http');

class _LruCache<K, V> {
  _LruCache({required this.maxEntries});

  final int maxEntries;
  final LinkedHashMap<K, V> _entries = LinkedHashMap<K, V>();

  V? read(K key) {
    final value = _entries.remove(key);
    if (value == null) {
      return null;
    }
    _entries[key] = value;
    return value;
  }

  void write(K key, V value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(K key) {
    _entries.remove(key);
  }

  void removeIfSame(K key, V value) {
    final existing = _entries[key];
    if (identical(existing, value)) {
      _entries.remove(key);
    }
  }

  void clear() {
    _entries.clear();
  }

  bool containsKey(K key) => _entries.containsKey(key);

  int get length => _entries.length;
}

class _ImageLoadResult {
  const _ImageLoadResult({
    this.resolvedData,
    this.bytes,
    this.error,
    required this.isSvg,
  });

  final String? resolvedData;
  final Uint8List? bytes;
  final String? error;
  final bool isSvg;

  bool get hasContent => resolvedData != null || bytes != null || error != null;
  bool get needsDecode =>
      error == null &&
      bytes == null &&
      resolvedData != null &&
      !_isRemoteContentValue(resolvedData!);
}

class _ImageAttachmentCaches {
  _ImageAttachmentCaches();

  static const int _resolvedDataEntries = 80;
  static const int _byteEntries = 48;
  static const int _metadataEntries = 96;
  static const int _errorEntries = 48;
  static const int _inFlightEntries = 24;

  final _LruCache<String, String> _resolvedData = _LruCache<String, String>(
    maxEntries: _resolvedDataEntries,
  );
  final _LruCache<String, Uint8List> _decodedBytes =
      _LruCache<String, Uint8List>(maxEntries: _byteEntries);
  final _LruCache<String, bool> _svgFlags = _LruCache<String, bool>(
    maxEntries: _metadataEntries,
  );
  final _LruCache<String, String> _errors = _LruCache<String, String>(
    maxEntries: _errorEntries,
  );
  final _LruCache<String, Future<_ImageLoadResult>> _inFlightLoads =
      _LruCache<String, Future<_ImageLoadResult>>(maxEntries: _inFlightEntries);

  _ImageLoadResult? readCached(String attachmentId) {
    final error = _errors.read(attachmentId);
    if (error != null) {
      return _ImageLoadResult(
        error: error,
        isSvg: _svgFlags.read(attachmentId) ?? false,
      );
    }

    final data = _resolvedData.read(attachmentId);
    final bytes = _decodedBytes.read(attachmentId);
    final isSvg = _svgFlags.read(attachmentId) ?? false;
    if (data == null && bytes == null) {
      return null;
    }
    return _ImageLoadResult(resolvedData: data, bytes: bytes, isSvg: isSvg);
  }

  void cacheBytes(String attachmentId, Uint8List bytes) {
    _errors.remove(attachmentId);
    _decodedBytes.write(attachmentId, bytes);
    _svgFlags.write(attachmentId, _isSvgBytes(bytes));
  }

  void cacheError(String attachmentId, String error) {
    _errors.write(attachmentId, error);
    _resolvedData.remove(attachmentId);
    _decodedBytes.remove(attachmentId);
    _svgFlags.remove(attachmentId);
  }

  void clear() {
    _resolvedData.clear();
    _decodedBytes.clear();
    _svgFlags.clear();
    _errors.clear();
    _inFlightLoads.clear();
  }

  void debugSeedResolvedData(String attachmentId, String resolvedData) {
    _errors.remove(attachmentId);
    _resolvedData.write(attachmentId, resolvedData);
    _svgFlags.write(attachmentId, _isSvgDataUrl(resolvedData));
  }

  bool hasResolvedData(String attachmentId) {
    return _resolvedData.containsKey(attachmentId);
  }

  bool hasDecodedBytes(String attachmentId) {
    return _decodedBytes.containsKey(attachmentId);
  }

  int get resolvedDataCount => _resolvedData.length;

  Future<_ImageLoadResult> decodeCachedResolvedDataForTesting({
    required String attachmentId,
    required WorkerManager workerManager,
  }) {
    final cached = readCached(attachmentId);
    if (cached == null || !cached.needsDecode || cached.resolvedData == null) {
      throw StateError(
        'No decodable cached resolved data exists for $attachmentId',
      );
    }
    return _decodeResolvedDataWithWorker(
      attachmentId: attachmentId,
      worker: workerManager,
      source: cached.resolvedData!,
      svgHint: cached.isSvg,
    );
  }

  Future<_ImageLoadResult> load({
    required String attachmentId,
    required WorkerManager workerManager,
    required ApiService? api,
    required AppLocalizations l10n,
  }) {
    final cached = readCached(attachmentId);
    if (cached != null &&
        (!cached.needsDecode || cached.bytes != null || cached.error != null)) {
      return Future<_ImageLoadResult>.value(cached);
    }

    final inFlight = _inFlightLoads.read(attachmentId);
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<_ImageLoadResult> future;
    future = () async {
      try {
        return await _loadInternal(
          attachmentId: attachmentId,
          workerManager: workerManager,
          api: api,
          l10n: l10n,
          cached: cached,
        );
      } finally {
        _inFlightLoads.removeIfSame(attachmentId, future);
      }
    }();
    _inFlightLoads.write(attachmentId, future);
    return future;
  }

  Future<_ImageLoadResult> _loadInternal({
    required String attachmentId,
    required WorkerManager workerManager,
    required ApiService? api,
    required AppLocalizations l10n,
    _ImageLoadResult? cached,
  }) async {
    if (cached?.bytes != null) {
      return cached!;
    }

    if (cached?.needsDecode == true && cached?.resolvedData != null) {
      return _decodeResolvedData(
        attachmentId: attachmentId,
        workerManager: workerManager,
        source: cached!.resolvedData!,
        svgHint: cached.isSvg,
      );
    }

    if (attachmentId.startsWith('data:') || attachmentId.startsWith('http')) {
      final isSvgContent =
          _isSvgDataUrl(attachmentId) || _isSvgUrl(attachmentId);
      _resolvedData.write(attachmentId, attachmentId);
      _svgFlags.write(attachmentId, isSvgContent);
      if (_isRemoteContentValue(attachmentId)) {
        _errors.remove(attachmentId);
        return _ImageLoadResult(
          resolvedData: attachmentId,
          isSvg: isSvgContent,
        );
      }
      return _decodeResolvedData(
        attachmentId: attachmentId,
        workerManager: workerManager,
        source: attachmentId,
        svgHint: isSvgContent,
      );
    }

    if (attachmentId.startsWith('/')) {
      if (api == null) {
        final error = l10n.unableToLoadImage;
        cacheError(attachmentId, error);
        return _ImageLoadResult(error: error, isSvg: false);
      }
      final fullUrl = api.baseUrl + attachmentId;
      final isSvgContent = _isSvgUrl(fullUrl);
      _resolvedData.write(attachmentId, fullUrl);
      _svgFlags.write(attachmentId, isSvgContent);
      _errors.remove(attachmentId);
      return _ImageLoadResult(resolvedData: fullUrl, isSvg: isSvgContent);
    }

    if (api == null) {
      final error = l10n.apiUnavailable;
      cacheError(attachmentId, error);
      return _ImageLoadResult(error: error, isSvg: false);
    }

    try {
      final fileInfo = await api.getFileInfo(attachmentId);
      final fileName = _extractFileName(fileInfo);
      final ext = fileName.toLowerCase().split('.').last;
      final contentType =
          (fileInfo['meta']?['content_type'] ?? fileInfo['content_type'] ?? '')
              .toString()
              .toLowerCase();

      final isImageByExt = [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'svg',
        'bmp',
      ].contains(ext);
      final isImageByContentType = contentType.startsWith('image/');
      if (!isImageByExt && !isImageByContentType) {
        final error = l10n.notAnImageFile(fileName);
        cacheError(attachmentId, error);
        return _ImageLoadResult(error: error, isSvg: false);
      }

      final isSvgFile = ext == 'svg' || contentType.contains('svg');
      final fileContent = await api.getFileContent(attachmentId);
      _resolvedData.write(attachmentId, fileContent);
      _svgFlags.write(attachmentId, isSvgFile);
      _errors.remove(attachmentId);

      if (_isRemoteContentValue(fileContent)) {
        return _ImageLoadResult(resolvedData: fileContent, isSvg: isSvgFile);
      }

      return _decodeResolvedData(
        attachmentId: attachmentId,
        workerManager: workerManager,
        source: fileContent,
        svgHint: isSvgFile,
      );
    } catch (error) {
      final message = l10n.failedToLoadImage(error.toString());
      cacheError(attachmentId, message);
      return _ImageLoadResult(error: message, isSvg: false);
    }
  }

  Future<_ImageLoadResult> _decodeResolvedData({
    required String attachmentId,
    required WorkerManager workerManager,
    required String source,
    required bool svgHint,
  }) async {
    return _decodeResolvedDataWithWorker(
      attachmentId: attachmentId,
      worker: workerManager,
      source: source,
      svgHint: svgHint,
    );
  }
}

Future<_ImageLoadResult> _decodeResolvedDataWithWorker({
  required String attachmentId,
  required WorkerManager worker,
  required String source,
  required bool svgHint,
}) async {
  final bytes = await worker.schedule<String, Uint8List>(
    _decodeImageData,
    source,
    debugLabel: 'decode_image',
  );
  _imageAttachmentCaches.cacheBytes(attachmentId, bytes);
  final isSvg = _isSvgBytes(bytes) || _isSvgDataUrl(source) || svgHint;
  _imageAttachmentCaches._svgFlags.write(attachmentId, isSvg);
  _imageAttachmentCaches._errors.remove(attachmentId);
  return _ImageLoadResult(resolvedData: source, bytes: bytes, isSvg: isSvg);
}

Future<_ImageLoadResult> _guardImageLoadFailure({
  required String attachmentId,
  required AppLocalizations l10n,
  required Future<_ImageLoadResult> Function() load,
}) async {
  try {
    return await load();
  } catch (_) {
    final decodeError = l10n.failedToDecodeImage;
    _imageAttachmentCaches.cacheError(attachmentId, decodeError);
    return _ImageLoadResult(error: decodeError, isSvg: false);
  }
}

String _extractFileName(Map<String, dynamic> fileInfo) {
  return fileInfo['filename'] ??
      fileInfo['meta']?['name'] ??
      fileInfo['name'] ??
      fileInfo['file_name'] ??
      fileInfo['original_name'] ??
      fileInfo['original_filename'] ??
      'unknown';
}

Map<String, String>? _mergeHeaders(
  Map<String, String>? defaults,
  Map<String, String>? overrides,
) {
  if ((defaults == null || defaults.isEmpty) &&
      (overrides == null || overrides.isEmpty)) {
    return null;
  }
  return {...?defaults, ...?overrides};
}

class EnhancedImageAttachment extends ConsumerStatefulWidget {
  final String attachmentId;
  final bool isMarkdownFormat;
  final VoidCallback? onTap;
  final BoxConstraints? constraints;
  final bool isUserMessage;
  final bool disableAnimation;
  final Map<String, String>? httpHeaders;

  const EnhancedImageAttachment({
    super.key,
    required this.attachmentId,
    this.isMarkdownFormat = false,
    this.onTap,
    this.constraints,
    this.isUserMessage = false,
    this.disableAnimation = false,
    this.httpHeaders,
  });

  @override
  ConsumerState<EnhancedImageAttachment> createState() =>
      _EnhancedImageAttachmentState();
}

class _EnhancedImageAttachmentState
    extends ConsumerState<EnhancedImageAttachment>
    with AutomaticKeepAliveClientMixin {
  String? _cachedImageData;
  Uint8List? _cachedBytes;
  bool _isLoading = true;
  String? _errorMessage;
  bool _isSvg = false;
  late String _heroTag;
  bool _hasAttemptedLoad = false;
  bool _loadScheduled = false;
  bool _retryLoadScheduled = false;
  int _loadGeneration = 0;
  Timer? _retryLoadTimer;

  String get _profileImageKey =>
      widget.attachmentId.hashCode.toUnsigned(32).toRadixString(16);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _heroTag = 'image_${widget.attachmentId}_${identityHashCode(this)}';
    // Defer loading until after first frame to avoid accessing inherited widgets
    // (e.g., Localizations) during initState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scheduleLoadIfNeeded();
    });
  }

  @override
  void didUpdateWidget(covariant EnhancedImageAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the attachment ID changed, reload the image
    if (oldWidget.attachmentId != widget.attachmentId) {
      _heroTag = 'image_${widget.attachmentId}_${identityHashCode(this)}';
      // Reset local state with setState for immediate visual feedback
      setState(() {
        _cachedImageData = null;
        _cachedBytes = null;
        _hasAttemptedLoad = false;
        _isLoading = true;
        _errorMessage = null;
        _isSvg = false;
      });
      _loadGeneration += 1;
      _retryLoadTimer?.cancel();
      _loadScheduled = false;
      _retryLoadScheduled = false;
      // Load the new image
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scheduleLoadIfNeeded();
      });
    }
  }

  @override
  void dispose() {
    _loadGeneration += 1;
    _retryLoadTimer?.cancel();
    super.dispose();
  }

  void _scheduleLoadIfNeeded({bool immediate = false}) {
    if (_hasAttemptedLoad || _loadScheduled) {
      return;
    }

    if (!immediate && Scrollable.recommendDeferredLoadingForContext(context)) {
      if (_retryLoadScheduled) {
        return;
      }
      _retryLoadScheduled = true;
      _retryLoadTimer?.cancel();
      _retryLoadTimer = Timer(const Duration(milliseconds: 250), () {
        if (!mounted) {
          return;
        }
        _retryLoadScheduled = false;
        _scheduleLoadIfNeeded();
      });
      return;
    }

    _retryLoadScheduled = false;
    _loadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadScheduled = false;
      if (!mounted) {
        return;
      }
      unawaited(_loadImage());
    });
  }

  Future<void> _loadImage() async {
    if (_hasAttemptedLoad) {
      return;
    }

    final cached = _imageAttachmentCaches.readCached(widget.attachmentId);
    if (cached != null) {
      _applyLoadResult(cached);
      if (!cached.needsDecode) {
        _hasAttemptedLoad = true;
        PerformanceProfiler.instance.instant(
          'image_cache_hit',
          scope: 'image',
          data: {
            'imageKey': _profileImageKey,
            'hasBytes': cached.bytes != null,
            'hasError': cached.error != null,
          },
        );
        return;
      }
    }

    _hasAttemptedLoad = true;
    final requestGeneration = ++_loadGeneration;
    var loadSource = cached == null ? 'cache_miss' : 'cache_decode';
    final taskKey = PerformanceProfiler.instance.startTask(
      'image_load',
      scope: 'image',
      key: 'image-load:$_profileImageKey:${identityHashCode(this)}',
      data: {
        'imageKey': _profileImageKey,
        'attachmentLength': widget.attachmentId.length,
      },
    );

    try {
      final l10n = AppLocalizations.of(context)!;
      final result = await _guardImageLoadFailure(
        attachmentId: widget.attachmentId,
        l10n: l10n,
        load: () => _imageAttachmentCaches.load(
          attachmentId: widget.attachmentId,
          workerManager: ref.read(workerManagerProvider),
          api: ref.read(apiServiceProvider),
          l10n: l10n,
        ),
      );
      if (!mounted || requestGeneration != _loadGeneration) {
        return;
      }

      loadSource = result.error != null
          ? 'error'
          : result.bytes != null
          ? 'decoded'
          : result.resolvedData != null &&
                _isRemoteContent(result.resolvedData!)
          ? 'remote'
          : 'resolved';
      _applyLoadResult(result);
    } finally {
      PerformanceProfiler.instance.finishTask(
        taskKey,
        data: {
          'imageKey': _profileImageKey,
          'source': loadSource,
          'hasBytes': _cachedBytes != null,
          'hasError': _errorMessage != null,
          'isSvg': _isSvg,
        },
      );
    }
  }

  void _applyLoadResult(_ImageLoadResult result) {
    if (!mounted) {
      return;
    }
    setState(() {
      _cachedImageData = result.resolvedData;
      _cachedBytes = result.bytes;
      _errorMessage = result.error;
      _isSvg = result.isSvg;
      _isLoading =
          result.error == null &&
          result.bytes == null &&
          result.resolvedData != null &&
          !_isRemoteContent(result.resolvedData!);
    });
  }

  bool _isRemoteContent(String data) => _isRemoteContentValue(data);

  ({int? width, int? height}) _cacheDimensions(BuildContext context) {
    final constraints =
        widget.constraints ??
        const BoxConstraints(maxWidth: 400, maxHeight: 400);
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

    int? normalize(double value) {
      if (!value.isFinite || value <= 0) {
        return null;
      }
      return (value * devicePixelRatio).round().clamp(64, 2048);
    }

    return (
      width: normalize(constraints.maxWidth),
      height: normalize(constraints.maxHeight),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    if (!_hasAttemptedLoad && !_loadScheduled) {
      _scheduleLoadIfNeeded();
    }

    // Directly return content without AnimatedSwitcher to prevent black flash during streaming
    return _buildContent();
  }

  Widget _buildContent() {
    if (_isLoading) {
      return _buildLoadingState();
    }

    if (_errorMessage != null) {
      return _buildErrorState();
    }

    if (_cachedImageData == null && _cachedBytes == null) {
      // No data available - this shouldn't happen in normal flow since
      // _loadImage always sets either data, bytes, or error before completing.
      // Show error state rather than attempting reload from build().
      return _buildErrorState();
    }

    // If we have bytes but no cached data string, use bytes directly
    if (_cachedImageData == null && _cachedBytes != null) {
      return _isSvg ? _buildBase64Svg() : _buildBase64Image();
    }

    // Handle different image data formats
    // Include fallback URL/data detection to match FullScreenImageViewer behavior
    Widget imageWidget;
    if (_cachedImageData!.startsWith('http')) {
      final isSvgContent = _isSvg || _isSvgUrl(_cachedImageData!);
      imageWidget = isSvgContent ? _buildNetworkSvg() : _buildNetworkImage();
    } else {
      final isSvgContent = _isSvg || _isSvgDataUrl(_cachedImageData!);
      imageWidget = isSvgContent ? _buildBase64Svg() : _buildBase64Image();
    }

    // Always show the image without fade transitions during streaming to prevent black display
    // The AutomaticKeepAliveClientMixin and global caching should preserve the image state
    return imageWidget;
  }

  Widget _buildLoadingState() {
    final constraints =
        widget.constraints ??
        const BoxConstraints(
          maxWidth: 300,
          maxHeight: 300,
          minHeight: 150,
          minWidth: 200,
        );

    return Container(
      key: const ValueKey('loading'),
      constraints: constraints,
      margin: const EdgeInsets.only(bottom: Spacing.xs),
      decoration: BoxDecoration(
        color: context.conduitTheme.surfaceBackground.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        border: Border.all(
          color: context.conduitTheme.dividerColor.withValues(alpha: 0.3),
          width: BorderWidth.thin,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Shimmer effect placeholder
          Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppBorderRadius.md),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      context.conduitTheme.shimmerBase,
                      context.conduitTheme.shimmerHighlight,
                      context.conduitTheme.shimmerBase,
                    ],
                  ),
                ),
              )
              .animate(onPlay: (controller) => controller.repeat())
              .shimmer(
                duration: const Duration(milliseconds: 1500),
                color: context.conduitTheme.shimmerHighlight.withValues(
                  alpha: 0.3,
                ),
              ),
          // Progress indicator overlay
          CircularProgressIndicator(
            color: context.conduitTheme.buttonPrimary,
            strokeWidth: 2,
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Container(
      key: const ValueKey('error'),
      constraints:
          widget.constraints ??
          const BoxConstraints(
            maxWidth: 300,
            maxHeight: 150,
            minHeight: 100,
            minWidth: 200,
          ),
      margin: const EdgeInsets.only(bottom: Spacing.xs),
      decoration: BoxDecoration(
        color: context.conduitTheme.surfaceBackground.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        border: Border.all(
          color: context.conduitTheme.error.withValues(alpha: 0.3),
          width: BorderWidth.thin,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image_outlined,
            color: context.conduitTheme.error,
            size: 32,
          ),
          const SizedBox(height: Spacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: Text(
              _errorMessage!,
              style: AppTypography.bodySmallStyle.copyWith(
                color: context.conduitTheme.error,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: const Duration(milliseconds: 200));
  }

  Widget _buildNetworkImage() {
    // Get authentication headers if available
    final defaultHeaders = buildImageHeadersFromWidgetRef(ref);
    final headers = _mergeHeaders(defaultHeaders, widget.httpHeaders);
    final dimensions = _cacheDimensions(context);

    final cacheManager = ref.watch(selfSignedImageCacheManagerProvider);
    final imageWidget = CachedNetworkImage(
      key: ValueKey('image_${widget.attachmentId}'),
      imageUrl: _cachedImageData!,
      fit: BoxFit.cover,
      cacheManager: cacheManager,
      httpHeaders: headers,
      memCacheWidth: dimensions.width,
      memCacheHeight: dimensions.height,
      maxWidthDiskCache: dimensions.width,
      maxHeightDiskCache: dimensions.height,
      fadeInDuration: widget.disableAnimation
          ? Duration.zero
          : const Duration(milliseconds: 200),
      fadeOutDuration: widget.disableAnimation
          ? Duration.zero
          : const Duration(milliseconds: 200),
      placeholder: (context, url) => Container(
        constraints: widget.constraints,
        decoration: BoxDecoration(
          color: context.conduitTheme.shimmerBase,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
        ),
      ),
      errorWidget: (context, url, error) {
        _errorMessage = error.toString();
        return _buildErrorState();
      },
    );

    return _wrapImage(imageWidget);
  }

  Widget _buildNetworkSvg() {
    // Get authentication headers if available
    final defaultHeaders = buildImageHeadersFromWidgetRef(ref);
    final headers = _mergeHeaders(defaultHeaders, widget.httpHeaders);

    final svgWidget = SvgPicture.network(
      _cachedImageData!,
      key: ValueKey('svg_${widget.attachmentId}'),
      fit: BoxFit.contain,
      headers: headers,
      placeholderBuilder: (context) => Container(
        constraints: widget.constraints,
        decoration: BoxDecoration(
          color: context.conduitTheme.shimmerBase,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
        ),
        child: Center(
          child: CircularProgressIndicator(
            color: context.conduitTheme.buttonPrimary,
            strokeWidth: 2,
          ),
        ),
      ),
      errorBuilder: (context, error, stackTrace) {
        _errorMessage = AppLocalizations.of(
          context,
        )!.failedToLoadImage(error.toString());
        return _buildErrorState();
      },
    );

    return _wrapImage(svgWidget);
  }

  Widget _buildBase64Image() {
    final bytes = _cachedBytes;
    if (bytes == null) {
      return _buildLoadingState();
    }
    final dimensions = _cacheDimensions(context);

    final imageWidget = Image.memory(
      key: ValueKey('image_${widget.attachmentId}'),
      bytes,
      fit: BoxFit.cover,
      cacheWidth: dimensions.width,
      cacheHeight: dimensions.height,
      gaplessPlayback: true, // Prevents flashing during rebuilds
      errorBuilder: (context, error, stackTrace) {
        _errorMessage = AppLocalizations.of(context)!.failedToDecodeImage;
        return _buildErrorState();
      },
    );

    return _wrapImage(imageWidget);
  }

  Widget _buildBase64Svg() {
    final bytes = _cachedBytes;
    if (bytes == null) {
      return _buildLoadingState();
    }

    final svgWidget = SvgPicture.memory(
      bytes,
      key: ValueKey('svg_${widget.attachmentId}'),
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        _errorMessage = AppLocalizations.of(context)!.failedToDecodeImage;
        return _buildErrorState();
      },
    );

    return _wrapImage(svgWidget);
  }

  Widget _wrapImage(Widget imageWidget) {
    final wrappedImage = Container(
      constraints:
          widget.constraints ??
          const BoxConstraints(maxWidth: 400, maxHeight: 400),
      margin: widget.isMarkdownFormat
          ? const EdgeInsets.symmetric(vertical: Spacing.sm)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        // Add subtle shadow for depth
        boxShadow: [
          BoxShadow(
            color: context.conduitTheme.cardShadow.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap ?? () => _showFullScreenImage(context),
          child: Hero(
            tag: _heroTag,
            flightShuttleBuilder:
                (
                  flightContext,
                  animation,
                  flightDirection,
                  fromHeroContext,
                  toHeroContext,
                ) {
                  final hero = flightDirection == HeroFlightDirection.push
                      ? fromHeroContext.widget as Hero
                      : toHeroContext.widget as Hero;
                  return FadeTransition(opacity: animation, child: hero.child);
                },
            child: imageWidget,
          ),
        ),
      ),
    );

    return wrappedImage;
  }

  void _showFullScreenImage(BuildContext context) {
    // Handle both data URL string and raw bytes cases
    if (_cachedImageData == null && _cachedBytes == null) return;

    PerformanceProfiler.instance.instant(
      'image_viewer_open',
      scope: 'image',
      data: {
        'imageKey': _profileImageKey,
        'hasBytes': _cachedBytes != null,
        'isSvg': _isSvg,
      },
    );

    Navigator.of(context).push(
      buildPlatformPageRoute(
        fullscreenDialog: true,
        builder: (context) => FullScreenImageViewer(
          imageData: _cachedImageData,
          imageBytes: _cachedBytes,
          tag: _heroTag,
          isSvg: _isSvg,
          customHeaders: widget.httpHeaders,
        ),
      ),
    );
  }
}

class FullScreenImageViewer extends ConsumerWidget {
  /// Image data as a URL (http://) or data URL (data:image/...) or base64 string.
  /// Either this or [imageBytes] must be provided.
  final String? imageData;

  /// Raw image bytes. Used when [imageData] is null.
  final Uint8List? imageBytes;

  final String tag;
  final bool isSvg;
  final Map<String, String>? customHeaders;

  const FullScreenImageViewer({
    super.key,
    this.imageData,
    this.imageBytes,
    required this.tag,
    this.isSvg = false,
    this.customHeaders,
  }) : assert(
         imageData != null || imageBytes != null,
         'Either imageData or imageBytes must be provided',
       );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget imageWidget;

    // If we have raw bytes, use them directly
    if (imageData == null && imageBytes != null) {
      if (isSvg || _isSvgBytes(imageBytes!)) {
        imageWidget = SvgPicture.memory(
          imageBytes!,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => Center(
            child: Icon(
              Icons.error_outline,
              color: context.conduitTheme.error,
              size: 48,
            ),
          ),
        );
      } else {
        imageWidget = Image.memory(imageBytes!, fit: BoxFit.contain);
      }
    } else if (imageData != null && imageData!.startsWith('http')) {
      // Get authentication headers if available
      final defaultHeaders = buildImageHeadersFromWidgetRef(ref);
      final headers = _mergeHeaders(defaultHeaders, customHeaders);

      if (isSvg || _isSvgUrl(imageData!)) {
        imageWidget = SvgPicture.network(
          imageData!,
          fit: BoxFit.contain,
          headers: headers,
          placeholderBuilder: (context) => Center(
            child: CircularProgressIndicator(
              color: context.conduitTheme.buttonPrimary,
            ),
          ),
          errorBuilder: (context, error, stackTrace) => Center(
            child: Icon(
              Icons.error_outline,
              color: context.conduitTheme.error,
              size: 48,
            ),
          ),
        );
      } else {
        final cacheManager = ref.watch(selfSignedImageCacheManagerProvider);
        imageWidget = CachedNetworkImage(
          imageUrl: imageData!,
          fit: BoxFit.contain,
          cacheManager: cacheManager,
          httpHeaders: headers,
          placeholder: (context, url) => Center(
            child: CircularProgressIndicator(
              color: context.conduitTheme.buttonPrimary,
            ),
          ),
          errorWidget: (context, url, error) => Center(
            child: Icon(
              Icons.error_outline,
              color: context.conduitTheme.error,
              size: 48,
            ),
          ),
        );
      }
    } else if (imageData != null) {
      try {
        String actualBase64;
        if (imageData!.startsWith('data:')) {
          final commaIndex = imageData!.indexOf(',');
          if (commaIndex == -1) {
            throw const FormatException('Invalid data URI');
          }
          actualBase64 = imageData!.substring(commaIndex + 1);
        } else {
          actualBase64 = imageData!;
        }
        final decodedBytes = base64.decode(actualBase64);

        // Check if SVG content
        if (isSvg || _isSvgDataUrl(imageData!) || _isSvgBytes(decodedBytes)) {
          imageWidget = SvgPicture.memory(
            decodedBytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => Center(
              child: Icon(
                Icons.error_outline,
                color: context.conduitTheme.error,
                size: 48,
              ),
            ),
          );
        } else {
          imageWidget = Image.memory(decodedBytes, fit: BoxFit.contain);
        }
      } catch (e) {
        imageWidget = Center(
          child: Icon(
            Icons.error_outline,
            color: context.conduitTheme.error,
            size: 48,
          ),
        );
      }
    } else {
      // No image data available - show error
      imageWidget = Center(
        child: Icon(
          Icons.error_outline,
          color: context.conduitTheme.error,
          size: 48,
        ),
      );
    }

    final tokens = context.colorTokens;
    final background = tokens.neutralTone10;
    final iconColor = tokens.neutralOnSurface;

    return AdaptiveRouteShell(
      backgroundColor: background,
      body: Stack(
        children: [
          Center(
            child: Hero(
              tag: tag,
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5.0,
                child: imageWidget,
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    Platform.isIOS ? Icons.ios_share : Icons.share_outlined,
                    color: iconColor,
                    size: 26,
                  ),
                  onPressed: () => _shareImage(context, ref),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.close, color: iconColor, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareImage(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      Uint8List bytes;
      String? fileExtension;

      // If we have raw bytes, use them directly
      if (imageData == null && imageBytes != null) {
        bytes = imageBytes!;
        fileExtension = isSvg ? 'svg' : 'png';
      } else if (imageData!.startsWith('http')) {
        final api = ref.read(apiServiceProvider);
        final authToken = ref.read(authTokenProvider3);
        final headers = <String, String>{};

        if (authToken != null && authToken.isNotEmpty) {
          headers['Authorization'] = 'Bearer $authToken';
        } else if (api?.serverConfig.apiKey != null &&
            api!.serverConfig.apiKey!.isNotEmpty) {
          headers['Authorization'] = 'Bearer ${api.serverConfig.apiKey}';
        }
        if (api != null && api.serverConfig.customHeaders.isNotEmpty) {
          headers.addAll(api.serverConfig.customHeaders);
        }
        final mergedHeaders = _mergeHeaders(headers, customHeaders);

        final client = api?.dio ?? dio.Dio();
        final response = await client.get<List<int>>(
          imageData!,
          options: dio.Options(
            responseType: dio.ResponseType.bytes,
            headers: mergedHeaders,
          ),
        );
        final data = response.data;
        if (data == null || data.isEmpty) {
          throw Exception(l10n.emptyImageData);
        }
        bytes = Uint8List.fromList(data);

        final contentType = response.headers.map['content-type']?.first;
        if (contentType != null && contentType.startsWith('image/')) {
          fileExtension = contentType.split('/').last;
          if (fileExtension == 'jpeg') fileExtension = 'jpg';
        } else {
          final uri = Uri.tryParse(imageData!);
          final lastSegment = uri?.pathSegments.isNotEmpty == true
              ? uri!.pathSegments.last
              : '';
          final dotIndex = lastSegment.lastIndexOf('.');
          if (dotIndex != -1 && dotIndex < lastSegment.length - 1) {
            final ext = lastSegment.substring(dotIndex + 1).toLowerCase();
            if (ext.length <= 5) {
              fileExtension = ext;
            }
          }
        }
      } else if (imageData != null) {
        String actualBase64 = imageData!;
        if (imageData!.startsWith('data:')) {
          final commaIndex = imageData!.indexOf(',');
          final meta = imageData!.substring(5, commaIndex); // image/png;base64
          final slashIdx = meta.indexOf('/');
          final semicolonIdx = meta.indexOf(';');
          if (slashIdx != -1 && semicolonIdx != -1 && slashIdx < semicolonIdx) {
            final subtype = meta.substring(slashIdx + 1, semicolonIdx);
            fileExtension = subtype == 'jpeg' ? 'jpg' : subtype;
          }
          actualBase64 = imageData!.substring(commaIndex + 1);
        }
        bytes = base64.decode(actualBase64);
      } else {
        // No image data available
        return;
      }

      fileExtension ??= 'png';
      final tempDir = await getTemporaryDirectory();
      final filePath =
          '${tempDir.path}/conduit_shared_${DateTime.now().millisecondsSinceEpoch}.$fileExtension';
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      // Swallowing UI feedback per requirements; keep a log for debugging
      DebugLogger.log(
        'Failed to share image: $e',
        scope: 'chat/image-attachment',
      );
    }
  }
}
