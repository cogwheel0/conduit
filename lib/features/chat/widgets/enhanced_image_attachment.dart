import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:dio/dio.dart' as dio;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/providers/app_providers.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/network/self_signed_image_cache_manager.dart';
import '../../../core/network/image_header_utils.dart';
import '../../../core/services/worker_manager.dart';

// Simple global cache to prevent reloading
final _globalImageCache = <String, String>{};
final _globalLoadingStates = <String, bool>{};
final _globalErrorStates = <String, String>{};
final _globalImageBytesCache = <String, Uint8List>{};
final _globalSvgStates = <String, bool>{};
final _base64WhitespacePattern = RegExp(r'\s');

/// Pre-cache image bytes for instant display after upload.
/// Call this with the server file ID and image bytes after successful upload.
void preCacheImageBytes(String fileId, Uint8List bytes) {
  if (fileId.isEmpty || bytes.isEmpty) return;
  // Clear any previous error state for this file
  _globalErrorStates.remove(fileId);
  _globalImageBytesCache[fileId] = bytes;
  _globalLoadingStates[fileId] = false;
  // Detect SVG
  _globalSvgStates[fileId] = _isSvgBytes(bytes);
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
  bool _isDecoding = false;
  bool _isSvg = false;
  late String _heroTag;
  bool _hasAttemptedLoad = false;

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
      _loadImage();
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
        _isDecoding = false;
        _isSvg = false;
      });
      // Load the new image
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadImage();
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadImage() async {
    // Prevent duplicate loads
    if (_hasAttemptedLoad) return;
    _hasAttemptedLoad = true;

    final l10n = AppLocalizations.of(context)!;

    // Check bytes cache first (populated during upload for instant display)
    final preCachedBytes = _globalImageBytesCache[widget.attachmentId];
    if (preCachedBytes != null) {
      final cachedIsSvg = _globalSvgStates[widget.attachmentId] ?? false;
      if (mounted) {
        setState(() {
          _cachedBytes = preCachedBytes;
          _isSvg = cachedIsSvg;
          _isLoading = false;
        });
      }
      return;
    }

    // Check for cached errors - if image previously failed, show error immediately
    // Note: preCacheImageBytes() clears errors when upload completes successfully
    final cachedError = _globalErrorStates[widget.attachmentId];
    if (cachedError != null) {
      if (mounted) {
        setState(() {
          _errorMessage = cachedError;
          _isLoading = false;
        });
      }
      return;
    }

    if (_globalImageCache.containsKey(widget.attachmentId)) {
      final cachedData = _globalImageCache[widget.attachmentId]!;
      final cachedBytes = _globalImageBytesCache[widget.attachmentId];
      final cachedIsSvg = _globalSvgStates[widget.attachmentId] ?? false;
      if (mounted) {
        setState(() {
          _cachedImageData = cachedData;
          _cachedBytes = cachedBytes;
          _isSvg = cachedIsSvg;
          _isLoading = cachedBytes == null && !_isRemoteContent(cachedData);
        });
      }
      if (cachedBytes == null && !_isRemoteContent(cachedData)) {
        await _decodeAndAssign(cachedData, l10n);
      } else if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    _globalLoadingStates[widget.attachmentId] = true;

    final attachmentId = widget.attachmentId;

    if (attachmentId.startsWith('data:') || attachmentId.startsWith('http')) {
      // Detect SVG from data URL or HTTP URL
      final isSvgContent =
          _isSvgDataUrl(attachmentId) || _isSvgUrl(attachmentId);
      _globalImageCache[attachmentId] = attachmentId;
      _globalLoadingStates[attachmentId] = false;
      _globalSvgStates[attachmentId] = isSvgContent;
      final cachedBytes = _globalImageBytesCache[attachmentId];
      if (mounted) {
        setState(() {
          _cachedImageData = attachmentId;
          _cachedBytes = cachedBytes;
          _isSvg = isSvgContent;
          _isLoading = cachedBytes == null && !_isRemoteContent(attachmentId);
        });
      }
      if (!_isRemoteContent(attachmentId) && cachedBytes == null) {
        await _decodeAndAssign(attachmentId, l10n);
      }
      return;
    }

    if (attachmentId.startsWith('/')) {
      final api = ref.read(apiServiceProvider);
      if (api != null) {
        final fullUrl = api.baseUrl + attachmentId;
        final isSvgContent = _isSvgUrl(fullUrl);
        _globalImageCache[attachmentId] = fullUrl;
        _globalLoadingStates[attachmentId] = false;
        _globalSvgStates[attachmentId] = isSvgContent;
        if (mounted) {
          setState(() {
            _cachedImageData = fullUrl;
            _cachedBytes = null;
            _isSvg = isSvgContent;
            _isLoading = false;
          });
        }
        return;
      } else {
        final error = l10n.unableToLoadImage;
        _cacheError(error);
        return;
      }
    }

    final api = ref.read(apiServiceProvider);
    if (api == null) {
      final error = l10n.apiUnavailable;
      _cacheError(error);
      return;
    }

    try {
      final fileInfo = await api.getFileInfo(attachmentId);
      final fileName = _extractFileName(fileInfo);
      final ext = fileName.toLowerCase().split('.').last;
      final contentType = (fileInfo['meta']?['content_type'] ??
              fileInfo['content_type'] ??
              '')
          .toString()
          .toLowerCase();

      // Check both extension and content_type for image detection
      final isImageByExt =
          ['jpg', 'jpeg', 'png', 'gif', 'webp', 'svg', 'bmp'].contains(ext);
      final isImageByContentType = contentType.startsWith('image/');

      if (!isImageByExt && !isImageByContentType) {
        final error = l10n.notAnImageFile(fileName);
        _cacheError(error);
        return;
      }

      // Track if this is an SVG file based on extension or content type
      final isSvgFile = ext == 'svg' || contentType.contains('svg');

      final fileContent = await api.getFileContent(attachmentId);

      _globalImageCache[attachmentId] = fileContent;
      _globalLoadingStates[attachmentId] = false;
      _globalSvgStates[attachmentId] = isSvgFile;

      if (_globalImageCache.length > 50) {
        final firstKey = _globalImageCache.keys.first;
        _globalImageCache.remove(firstKey);
        _globalLoadingStates.remove(firstKey);
        _globalErrorStates.remove(firstKey);
        _globalImageBytesCache.remove(firstKey);
        _globalSvgStates.remove(firstKey);
      }

      if (mounted) {
        setState(() {
          _cachedImageData = fileContent;
          _cachedBytes = null;
          _isSvg = isSvgFile;
          _isLoading = !_isRemoteContent(fileContent);
        });
      }

      if (_isRemoteContent(fileContent)) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      await _decodeAndAssign(fileContent, l10n);
    } catch (e) {
      final error = l10n.failedToLoadImage(e.toString());
      _cacheError(error);
    }
  }

  bool _isRemoteContent(String data) => data.startsWith('http');

  Future<void> _decodeAndAssign(String data, AppLocalizations l10n) async {
    if (_isDecoding) return;
    _isDecoding = true;
    try {
      final worker = ref.read(workerManagerProvider);
      final bytes = await worker.schedule(
        _decodeImageData,
        data,
        debugLabel: 'decode_image',
      );
      _globalImageBytesCache[widget.attachmentId] = bytes;

      // Use byte content as authoritative SVG detection when positive, but
      // preserve prior true-hints (e.g., from file extension) if detection fails.
      final previousHint = _globalSvgStates[widget.attachmentId] ?? _isSvg;
      final detectedSvg = _isSvgBytes(bytes) || _isSvgDataUrl(data);
      final isSvgContent = detectedSvg ? true : previousHint;
      _globalSvgStates[widget.attachmentId] = isSvgContent;

      if (!mounted) return;
      setState(() {
        _cachedBytes = bytes;
        _isSvg = isSvgContent;
        _isLoading = false;
      });
    } on FormatException {
      final error = l10n.invalidImageFormat;
      _cacheError(error);
    } catch (_) {
      final error = l10n.failedToDecodeImage;
      _cacheError(error);
    } finally {
      _isDecoding = false;
    }
  }

  void _cacheError(String error) {
    _globalErrorStates[widget.attachmentId] = error;
    _globalLoadingStates[widget.attachmentId] = false;
    _globalImageCache.remove(widget.attachmentId);
    _globalImageBytesCache.remove(widget.attachmentId);
    _globalSvgStates.remove(widget.attachmentId);
    if (!mounted) {
      return;
    }
    setState(() {
      _errorMessage = error;
      _cachedBytes = null;
      _isLoading = false;
    });
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

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

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
              style: TextStyle(
                color: context.conduitTheme.error,
                fontSize: AppTypography.bodySmall,
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

    final cacheManager = ref.watch(selfSignedImageCacheManagerProvider);
    final imageWidget = CachedNetworkImage(
      key: ValueKey('image_${widget.attachmentId}'),
      imageUrl: _cachedImageData!,
      fit: BoxFit.cover,
      cacheManager: cacheManager,
      httpHeaders: headers,
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

    final imageWidget = Image.memory(
      key: ValueKey('image_${widget.attachmentId}'),
      bytes,
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
        child: Material(
          color: Colors.transparent,
          child: InkWell(
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

    Navigator.of(context).push(
      MaterialPageRoute(
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
  }) : assert(imageData != null || imageBytes != null,
            'Either imageData or imageBytes must be provided');

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

    return Scaffold(
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
