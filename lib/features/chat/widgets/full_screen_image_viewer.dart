part of 'enhanced_image_attachment.dart';

ImageAttachmentCacheScope? _viewerCacheScope(
  ProviderContainer container,
  String attachmentId,
) => usesAccountScopedImageCache(attachmentId)
    ? ImageAttachmentCacheScope(
        api: container.read(apiServiceProvider),
        authSessionEpoch: container.read(openWebUiAuthSessionEpochProvider),
      )
    : null;

/// Resolves a gallery item through the same cache the thumbnails use, so
/// visible siblings open without another request.
Future<ImageAttachmentCacheEntry> _resolveViewerEntry(
  ProviderContainer container,
  String attachmentId,
  AppLocalizations l10n,
) async {
  final scope = _viewerCacheScope(container, attachmentId);
  final cached = _imageAttachmentLoader.readCached(attachmentId, scope: scope);
  if (cached != null && !cached.needsDecode) return cached;
  return _guardImageLoadFailure(
    attachmentId: attachmentId,
    cacheScope: scope,
    l10n: l10n,
    load: () => _imageAttachmentLoader.load(
      attachmentId: attachmentId,
      workerManager: container.read(workerManagerProvider),
      api: scope?.api,
      l10n: l10n,
      cacheScope: scope,
    ),
  );
}

typedef _ViewerImageBytes = ({Uint8List bytes, ImageFileType type});

