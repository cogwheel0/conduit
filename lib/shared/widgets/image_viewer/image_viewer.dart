import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../l10n/app_localizations.dart';
import '../../../platform/native_image_preview.dart';
import '../../services/raster_media_policy.dart';
import '../../utils/platform_page_route.dart';
import '../../theme/theme_extensions.dart';
import '../jovial_svg_image.dart';
import 'image_viewer_canvas.dart';
import 'image_viewer_media.dart';

export 'image_viewer_media.dart';

PageRoute<void> buildImageViewerRoute(
  BuildContext context, {
  required List<ImageViewerItem> items,
  int initialIndex = 0,
  ValueListenable<bool>? active,
  bool Function()? isCurrent,
}) {
  Widget builder(BuildContext context) => ImageViewer(
    items: items,
    initialIndex: initialIndex,
    active: active,
    isCurrent: isCurrent,
  );
  if (defaultTargetPlatform == TargetPlatform.iOS || context.reduceMotion) {
    return PageRouteBuilder<void>(
      fullscreenDialog: true,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => builder(context),
    );
  }
  return buildPlatformPageRoute<void>(fullscreenDialog: true, builder: builder);
}

class ImageViewer extends StatefulWidget {
  ImageViewer({
    super.key,
    required List<ImageViewerItem> items,
    this.initialIndex = 0,
    this.active,
    this.isCurrent,
  }) : items = List.unmodifiable(items),
       assert(items.isNotEmpty),
       assert(initialIndex >= 0 && initialIndex < items.length);

  final List<ImageViewerItem> items;
  final int initialIndex;

  /// The calling feature owns connection/session lifetime. A false value
  /// closes the preview and prevents pending loads or exports from completing.
  final ValueListenable<bool>? active;

  /// Rechecks operation authority immediately before and after asynchronous work.
  final bool Function()? isCurrent;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late int _index = widget.initialIndex;
  int _generation = 0;
  ImageViewerMedia? _media;
  Widget? _svg;
  bool _failed = false;
  bool _controls = true;
  bool _busy = false;
  bool _closing = false;
  bool _nativePresented = false;
  bool _defaultPreviewPending = defaultTargetPlatform == TargetPlatform.iOS;
  bool _openingDefaultPreview = false;
  double _decodeScale = 1;
  ImageProvider<Object>? _provider;
  final _shareAnchor = GlobalKey();

  bool get _active =>
      mounted &&
      !_closing &&
      widget.active?.value != false &&
      widget.isCurrent?.call() != false;

