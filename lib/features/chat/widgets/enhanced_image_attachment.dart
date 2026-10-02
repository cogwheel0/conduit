import 'dart:async';
import 'dart:convert';

import 'package:markdown/markdown.dart' as md;
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/jovial_svg_image.dart';
import '../../../shared/widgets/image_viewer/image_viewer.dart';
import '../../../shared/widgets/skeleton_loader.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_core/network/conduit_user_agent.dart';

import '../../../core/network/self_signed_image_cache_manager.dart';
import '../../../core/network/image_header_utils.dart';

import 'package:conduit_core/services/api_service.dart';

import '../../../core/services/image_attachment_cache_service.dart';

import 'package:conduit_core/services/performance_profiler.dart';

import '../../../shared/services/raster_media_policy.dart';

import 'package:conduit_core/services/worker_manager.dart';

export '../../../core/services/image_attachment_cache_service.dart'
    show
        ImageAttachmentCacheScope,
        debugDecodedImageAttachmentByteBudget,
        debugDecodedImageAttachmentCount,
        debugDecodedImageAttachmentWeight,
        debugHasDecodedImageAttachment,
        debugHasImageAttachmentError,
        debugHasResolvedImageAttachment,
        debugResetImageAttachmentCaches,
        debugResolvedImageAttachmentCount,
        debugSeedImageAttachmentError,
        debugSeedResolvedImageAttachment,
        imageAttachmentCacheLifecycleProvider,
        preCacheImageBytes;

final _base64WhitespacePattern = RegExp(r'\s');

@visibleForTesting
Future<void> debugDecodeCachedResolvedImageAttachment({
  required String attachmentId,
  required WorkerManager workerManager,
  ImageAttachmentCacheScope? scope,
}) async {
  await _imageAttachmentLoader.decodeCachedResolvedDataForTesting(
    attachmentId: attachmentId,
    workerManager: workerManager,
    scope: scope,
  );
}

@visibleForTesting
Future<String?> debugDecodeCachedResolvedImageAttachmentError({
  required String attachmentId,
  required WorkerManager workerManager,
  required AppLocalizations l10n,
  ImageAttachmentCacheScope? scope,
}) async {
  final result = await _guardImageLoadFailure(
    attachmentId: attachmentId,
    cacheScope: scope,
    l10n: l10n,
    load: () async {
      await _imageAttachmentLoader.decodeCachedResolvedDataForTesting(
        attachmentId: attachmentId,
        workerManager: workerManager,
        scope: scope,
      );
      return imageAttachmentCacheStore.read(attachmentId, scope: scope) ??
          const ImageAttachmentCacheEntry(isSvg: false);
    },
  );
  return result.error;
}