/// Returns the original bytes for [entry] so they can be handed to the
/// platform viewer, the share sheet, or the gallery.
///
/// Remote images come from the network-image disk cache when the thumbnail
/// already stored them, and otherwise download with the same headers the
/// thumbnail used.
Future<_ViewerImageBytes> _loadViewerImageBytes(
  ProviderContainer container,
  ImageAttachmentCacheEntry entry,
  Map<String, String>? customHeaders,
) async {
  final data = entry.resolvedData;
  final bytes = entry.bytes;
  if (bytes != null) {
    return (bytes: bytes, type: detectImageFileType(bytes, contentType: data));
  }
  if (data == null) throw StateError('Image has no data');
  if (!_isRemoteContentValue(data)) {
    final decoded = _decodeImageData(data);
    return (
      bytes: decoded,
      type: detectImageFileType(decoded, contentType: data),
    );
  }

  final headers = _mergeHeaders(
    buildImageHeadersForUrlFromContainer(container, data),
    customHeaders,
  );
  final cacheKey =
      buildImageCacheKeyForUrlFromContainer(
        container,
        data,
        effectiveHeaders: headers,
      ) ??
      data;
  final cacheManager =
      container.read(selfSignedImageCacheManagerProvider) ??
      CachedNetworkImageProvider.defaultCacheManager;
  final cachedFile = await cacheManager.getFileFromCache(cacheKey);
  if (cachedFile != null) {
    final cachedBytes = await cachedFile.file.readAsBytes();
    return (
      bytes: cachedBytes,
      type: detectImageFileType(cachedBytes, sourceUrl: data),
    );
  }

  final client =
      container.read(apiServiceProvider)?.dio ??
      dio.Dio(
        dio.BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
  final response = await client.get<List<int>>(
    data,
    options: dio.Options(
      responseType: dio.ResponseType.bytes,
      headers: headers,
    ),
  );
  final body = response.data;
  if (body == null || body.isEmpty) throw StateError('Empty image response');
  final downloaded = Uint8List.fromList(body);
  return (
    bytes: downloaded,
    type: detectImageFileType(
      downloaded,
      contentType: response.headers.value('content-type'),
      sourceUrl: data,
    ),
  );
}

/// Width-to-height ratio of the first decoded image under [context].
///
/// The viewer sizes its hero to this ratio so the thumbnail flies to the
/// fitted image instead of the whole screen.
double? _decodedAspectRatioOf(BuildContext context) {
  double? ratio;
  void visit(RenderObject object) {
    if (ratio != null) return;
    if (object case RenderImage(image: final image?) when image.height > 0) {
      ratio = image.width / image.height;
      return;
    }
    object.visitChildren(visit);
  }

  if (context.findRenderObject() case final object?) visit(object);
  return ratio;
}

Rect? _globalRectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Opens [items] full screen, starting at [initialIndex].
///
/// iOS uses Quick Look for raster images when every page is ready within
/// [_nativeViewerPrepareTimeout]. SVGs, failures, slow pages, and other
/// platforms use [FullScreenImageViewer], which loads pages on demand. [context] should belong to the
/// tapped thumbnail so the transitions start from it.
Future<void> _openImageViewer({
  required BuildContext context,
  required List<ImageViewerItem> items,
  required int initialIndex,
  required ImageAttachmentCacheEntry initialEntry,
  required String heroTag,
  required ValueChanged<bool> onPreparing,
}) async {
  final bridge = NativeImageViewerBridge.instance;
  if (bridge.supportsNativeViewer && !initialEntry.isSvg) {
    final container = ProviderScope.containerOf(context, listen: false);
    final l10n = AppLocalizations.of(context)!;
    final sourceRect = _globalRectOf(context);
    onPreparing(true);
    _NativeViewerFiles? files;
    try {
      files = await _prepareNativeViewerFiles(
        container: container,
        l10n: l10n,
        items: items,
        initialIndex: initialIndex,
        initialEntry: initialEntry,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-image-viewer-prepare-failed',
        scope: 'chat/image-viewer',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      onPreparing(false);
    }
    if (files != null) {
      try {
        if (!context.mounted) return;
        final presented = await bridge.present(
          files: files.files,
          initialIndex: files.initialIndex,
          sourceRect: sourceRect,
        );
        if (presented) return;
      } finally {
        await deleteImageSessionDirectory(files.directory);
      }
    }
  }

  if (!context.mounted) return;
  final aspectRatio = _decodedAspectRatioOf(context);
  await Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      fullscreenDialog: true,
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) =>
          FullScreenImageViewer(
            items: items,
            initialIndex: initialIndex,
            initialEntry: initialEntry,
            initialAspectRatio: aspectRatio,
            heroTag: heroTag,
          ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _NativeViewerFiles {
  const _NativeViewerFiles(this.directory, this.files, this.initialIndex);

  final Directory directory;
  final List<NativeImageFile> files;
  final int initialIndex;
}

/// How long the tapped thumbnail waits for every gallery image to be written
/// before it opens the Flutter viewer instead.
const _nativeViewerPrepareTimeout = Duration(seconds: 4);

/// Writes every gallery image to a private session directory.
///
/// Returns `null` when any image fails, is an SVG (which Quick Look does not
/// render reliably), or is not ready within [_nativeViewerPrepareTimeout].
/// The Flutter viewer then shows every page, including failed ones, so the
/// page count always matches the message.
Future<_NativeViewerFiles?> _prepareNativeViewerFiles({
  required ProviderContainer container,
  required AppLocalizations l10n,
  required List<ImageViewerItem> items,
  required int initialIndex,
  required ImageAttachmentCacheEntry initialEntry,
}) async {
  final directory = await createImageSessionDirectory('viewer');
  try {
    var hasSvg = false;
    final written = await Future.wait([
      for (var i = 0; i < items.length; i++)
        () async {
          try {
            final entry = i == initialIndex
                ? initialEntry
                : await _resolveViewerEntry(
                    container,
                    items[i].attachmentId,
                    l10n,
                  );
            if (entry.error != null) return null;
            if (entry.isSvg) {
              hasSvg = true;
              return null;
            }
            final image = await _loadViewerImageBytes(
              container,
              entry,
              items[i].httpHeaders,
            );
            if (image.type.isSvg) {
              hasSvg = true;
              return null;
            }
            return await writeImageFile(
              image.bytes,
              directory: directory,
              baseName: 'image-${i + 1}',
              type: image.type,
            );
          } catch (error, stackTrace) {
            DebugLogger.error(
              'native-image-viewer-prepare-failed',
              scope: 'chat/image-viewer',
              error: error,
              stackTrace: stackTrace,
              data: {'index': i, 'count': items.length},
            );
            return null;
          }
        }(),
    ]).timeout(_nativeViewerPrepareTimeout, onTimeout: () => const []);

    if (hasSvg || written.length != items.length || written.contains(null)) {
      // Late writes into the deleted directory fail and are logged above.
      await deleteImageSessionDirectory(directory);
      return null;
    }

    final files = [
      for (var i = 0; i < written.length; i++)
        NativeImageFile(
          path: written[i]!.path,
          title: written.length > 1
              ? l10n.imageViewerPosition(i + 1, written.length)
              : l10n.imageFileType,
        ),
    ];
    return _NativeViewerFiles(directory, files, initialIndex);
  } catch (_) {
    await deleteImageSessionDirectory(directory);
    rethrow;
  }
}

/// Flutter image viewer with paging, zoom, swipe-to-dismiss, share, and
/// (on Android 10+) save to the device gallery.
class FullScreenImageViewer extends ConsumerStatefulWidget {
  const FullScreenImageViewer({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.initialEntry,
    this.initialAspectRatio,
    required this.heroTag,
  }) : assert(items.length > 0, 'At least one image is required');

  final List<ImageViewerItem> items;
  final int initialIndex;

  /// Already-loaded data for the item at [initialIndex].
  final ImageAttachmentCacheEntry? initialEntry;

  /// Width-to-height ratio of the tapped thumbnail's image, when decoded.
  /// Sizes the hero so the opening flight ends on the fitted image.
  final double? initialAspectRatio;

  /// Hero tag of the tapped thumbnail. Only the initial page uses it.
  final String heroTag;

  @override
  ConsumerState<FullScreenImageViewer> createState() =>
      _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends ConsumerState<FullScreenImageViewer>
    with SingleTickerProviderStateMixin {
  static const _dismissDistance = 120.0;
  static const _dismissVelocity = 900.0;

  late final PageController _pageController;
  late final AnimationController _settleController;
  late int _index;
  final Map<int, ImageAttachmentCacheEntry> _entries = {};
  final Set<int> _resolving = {};
  bool _zoomed = false;
  bool _chromeVisible = true;
  bool _busy = false;
  bool _canSave = false;
  double _dragOffset = 0;
  double _settleFrom = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    _pageController = PageController(initialPage: _index);
    _settleController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 180),
        )..addListener(() {
          setState(() {
            _dragOffset =
                _settleFrom *
                (1 - Curves.easeOut.transform(_settleController.value));
          });
        });
    if (widget.initialEntry case final entry?) {
      _entries[_index] = entry;
    }
    unawaited(
      NativeImageViewerBridge.instance.canSaveImages().then((canSave) {
        if (mounted && canSave) setState(() => _canSave = true);
      }),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _settleController.dispose();
    super.dispose();
  }

  ImageAttachmentCacheEntry? _entryAt(int index) {
    final entry = _entries[index];
    if (entry != null || !_resolving.add(index)) return entry;
    final container = ProviderScope.containerOf(context, listen: false);
    final l10n = AppLocalizations.of(context)!;
    unawaited(
      _resolveViewerEntry(
        container,
        widget.items[index].attachmentId,
        l10n,
      ).then((resolved) {
        if (!mounted) return;
        setState(() {
          _entries[index] = resolved;
          _resolving.remove(index);
        });
      }),
    );
    return null;
  }

  void _onDismissDrag(double delta) {
    if (_zoomed) return;
    _settleController.stop();
    setState(() => _dragOffset += delta);
  }

  void _onDismissDragEnd(double velocity) {
    if (_dragOffset == 0) return;
    if (_dragOffset.abs() > _dismissDistance ||
        velocity.abs() > _dismissVelocity) {
      Navigator.of(context).maybePop();
      return;
    }
    _settleFrom = _dragOffset;
    _settleController.forward(from: 0);
  }

  void _onZoomChanged(int index, bool zoomed) {
    if (index != _index || zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() => _runBusy(() async {
    final entry = _entries[_index];
    if (entry == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    Directory? directory;
    try {
      final image = await _loadViewerImageBytes(
        container,
        entry,
        widget.items[_index].httpHeaders,
      );
      directory = await createImageSessionDirectory('share');
      final file = await writeImageFile(
        image.bytes,
        directory: directory,
        baseName: 'conduit_image',
        type: image.type,
      );
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, mimeType: image.type.mimeType)]),
      );
    } catch (e) {
      // Share failures stay silent; keep a log for debugging.
      DebugLogger.log(
        'Failed to share image: $e',
        scope: 'chat/image-attachment',
      );
    } finally {
      // The share target may read the file after share() returns, so the
      // next image session purges it once it is old enough.
      if (directory != null) releaseImageSessionDirectory(directory);
    }
  });

  Future<void> _save() => _runBusy(() async {
    final entry = _entries[_index];
    if (entry == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final l10n = AppLocalizations.of(context)!;
    Directory? directory;
    var saved = false;
    try {
      final image = await _loadViewerImageBytes(
        container,
        entry,
        widget.items[_index].httpHeaders,
      );
      if (image.type.isSvg) throw StateError('SVG cannot be saved');
      directory = await createImageSessionDirectory('save');
      final name = 'conduit_${DateTime.now().millisecondsSinceEpoch}';
      final file = await writeImageFile(
        image.bytes,
        directory: directory,
        baseName: name,
        type: image.type,
      );
      await NativeImageViewerBridge.instance.saveImage(
        path: file.path,
        mimeType: image.type.mimeType,
        displayName: '$name.${image.type.extension}',
      );
      saved = true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'image-save-failed',
        scope: 'chat/image-viewer',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (directory != null) await deleteImageSessionDirectory(directory);
    }
    if (!mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: saved ? l10n.imageSaved : l10n.imageSaveFailed,
      type: saved ? AdaptiveSnackBarType.success : AdaptiveSnackBarType.error,
    );
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.colorTokens;
    final iconColor = tokens.neutralOnSurface;
    final l10n = AppLocalizations.of(context)!;
    final count = widget.items.length;
    final dragProgress = (_dragOffset.abs() / 400).clamp(0.0, 1.0);
    final currentEntry = _entries[_index];
    final canAct = currentEntry != null && currentEntry.error == null;
    final showChrome = _chromeVisible && _dragOffset == 0;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: tokens.neutralTone10.withValues(
                alpha: 1 - dragProgress * 0.8,
              ),
            ),
          ),
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(0, _dragOffset),
              child: PageView.builder(
                controller: _pageController,
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: count,
                onPageChanged: (index) => setState(() {
                  _index = index;
                  _zoomed = false;
                }),
                itemBuilder: (context, index) => _buildPage(index),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 16,
            left: 16,
            right: 16,
            child: IgnorePointer(
              ignoring: !showChrome,
              child: AnimatedOpacity(
                opacity: showChrome ? 1 : 0,
                duration: context.reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 150),
                child: Row(
                  children: [
                    if (count > 1)
                      Text(
                        l10n.imageViewerPosition(_index + 1, count),
                        style: AppTypography.bodyMediumStyle.copyWith(
                          color: iconColor,
                        ),
                      ),
                    const Spacer(),
                    if (_canSave && canAct && !currentEntry.isSvg) ...[
                      ConduitIconButton(
                        icon: Icons.download_outlined,
                        iconColor: iconColor,
                        tooltip: l10n.saveImage,
                        onPressed: _busy ? null : _save,
                      ),
                      const SizedBox(width: 8),
                    ],
                    ConduitIconButton(
                      icon: Platform.isIOS
                          ? Icons.ios_share
                          : Icons.share_outlined,
                      iconColor: iconColor,
                      tooltip: l10n.shareSystemSheet,
                      onPressed: _busy || !canAct ? null : _share,
                    ),
                    const SizedBox(width: 8),
                    ConduitIconButton(
                      icon: Icons.close,
                      iconColor: iconColor,
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPage(int index) {
    final entry = _entryAt(index);
    final Widget content;
    if (entry == null) {
      content = Center(
        child: CircularProgressIndicator(
          color: context.conduitTheme.buttonPrimary,
        ),
      );
    } else {
      content = _FullScreenImageContent(
        imageData: entry.resolvedData,
        imageBytes: entry.bytes,
        isSvg: entry.isSvg,
        customHeaders: widget.items[index].httpHeaders,
      );
    }

    return _ZoomableImagePage(
      onZoomChanged: (zoomed) => _onZoomChanged(index, zoomed),
      onTap: () => setState(() => _chromeVisible = !_chromeVisible),
      onDismissDrag: _onDismissDrag,
      onDismissDragEnd: _onDismissDragEnd,
      child: index == widget.initialIndex
          ? HeroMode(
              enabled: !context.reduceMotion,
              child: Hero(
                tag: widget.heroTag,
                child: switch (widget.initialAspectRatio) {
                  final ratio? => AspectRatio(
                    aspectRatio: ratio,
                    child: content,
                  ),
                  null => content,
                },
              ),
            )
          : content,
    );
  }
}

/// One zoomable page. Double-tap toggles zoom; a one-finger vertical drag
/// while not zoomed is reported for swipe-to-dismiss.
class _ZoomableImagePage extends StatefulWidget {
  const _ZoomableImagePage({
    required this.child,
    required this.onZoomChanged,
    required this.onTap,
    required this.onDismissDrag,
    required this.onDismissDragEnd,
  });

  final Widget child;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback onTap;
  final ValueChanged<double> onDismissDrag;
  final ValueChanged<double> onDismissDragEnd;

  @override
  State<_ZoomableImagePage> createState() => _ZoomableImagePageState();
}

class _ZoomableImagePageState extends State<_ZoomableImagePage>
    with SingleTickerProviderStateMixin {
  static const _doubleTapScale = 2.5;

  final _transformation = TransformationController();
  late final AnimationController _zoomAnimation;
  Animation<Matrix4>? _zoomTween;
  Offset _doubleTapPosition = Offset.zero;
  bool _zoomed = false;
  bool _dismissDragging = false;

  @override
  void initState() {
    super.initState();
    _zoomAnimation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
        )..addListener(() {
          if (_zoomTween case final tween?) {
            _transformation.value = tween.value;
          }
        });
    _transformation.addListener(_onTransformationChanged);
  }

  @override
  void dispose() {
    _zoomAnimation.dispose();
    _transformation.dispose();
    super.dispose();
  }

  void _onTransformationChanged() {
    final zoomed = _transformation.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged(zoomed);
  }

  void _toggleZoom() {
    final Matrix4 target;
    if (_zoomed) {
      target = Matrix4.identity();
    } else {
      const s = _doubleTapScale;
      final p = _doubleTapPosition;
      target = Matrix4.identity()
        ..setEntry(0, 0, s)
        ..setEntry(1, 1, s)
        ..setTranslationRaw(-p.dx * (s - 1), -p.dy * (s - 1), 0);
    }
    if (context.reduceMotion) {
      _transformation.value = target;
      return;
    }
    _zoomTween = Matrix4Tween(
      begin: _transformation.value,
      end: target,
    ).animate(CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOut));
    _zoomAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transformation,
        minScale: 1,
        maxScale: 5,
        onInteractionStart: (details) {
          _zoomAnimation.stop();
          _dismissDragging = !_zoomed && details.pointerCount == 1;
        },
        onInteractionUpdate: (details) {
          if (!_dismissDragging) return;
          if (details.pointerCount != 1 || _zoomed) {
            // A second finger turned the drag into a pinch.
            _dismissDragging = false;
            widget.onDismissDragEnd(0);
            return;
          }
          widget.onDismissDrag(details.focalPointDelta.dy);
        },
        onInteractionEnd: (details) {
          if (!_dismissDragging) return;
          _dismissDragging = false;
          widget.onDismissDragEnd(details.velocity.pixelsPerSecond.dy);
        },
        child: SizedBox.expand(child: Center(child: widget.child)),
      ),
    );
  }
}

class _FullScreenImageContent extends ConsumerWidget {
  const _FullScreenImageContent({
    this.imageData,
    this.imageBytes,
    required this.isSvg,
    this.customHeaders,
  });

  /// Image data as a URL (http://) or data URL (data:image/...) or base64 string.
  final String? imageData;

  /// Raw image bytes. Used when [imageData] is null.
  final Uint8List? imageBytes;
  final bool isSvg;
  final Map<String, String>? customHeaders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget imageWidget;
    final viewportSize = MediaQuery.sizeOf(context);
    final decodeTarget = RasterMediaPolicy.forBox(
      context,
      profile: RasterDecodeProfile.fullScreen,
    );
    Widget errorIcon(BuildContext context) => Center(
      child: Icon(
        Icons.error_outline,
        color: context.conduitTheme.error,
        size: 48,
      ),
    );

    final imageData = this.imageData;
    final imageBytes = this.imageBytes;
    if (imageBytes != null &&
        (imageData == null || !_isRemoteContentValue(imageData))) {
      // Decoded bytes are already cached for data URLs and file contents.
      if (isSvg || _isSvgBytes(imageBytes)) {
        imageWidget = JovialSvgImage.bytes(
          imageBytes,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => errorIcon(context),
        );
      } else {
        imageWidget = Image(
          image: RasterMediaPolicy.resizeProvider(
            MemoryImage(imageBytes),
            decodeTarget,
          ),
          fit: BoxFit.contain,
        );
      }
    } else if (imageData != null && imageData.startsWith('http')) {
      final defaultHeaders = buildImageHeadersForUrlFromWidgetRef(
        ref,
        imageData,
      );
      final headers = _mergeHeaders(defaultHeaders, customHeaders);
      final networkCacheKey = buildImageCacheKeyForUrlFromWidgetRef(
        ref,
        imageData,
        effectiveHeaders: headers,
      );

      if (isSvg || _isSvgUrl(imageData)) {
        imageWidget = JovialSvgImage.network(
          imageData,
          fit: BoxFit.contain,
          headers: headers,
          cacheIdentity: networkCacheKey,
          placeholderBuilder: (context) => Center(
            child: CircularProgressIndicator(
              color: context.conduitTheme.buttonPrimary,
            ),
          ),
          errorBuilder: (context, error, stackTrace) => errorIcon(context),
        );
      } else {
        final cacheManager = ref.watch(selfSignedImageCacheManagerProvider);
        imageWidget = Image(
          image: RasterMediaPolicy.resizeProvider(
            CachedNetworkImageProvider(
              imageData,
              cacheKey: networkCacheKey,
              cacheManager: cacheManager,
              headers: headers,
            ),
            decodeTarget,
          ),
          width: viewportSize.width,
          height: viewportSize.height,
          fit: BoxFit.contain,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            return wasSynchronouslyLoaded || frame != null
                ? child
                : SizedBox.fromSize(
                    size: viewportSize,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: context.conduitTheme.buttonPrimary,
                      ),
                    ),
                  );
          },
          errorBuilder: (context, error, stackTrace) => errorIcon(context),
        );
      }
    } else if (imageData != null) {
      try {
        final decodedBytes = _decodeImageData(imageData);
        if (isSvg || _isSvgDataUrl(imageData) || _isSvgBytes(decodedBytes)) {
          imageWidget = JovialSvgImage.bytes(
            decodedBytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => errorIcon(context),
          );
        } else {
          imageWidget = Image(
            image: RasterMediaPolicy.resizeProvider(
              MemoryImage(decodedBytes),
              decodeTarget,
            ),
            fit: BoxFit.contain,
          );
        }
      } catch (e) {
        imageWidget = errorIcon(context);
      }
    } else {
      imageWidget = errorIcon(context);
    }

    return imageWidget;
  }
}