  @override
  void initState() {
    super.initState();
    widget.active?.addListener(_ownerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ownerChanged();
    });
    unawaited(_load());
  }

  void _ownerChanged() {
    if (widget.active?.value != false) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _close();
      });
    } else {
      _close();
    }
  }

  @override
  void didUpdateWidget(covariant ImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      oldWidget.active?.removeListener(_ownerChanged);
      widget.active?.addListener(_ownerChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ownerChanged();
      });
    }
  }

  Future<void> _load({bool refresh = false}) async {
    final generation = ++_generation;
    final item = widget.items[_index];
    try {
      if (refresh) await item.invalidate?.call();
      if (!_active || generation != _generation) return;
      final media = await item.load();
      final svgBytes = media.isSvg ? await media.readBytes() : null;
      if (!_active || generation != _generation) return;
      setState(() {
        _media = media;
        _svg = svgBytes == null
            ? null
            : JovialSvgImage.bytes(
                svgBytes,
                errorBuilder: (_, _, _) => _error(),
              );
        _failed = false;
      });
      if (_defaultPreviewPending) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_active ||
              !_defaultPreviewPending ||
              generation != _generation) {
            return;
          }
          _defaultPreviewPending = false;
          _openingDefaultPreview = true;
          unawaited(_export(native: true, closeAfterNative: true));
        });
      }
    } catch (_) {
      if (!_active || generation != _generation) return;
      setState(() => _failed = true);
    }
  }

  void _releaseFrame() {
    final provider = _provider;
    _provider = null;
    if (provider != null) unawaited(provider.evict());
  }

  void _page(int delta) {
    final next = _index + delta;
    if (_busy ||
        _defaultPreviewPending ||
        next < 0 ||
        next >= widget.items.length) {
      return;
    }
    _releaseFrame();
    setState(() {
      _index = next;
      _media = null;
      _svg = null;
      _failed = false;
      _decodeScale = 1;
      _controls = true;
    });
    unawaited(_load());
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    ++_generation;
    unawaited(_dismissNative());
    final route = ModalRoute.of(context);
    final navigator = route?.navigator;
    if (route == null || navigator == null) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  Future<void> _dismissNative() async {
    if (!_nativePresented) return;
    _nativePresented = false;
    try {
      await NativeImagePreview.dismiss();
    } catch (_) {
      // No native presentation exists on unsupported platforms or test hosts.
    }
  }

  @override
  void dispose() {
    widget.active?.removeListener(_ownerChanged);
    ++_generation;
    _releaseFrame();
    unawaited(_dismissNative());
    super.dispose();
  }

  Widget _error() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.broken_image_outlined,
            color: Colors.white70,
            size: 40,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.unableToLoadImage,
            style: const TextStyle(color: Colors.white),
          ),
          TextButton(
            onPressed: () {
              _releaseFrame();
              setState(() {
                _failed = false;
                _media = null;
                _svg = null;
              });
              unawaited(_load(refresh: true));
            },
            child: Text(l10n.retry),
          ),
        ],
      ),
    );
  }

  Widget _image(Size viewport) {
    if (_failed) return _error();
    if (_defaultPreviewPending || _openingDefaultPreview) {
      return const Center(child: CircularProgressIndicator());
    }
    final media = _media;
    if (media == null) return const Center(child: CircularProgressIndicator());
    if (_svg != null) return _hero(_svg!);
    // Decode only the active page, and adjust detail after a gesture
    // settles. Six million pixels bound a decoded RGBA frame to about 24 MB.
    final base = RasterMediaPolicy.target(
      profile: RasterDecodeProfile.fullScreen,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      logicalWidth: viewport.width,
      logicalHeight: viewport.height,
    );
    final width = base.width * _decodeScale;
    final height = base.height * _decodeScale;
    final ratio = math.min(
      1.0,
      math.min(
        6144 / math.max(width, height),
        math.sqrt(6000000 / (width * height)),
      ),
    );
    final target = RasterDecodeTarget(
      width: math.max(1, (width * ratio).round()),
      height: math.max(1, (height * ratio).round()),
    );
    final original = media.file != null
        ? FileImage(media.file!)
        : MemoryImage(media.bytes!) as ImageProvider<Object>;
    final provider = RasterMediaPolicy.resizeProvider(original, target);
    if (_provider != provider) {
      _releaseFrame();
      _provider = provider;
    }
    final item = widget.items[_index];
    final image = Image(
      image: provider,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      semanticLabel: item.label,
      frameBuilder: (_, child, frame, synchronous) =>
          frame != null || synchronous
          ? child
          : const Center(child: CircularProgressIndicator()),
      errorBuilder: (_, _, _) => _error(),
    );
    return _hero(image);
  }

  Widget _hero(Widget image) {
    final item = widget.items[_index];
    return item.heroTag == null || context.reduceMotion
        ? image
        : Hero(tag: item.heroTag!, child: image);
  }

  Future<void> _export({
    required bool native,
    bool closeAfterNative = false,
  }) async {
    final media = _media;
    if (media == null || _busy || !_active) return;
    final l10n = AppLocalizations.of(context)!;
    final generation = _generation;
    final box = _shareAnchor.currentContext?.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _busy = true);
    File? staged;
    bool handedOff = false;
    try {
      staged = await media.stage();
      if (!_active || generation != _generation) return;
      if (native) {
        _nativePresented = true;
        try {
          await NativeImagePreview.open(staged);
        } finally {
          _nativePresented = false;
        }
      } else {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(staged.path)], sharePositionOrigin: origin),
        );
      }
      handedOff = true;
      if (closeAfterNative && _active && generation == _generation) _close();
    } catch (_) {
      DebugLogger.log('Image export failed', scope: 'images/export');
      if (!closeAfterNative && mounted && _active) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.imageViewerExportFailed)));
      }
    } finally {
      // Android receivers and share extensions may keep reading after their
      // handoff returns. They become eligible for pruning after a day.
      if (staged != null &&
          (!handedOff ||
              (native && defaultTargetPlatform == TargetPlatform.iOS))) {
        await staged.parent
            .delete(recursive: true)
            .catchError((_) => staged!.parent);
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _openingDefaultPreview = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final item = widget.items[_index];
    final showControls =
        _controls || MediaQuery.accessibleNavigationOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _page(1),
      },
      child: Focus(
        autofocus: true,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return ImageViewerCanvas(
                        key: ValueKey((_index, _generation)),
                        onTap: () => setState(() => _controls = !_controls),
                        onDismiss: _busy ? () {} : _close,
                        onPage: _page,
                        zoomLabel: l10n.imageViewerZoom,
                        resetLabel: l10n.imageViewerResetZoom,
                        onZoomSettled: (scale) {
                          if (scale != _decodeScale && mounted) {
                            setState(() => _decodeScale = scale);
                          }
                        },
                        child: _image(constraints.biggest),
                      );
                    },
                  ),
                ),
                SafeArea(
                  child: IgnorePointer(
                    ignoring: !showControls,
                    child: ExcludeSemantics(
                      excluding: !showControls,
                      child: AnimatedOpacity(
                        opacity: showControls ? 1 : 0,
                        duration: context.motionDuration(
                          AnimationDuration.fast,
                        ),
                        child: Column(
                          children: [
                            ColoredBox(
                              color: Colors.black54,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                child: Row(
                                  children: [
                                    _button(
                                      Icons.close,
                                      MaterialLocalizations.of(context)
                                          .closeButtonTooltip,
                                      _close,
                                    ),
                                    Expanded(
                                      child: Text(
                                        item.label ??
                                            l10n.imageViewerPosition(
                                              _index + 1,
                                              widget.items.length,
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    if (_busy)
                                      const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(),
                                      ),
                                    if (Platform.isIOS || Platform.isAndroid)
                                      _button(
                                        Icons.open_in_new,
                                        Platform.isIOS
                                            ? l10n.imageViewerQuickLook
                                            : l10n.imageViewerOpenIn,
                                        _media == null ||
                                                _busy ||
                                                _defaultPreviewPending
                                            ? null
                                            : () => _export(native: true),
                                      ),
                                    KeyedSubtree(
                                      key: _shareAnchor,
                                      child: _button(
                                        Platform.isIOS
                                            ? Icons.ios_share
                                            : Icons.share_outlined,
                                        l10n.shareSystemSheet,
                                        _media == null ||
                                                _busy ||
                                                _defaultPreviewPending
                                            ? null
                                            : () => _export(native: false),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (widget.items.length > 1)
                              ColoredBox(
                                color: Colors.black54,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _button(
                                      Icons.chevron_left,
                                      l10n.imageViewerPrevious,
                                      _index > 0 &&
                                              !_busy &&
                                              !_defaultPreviewPending
                                          ? () => _page(-1)
                                          : null,
                                    ),
                                    Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        l10n.imageViewerPosition(
                                          _index + 1,
                                          widget.items.length,
                                        ),
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    _button(
                                      Icons.chevron_right,
                                      l10n.imageViewerNext,
                                      _index + 1 < widget.items.length &&
                                              !_busy &&
                                              !_defaultPreviewPending
                                          ? () => _page(1)
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _button(IconData icon, String label, VoidCallback? action) =>
      IconButton(
        icon: Icon(icon),
        color: Colors.white,
        disabledColor: Colors.white38,
        tooltip: label,
        onPressed: action,
      );
}