@visibleForTesting
Future<String?> debugLoadImageAttachmentError({
  required String attachmentId,
  required WorkerManager workerManager,
  required AppLocalizations l10n,
  ApiService? api,
  ImageAttachmentCacheScope? scope,
}) async {
  final result = await _guardImageLoadFailure(
    attachmentId: attachmentId,
    cacheScope: scope,
    l10n: l10n,
    load: () => _imageAttachmentLoader.load(
      attachmentId: attachmentId,
      workerManager: workerManager,
      api: api,
      l10n: l10n,
      cacheScope: scope,
    ),
  );
  return result.error;
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
bool _isSvgDataUrl(String data) => imageAttachmentDataIsSvg(data);

/// Checks if a URL points to an SVG file.
bool _isSvgUrl(String url) => imageAttachmentUrlIsSvg(url);

/// Checks if decoded bytes represent SVG content by looking for the SVG tag.
bool _isSvgBytes(Uint8List bytes) => imageAttachmentBytesAreSvg(bytes);

bool _isRemoteContentValue(String data) => imageAttachmentContentIsRemote(data);

typedef _ImageLoadResult = ImageAttachmentCacheEntry;
const _imageAttachmentLoader = _ImageAttachmentLoader();

class _ImageAttachmentLoader {
  const _ImageAttachmentLoader();

  _ImageLoadResult? readCached(
    String attachmentId, {
    ImageAttachmentCacheScope? scope,
  }) => imageAttachmentCacheStore.read(attachmentId, scope: scope);

  void cacheBytes(
    String attachmentId,
    Uint8List bytes, {
    ImageAttachmentCacheScope? scope,
    bool? isSvg,
  }) => imageAttachmentCacheStore.cacheBytes(
    attachmentId,
    bytes,
    scope: scope,
    isSvg: isSvg,
  );

  void cacheError(
    String attachmentId,
    String error, {
    ImageAttachmentCacheScope? scope,
  }) => imageAttachmentCacheStore.cacheError(attachmentId, error, scope: scope);

  void _cacheResolvedData(
    String attachmentId,
    String resolvedData, {
    required bool isSvg,
    ImageAttachmentCacheScope? scope,
  }) => imageAttachmentCacheStore.cacheResolvedData(
    attachmentId,
    resolvedData,
    isSvg: isSvg,
    scope: scope,
  );

  Future<_ImageLoadResult> decodeCachedResolvedDataForTesting({
    required String attachmentId,
    required WorkerManager workerManager,
    ImageAttachmentCacheScope? scope,
  }) {
    final cached = readCached(attachmentId, scope: scope);
    if (cached == null || !cached.needsDecode || cached.resolvedData == null) {
      throw StateError(
        'No decodable cached resolved data exists for $attachmentId',
      );
    }
    return _decodeResolvedDataWithWorker(
      attachmentId: attachmentId,
      cacheScope: scope,
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
    ImageAttachmentCacheScope? cacheScope,
  }) {
    return imageAttachmentCacheStore.load(
      attachmentId,
      scope: cacheScope,
      loader: (cached) => _loadInternal(
        attachmentId: attachmentId,
        cacheScope: cacheScope,
        workerManager: workerManager,
        api: api,
        l10n: l10n,
        cached: cached,
      ),
    );
  }

  Future<_ImageLoadResult> _loadInternal({
    required String attachmentId,
    required ImageAttachmentCacheScope? cacheScope,
    required WorkerManager workerManager,
    required ApiService? api,
    required AppLocalizations l10n,
    _ImageLoadResult? cached,
  }) async {
    if (cached?.bytes != null) {
      return cached!;
    }

    if (cached?.needsDecode == true && cached?.resolvedData != null) {
      return await _decodeResolvedData(
        attachmentId: attachmentId,
        cacheScope: cacheScope,
        workerManager: workerManager,
        source: cached!.resolvedData!,
        svgHint: cached.isSvg,
      );
    }

    if (attachmentId.startsWith('data:') || attachmentId.startsWith('http')) {
      final isSvgContent =
          _isSvgDataUrl(attachmentId) || _isSvgUrl(attachmentId);
      _cacheResolvedData(
        attachmentId,
        attachmentId,
        isSvg: isSvgContent,
        scope: cacheScope,
      );
      if (_isRemoteContentValue(attachmentId)) {
        return _ImageLoadResult(
          resolvedData: attachmentId,
          isSvg: isSvgContent,
        );
      }
      return await _decodeResolvedData(
        attachmentId: attachmentId,
        cacheScope: cacheScope,
        workerManager: workerManager,
        source: attachmentId,
        svgHint: isSvgContent,
      );
    }

    if (attachmentId.startsWith('/')) {
      if (api == null) {
        final error = l10n.unableToLoadImage;
        // API availability is lifecycle state, not an immutable property of
        // this attachment. Do not turn bootstrap/teardown into a process-long
        // negative cache entry.
        return _ImageLoadResult(error: error, isSvg: false);
      }
      final fullUrl = api.baseUrl + attachmentId;
      final isSvgContent = _isSvgUrl(fullUrl);
      _cacheResolvedData(
        attachmentId,
        fullUrl,
        isSvg: isSvgContent,
        scope: cacheScope,
      );
      return _ImageLoadResult(resolvedData: fullUrl, isSvg: isSvgContent);
    }

    if (api == null) {
      final error = l10n.apiUnavailable;
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
        cacheError(attachmentId, error, scope: cacheScope);
        return _ImageLoadResult(error: error, isSvg: false);
      }

      final isSvgFile = ext == 'svg' || contentType.contains('svg');
      final fileContent = await api.getFileContent(attachmentId);
      _cacheResolvedData(
        attachmentId,
        fileContent,
        isSvg: isSvgFile,
        scope: cacheScope,
      );

      if (_isRemoteContentValue(fileContent)) {
        return _ImageLoadResult(resolvedData: fileContent, isSvg: isSvgFile);
      }

      return await _decodeResolvedData(
        attachmentId: attachmentId,
        cacheScope: cacheScope,
        workerManager: workerManager,
        source: fileContent,
        svgHint: isSvgFile,
      );
    } catch (error) {
      final message = l10n.failedToLoadImage(error.toString());
      // File metadata/content requests can fail transiently. Return the error
      // to this mounted caller but leave the shared cache retryable on remount.
      return _ImageLoadResult(error: message, isSvg: false);
    }
  }

  Future<_ImageLoadResult> _decodeResolvedData({
    required String attachmentId,
    required ImageAttachmentCacheScope? cacheScope,
    required WorkerManager workerManager,
    required String source,
    required bool svgHint,
  }) async {
    return _decodeResolvedDataWithWorker(
      attachmentId: attachmentId,
      cacheScope: cacheScope,
      worker: workerManager,
      source: source,
      svgHint: svgHint,
    );
  }
}

Future<_ImageLoadResult> _decodeResolvedDataWithWorker({
  required String attachmentId,
  required ImageAttachmentCacheScope? cacheScope,
  required WorkerManager worker,
  required String source,
  required bool svgHint,
}) async {
  final bytes = await worker.schedule<String, Uint8List>(
    _decodeImageData,
    source,
    debugLabel: 'decode_image',
  );
  final isSvg = _isSvgBytes(bytes) || _isSvgDataUrl(source) || svgHint;
  imageAttachmentCacheStore.cacheBytes(
    attachmentId,
    bytes,
    scope: cacheScope,
    isSvg: isSvg,
  );
  return _ImageLoadResult(resolvedData: source, bytes: bytes, isSvg: isSvg);
}

Future<_ImageLoadResult> _guardImageLoadFailure({
  required String attachmentId,
  ImageAttachmentCacheScope? cacheScope,
  required AppLocalizations l10n,
  required Future<_ImageLoadResult> Function() load,
}) async {
  try {
    return await load();
  } catch (_) {
    final decodeError = l10n.failedToDecodeImage;
    imageAttachmentCacheStore.cacheError(
      attachmentId,
      decodeError,
      scope: cacheScope,
    );
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
  final merged = <String, String>{...?defaults, ...?overrides};
  if (defaults?.keys.any(ConduitUserAgent.isHeaderName) == true) {
    ConduitUserAgent.applyTo(merged);
  }
  return merged;
}

@visibleForTesting
Map<String, String>? debugMergeImageHeaders(
  Map<String, String>? defaults,
  Map<String, String>? overrides,
) => _mergeHeaders(defaults, overrides);

const _defaultImagePreviewConstraints = BoxConstraints(
  minWidth: 200,
  maxWidth: 300,
  minHeight: 150,
  maxHeight: 300,
);

@visibleForTesting
Size debugStableImagePreviewSizeForTesting(BoxConstraints? constraints) {
  final effective = constraints ?? _defaultImagePreviewConstraints;
  return Size(
    effective.hasBoundedWidth
        ? effective.maxWidth
        : _defaultImagePreviewConstraints.maxWidth,
    effective.hasBoundedHeight
        ? effective.maxHeight
        : _defaultImagePreviewConstraints.maxHeight,
  );
}

@visibleForTesting
RasterDecodeTarget debugImagePreviewDecodeTargetForTesting({
  required BoxConstraints? constraints,
  required double devicePixelRatio,
}) {
  final previewSize = debugStableImagePreviewSizeForTesting(constraints);
  return RasterMediaPolicy.target(
    profile: RasterDecodeProfile.inline,
    devicePixelRatio: devicePixelRatio,
    logicalWidth: previewSize.width,
    logicalHeight: previewSize.height,
  );
}

/// Explicit message-local sources. Collected on tap so streaming Markdown is
/// parsed once, and a viewer keeps a stable snapshot while the message changes.
class ImageAttachmentReference {
  const ImageAttachmentReference(
    this.id, {
    this.headers,
    this.label,
    this.isKnownImage = true,
  });
  final String id;
  final Map<String, String>? headers;
  final String? label;
  final bool isKnownImage;
}

class ImageAttachmentGallery extends InheritedWidget {
  const ImageAttachmentGallery({
    super.key,
    required this.images,
    required super.child,
  });
  final List<ImageAttachmentReference> Function() images;

  static List<ImageAttachmentReference> markdownImages(String content) {
    final document = md.Document(
      extensionSet: conduitGitHubWebExtensionSet,
      inlineSyntaxes: [LongAlphanumericRunSyntax()],
    );
    final images = <ImageAttachmentReference>[];
    void visit(md.Node node) {
      if (node is! md.Element) return;
      if (node.tag == 'img') {
        final source = node.attributes['src'];
        if (source != null) {
          images.add(
            ImageAttachmentReference(source, label: node.attributes['alt']),
          );
        }
      }
      for (final child in node.children ?? const <md.Node>[]) {
        visit(child);
      }
    }

    for (final node in document.parseLines(content.split('\n'))) {
      visit(node);
    }
    return images;
  }

  @override
  bool updateShouldNotify(ImageAttachmentGallery oldWidget) => false;
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
  ImageAttachmentCacheScope? _cacheScope;

  String get _profileImageKey =>
      widget.attachmentId.hashCode.toUnsigned(32).toRadixString(16);

  // The process-wide byte-bounded cache preserves inexpensive remounts. Do not
  // pin every image row and its decoded widget state in a virtualized chat list.
  @override
  bool get wantKeepAlive => false;

  @override
  void initState() {
    super.initState();
    _cacheScope = usesAccountScopedImageCache(widget.attachmentId)
        ? ImageAttachmentCacheScope(
            api: ref.read(apiServiceProvider),
            authSessionEpoch: ref.read(openWebUiAuthSessionEpochProvider),
          )
        : null;
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

    final requestScope = _cacheScope;
    final cached = _imageAttachmentLoader.readCached(
      widget.attachmentId,
      scope: requestScope,
    );
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
        cacheScope: requestScope,
        l10n: l10n,
        load: () => _imageAttachmentLoader.load(
          attachmentId: widget.attachmentId,
          workerManager: ref.read(workerManagerProvider),
          api: requestScope?.api,
          l10n: l10n,
          cacheScope: requestScope,
        ),
      );
      if (!mounted ||
          requestGeneration != _loadGeneration ||
          requestScope != _cacheScope) {
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

  RasterDecodeTarget _cacheDimensions(BuildContext context) {
    return debugImagePreviewDecodeTargetForTesting(
      constraints: _previewConstraints,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
  }

  BoxConstraints get _previewConstraints =>
      widget.constraints ?? _defaultImagePreviewConstraints;

  Size get _stablePreviewSize =>
      debugStableImagePreviewSizeForTesting(widget.constraints);

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    // Literal data/HTTP sources do not consult the Open WebUI API, and their
    // process-local cache key is already the literal itself. Avoid pulling the
    // authenticated app graph into public/generated image rows; server file IDs
    // still watch both ownership identities and reset immediately on a switch.
    final currentScope = usesAccountScopedImageCache(widget.attachmentId)
        ? ImageAttachmentCacheScope(
            api: ref.watch(apiServiceProvider),
            authSessionEpoch: ref.watch(openWebUiAuthSessionEpochProvider),
          )
        : null;
    if (currentScope != _cacheScope) {
      _cacheScope = currentScope;
      _cachedImageData = null;
      _cachedBytes = null;
      _hasAttemptedLoad = false;
      _isLoading = true;
      _errorMessage = null;
      _isSvg = false;
      _loadGeneration += 1;
      _retryLoadTimer?.cancel();
      _loadScheduled = false;
      _retryLoadScheduled = false;
    }

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
    // Include fallback detection for SVG URLs and inline data.
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

  Widget _buildSkeletonPlaceholder({
    BoxConstraints? constraints,
    bool showProgressIndicator = false,
    bool includeMarkdownMargin = false,
  }) {
    final theme = context.conduitTheme;
    final borderRadius = BorderRadius.circular(AppBorderRadius.md);

    return Container(
      constraints: constraints,
      margin: includeMarkdownMargin && widget.isMarkdownFormat
          ? const EdgeInsets.symmetric(vertical: Spacing.sm)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: theme.surfaceBackground.withValues(alpha: 0.28),
        borderRadius: borderRadius,
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.2),
          width: BorderWidth.thin,
        ),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            SkeletonLoader(
              borderRadius: borderRadius,
              baseColor: theme.shimmerBase.withValues(
                alpha: widget.isUserMessage ? 0.92 : 0.8,
              ),
              highlightColor: theme.shimmerHighlight.withValues(
                alpha: widget.isUserMessage ? 1.0 : 0.9,
              ),
            ),
            if (showProgressIndicator)
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.surfaceContainer.withValues(alpha: 0.75),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.sm),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: theme.buttonPrimary,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return KeyedSubtree(
      key: const ValueKey('loading'),
      child: SizedBox.fromSize(
        size: _stablePreviewSize,
        child: _buildSkeletonPlaceholder(
          constraints: _previewConstraints,
          showProgressIndicator: true,
          includeMarkdownMargin: true,
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    final error = SizedBox.fromSize(
      key: const ValueKey('error'),
      size: _stablePreviewSize,
      child: Container(
        constraints: _previewConstraints,
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
      ),
    );
    if (widget.disableAnimation || context.reduceMotion) {
      return error;
    }
    return error.animate().fadeIn(duration: const Duration(milliseconds: 200));
  }

  Widget _buildNetworkImage() {
    // Only attach credentials for images served by the configured server.
    final defaultHeaders = buildImageHeadersForUrlFromWidgetRef(
      ref,
      _cachedImageData!,
    );
    final headers = _mergeHeaders(defaultHeaders, widget.httpHeaders);
    final networkCacheKey = buildImageCacheKeyForUrlFromWidgetRef(
      ref,
      _cachedImageData!,
      effectiveHeaders: headers,
    );
    final dimensions = _cacheDimensions(context);
    final previewSize = _stablePreviewSize;

    final cacheManager = ref.watch(selfSignedImageCacheManagerProvider);
    final imageWidget = Image(
      key: ValueKey('image_${widget.attachmentId}'),
      image: RasterMediaPolicy.resizeProviderForCover(
        CachedNetworkImageProvider(
          _cachedImageData!,
          cacheKey: networkCacheKey,
          cacheManager: cacheManager,
          headers: headers,
        ),
        dimensions,
        profile: RasterDecodeProfile.inline,
      ),
      width: previewSize.width,
      height: previewSize.height,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        return wasSynchronouslyLoaded || frame != null
            ? child
            : SizedBox.fromSize(
                size: previewSize,
                child: _buildSkeletonPlaceholder(),
              );
      },
      errorBuilder: (context, error, stackTrace) {
        _errorMessage = error.toString();
        return _buildErrorState();
      },
    );

    return _wrapImage(imageWidget);
  }

  Widget _buildNetworkSvg() {
    final defaultHeaders = buildImageHeadersForUrlFromWidgetRef(
      ref,
      _cachedImageData!,
    );
    final headers = _mergeHeaders(defaultHeaders, widget.httpHeaders);
    final networkCacheKey = buildImageCacheKeyForUrlFromWidgetRef(
      ref,
      _cachedImageData!,
      effectiveHeaders: headers,
    );

    final svgWidget = JovialSvgImage.network(
      _cachedImageData!,
      key: ValueKey('svg_${widget.attachmentId}'),
      fit: BoxFit.contain,
      headers: headers,
      cacheIdentity: networkCacheKey,
      placeholderBuilder: (context) => _buildSkeletonPlaceholder(),
      errorBuilder: (context, error, stackTrace) {
        _errorMessage = AppLocalizations.of(context)!
            .failedToLoadImage(error.toString());
        return _buildErrorState();
      },
    );

    return _wrapImage(
      SizedBox.fromSize(size: _stablePreviewSize, child: svgWidget),
    );
  }

  Widget _buildBase64Image() {
    final bytes = _cachedBytes;
    if (bytes == null) {
      return _buildLoadingState();
    }
    final dimensions = _cacheDimensions(context);
    final previewSize = _stablePreviewSize;

    final imageWidget = Image(
      key: ValueKey('image_${widget.attachmentId}'),
      image: RasterMediaPolicy.resizeProviderForCover(
        MemoryImage(bytes),
        dimensions,
        profile: RasterDecodeProfile.inline,
      ),
      width: previewSize.width,
      height: previewSize.height,
      fit: BoxFit.cover,
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

    final svgWidget = JovialSvgImage.bytes(
      bytes,
      key: ValueKey('svg_${widget.attachmentId}'),
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        _errorMessage = AppLocalizations.of(context)!.failedToDecodeImage;
        return _buildErrorState();
      },
    );

    return _wrapImage(
      SizedBox.fromSize(size: _stablePreviewSize, child: svgWidget),
    );
  }

  Widget _wrapImage(Widget imageWidget) {
    final wrappedImage = Container(
      constraints: _previewConstraints,
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
          child: HeroMode(
            enabled: !context.reduceMotion,
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
                    return FadeTransition(
                      opacity: animation,
                      child: hero.child,
                    );
                  },
              child: imageWidget,
            ),
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

    final gallery = context
        .getInheritedWidgetOfExactType<ImageAttachmentGallery>();
    final api = ref.read(apiServiceProvider);
    final epoch = ref.read(openWebUiAuthSessionEpochProvider);
    final scope = ImageAttachmentCacheScope(api: api, authSessionEpoch: epoch);
    if (usesAccountScopedImageCache(widget.attachmentId) && _cacheScope != scope) {
      return;
    }
    final sources = <ImageAttachmentReference>[];
    final seen = <String>{};
    for (final source in gallery?.images() ?? <ImageAttachmentReference>[]) {
      // Generic legacy attachment lists can contain documents. Include only
      // siblings that have already resolved as images, plus literal image data.
      final cached = imageAttachmentCacheStore.read(source.id, scope: scope);
      if (!source.isKnownImage &&
          source.id != widget.attachmentId &&
          !source.id.startsWith('data:image/') &&
          (cached == null || cached.error != null)) {
        continue;
      }
      if (seen.add(source.id)) sources.add(source);
    }
    if (seen.add(widget.attachmentId)) {
      sources.add(
        ImageAttachmentReference(
          widget.attachmentId,
          headers: widget.httpHeaders,
        ),
      );
    }
    final initialIndex = sources.indexWhere(
      (source) => source.id == widget.attachmentId,
    );
    final worker = ref.read(workerManagerProvider);
    final l10n = AppLocalizations.of(context)!;
    final cacheManager =
        ref.read(selfSignedImageCacheManagerProvider) ??
        CachedNetworkImageProvider.defaultCacheManager;
    final container = ProviderScope.containerOf(context, listen: false);
    bool isCurrent() =>
        identical(container.read(apiServiceProvider), api) &&
        identical(container.read(openWebUiAuthSessionEpochProvider), epoch);
    final items = sources
        .map((source) {
          final scope = usesAccountScopedImageCache(source.id)
              ? ImageAttachmentCacheScope(api: api, authSessionEpoch: epoch)
              : null;
          String? downloadedKey;
          var thumbnail =
              source.id == widget.attachmentId && _cachedBytes != null
              ? ImageViewerMedia.bytes(_cachedBytes!, isSvg: _isSvg)
              : null;
          return ImageViewerItem(
            label: source.label,
            invalidate: () async {
              if (!isCurrent()) return;
              thumbnail = null;
              await imageAttachmentCacheStore.invalidate(
                source.id,
                scope: scope,
              );
              if (downloadedKey != null) {
                await cacheManager.removeFile(downloadedKey!);
              }
            },
            heroTag: source.id == widget.attachmentId ? _heroTag : null,
            load: () async {
              if (!isCurrent()) throw StateError('Image owner changed');
              if (thumbnail case final media?) return media;
              final result = await _imageAttachmentLoader.load(
                attachmentId: source.id,
                workerManager: worker,
                api: api,
                l10n: l10n,
                cacheScope: scope,
              );
              if (!isCurrent()) throw StateError('Image owner changed');
              if (result.error != null) throw StateError('Image unavailable');
              if (result.bytes case final bytes?) {
                return ImageViewerMedia.bytes(bytes, isSvg: result.isSvg);
              }
              final url = result.resolvedData;
              if (url == null || !url.startsWith('http')) {
                throw StateError('Image unavailable');
              }
              final headers = _mergeHeaders(
                buildImageHeadersForUrlFromContainer(container, url),
                source.headers,
              );
              final cacheKey = buildImageCacheKeyForUrlFromContainer(
                container,
                url,
                effectiveHeaders: headers,
              );
              downloadedKey = cacheKey ?? url;
              final file = await cacheManager
                  .getFileStream(url, key: cacheKey, headers: headers)
                  .where((response) => response is FileInfo)
                  .cast<FileInfo>()
                  .first;
              if (!isCurrent()) throw StateError('Image owner changed');
              return ImageViewerMedia.file(file.file, isSvg: result.isSvg);
            },
          );
        })
        .toList(growable: false);
    final active = ValueNotifier<bool>(true);
    final apiSubscription = container.listen(apiServiceProvider, (_, _) {
      active.value = isCurrent();
    });
    final epochSubscription = container.listen(
      openWebUiAuthSessionEpochProvider,
      (_, _) {
        active.value = isCurrent();
      },
    );
    Navigator.of(context)
        .push(
          buildImageViewerRoute(
            context,
            items: items,
            initialIndex: initialIndex,
            active: active,
          ),
        )
        .whenComplete(() {
          apiSubscription.close();
          epochSubscription.close();
          active.dispose();
        });
  }
}
