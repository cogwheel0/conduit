import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

/// Dedicated, explicitly-bounded disk cache for PDFs, isolated from the app-wide
/// image cache. flutter_cache_manager's DefaultCacheManager keeps up to 200
/// objects for 30 days with no total-byte ceiling; mixing multi-MB PDFs into it
/// risks unbounded disk growth. This keeps the PDF cache small and predictable.
final BaseCacheManager _pdfCacheManager = CacheManager(
  Config(
    'conduit_pdf_cache',
    stalePeriod: const Duration(days: 7),
    maxNrOfCacheObjects: 30,
  ),
);

/// Inline PDF card rendered inside a chat message.
///
/// When a markdown link points at a PDF (a URL ending in `.pdf`), the markdown
/// inline renderer ([InlineRenderer._renderLink]) renders this widget instead of
/// a plain hyperlink, so PDFs sent in a conversation are viewable in place.
///
/// When the card appears the PDF is downloaded once and cached to a local file,
/// and its first page is pre-rasterized to a held [ui.Image] (a fixed image, not
/// pdfrx's live `PdfPageView`, so the preview never flashes white on rebuild).
/// Tapping opens [_PdfFullscreenPage], which rasterizes pages lazily around the
/// viewport under a hard memory budget.
class PdfInlineView extends StatefulWidget {
  const PdfInlineView({super.key, required this.url, this.label});

  /// Absolute URL of the PDF.
  final String url;

  /// Display label taken from the markdown link text (e.g. the file name).
  final String? label;

  /// Returns true when [href] is a link the inline PDF viewer should render:
  /// a URL whose path ends in `.pdf`.
  static bool isPdfLink(String href) {
    if (href.isEmpty) return false;
    // Strip both query string and fragment before the extension check, so
    // `report.pdf?token=…` and `report.pdf#page=3` are still detected.
    return href
        .split('?')
        .first
        .split('#')
        .first
        .toLowerCase()
        .endsWith('.pdf');
  }

  @override
  State<PdfInlineView> createState() => _PdfInlineViewState();
}

class _PdfInlineViewState extends State<PdfInlineView> {
  /// Preview render width, matched to the card's on-screen footprint (the card
  /// is <=560 logical px, cover-cropped) — no need to hold a screen-sized bitmap.
  static const double _previewRenderWidth = 720;

  String? _filePath;
  ui.Image? _previewImage;
  bool _previewSettled = false;
  bool _error = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PdfInlineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A markdown card can be re-bound to a different URL during streaming
    // re-compilation; reload (and free the old preview) so we never show a
    // stale document.
    if (oldWidget.url != widget.url) {
      _previewImage?.dispose();
      _previewImage = null;
      _filePath = null;
      _previewSettled = false;
      _error = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final loadingUrl = widget.url;
    try {
      // pdfrx engine init is idempotent; awaiting it removes a cold-start race
      // where openFile runs before the PDFium engine is ready.
      await pdfrxFlutterInitialize();
      final file = await _pdfCacheManager.getSingleFile(loadingUrl);
      if (_disposed || loadingUrl != widget.url) return;
      setState(() => _filePath = file.path);

      final doc = await PdfDocument.openFile(file.path);
      try {
        if (doc.pages.isEmpty) return;
        final page = doc.pages.first;
        final pdfImage = await page.render(
          fullWidth: _previewRenderWidth,
          fullHeight: _previewRenderWidth * page.height / page.width,
        );
        ui.Image? image;
        if (pdfImage != null) {
          try {
            image = await pdfImage.createImage();
          } finally {
            pdfImage.dispose();
          }
        }
        if (_disposed || loadingUrl != widget.url) {
          image?.dispose();
          return;
        }
        setState(() {
          _previewImage = image;
          _previewSettled = true;
        });
      } finally {
        await doc.dispose();
      }
    } catch (_) {
      if (!_disposed && loadingUrl == widget.url) {
        setState(() {
          _error = true;
          _previewSettled = true;
        });
      }
    }
  }

  void _retryLoad() {
    setState(() {
      _error = false;
      _previewSettled = false;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    _previewImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = _cleanPdfLabel(widget.label);
    final ready = _filePath != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            button: true,
            label: ready ? 'Open PDF: $title' : 'PDF loading: $title',
            child: InkWell(
              onTap: ready
                  ? () => _openFullscreen(context, _filePath!, title)
                  : (_error ? _retryLoad : null),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 360,
                    child: ColoredBox(
                      color: scheme.surface,
                      child: _buildPreview(scheme, title),
                    ),
                  ),
                  _buildBar(title, scheme, ready: ready),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(ColorScheme scheme, String title) {
    final image = _previewImage;
    final Widget content;
    if (_error) {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, color: scheme.error),
            const SizedBox(height: 6),
            Text(
              'Tap to retry',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      );
    } else if (image != null) {
      content = Semantics(
        image: true,
        label: 'Preview of first page: $title',
        child: RawImage(
          image: image,
          fit: BoxFit.fitWidth,
          alignment: Alignment.topCenter,
        ),
      );
    } else if (_previewSettled) {
      content = Center(
        child: Icon(Icons.picture_as_pdf, size: 48, color: scheme.primary),
      );
    } else {
      content = const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        if (image != null)
          Positioned(
            right: 10,
            bottom: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: Icon(
                  Icons.open_in_full,
                  size: 16,
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBar(String title, ColorScheme scheme, {required bool ready}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.picture_as_pdf, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (ready)
            IconButton(
              onPressed: () => unawaited(_sharePdf(_filePath!, title)),
              icon: Icon(Icons.share, size: 19, color: scheme.primary),
              tooltip: 'Share',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            ),
          Text(
            ready ? 'Open' : 'Loading …',
            style: TextStyle(color: scheme.primary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _openFullscreen(BuildContext context, String path, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _PdfFullscreenPage(path: path, title: title),
      ),
    );
  }
}

String _cleanPdfLabel(String? raw) {
  final text = (raw ?? '').replaceFirst('📄', '').trim();
  return text.isEmpty ? 'PDF document' : text;
}

/// Shares the local PDF via the OS share sheet (share_plus) under a meaningful
/// filename.
///
/// flutter_cache_manager stores the download under a random hash filename, and
/// neither [XFile.name] nor [ShareParams.fileNameOverrides] is reliably honoured
/// on Android. To control the name robustly, the cached file is copied to a temp
/// file (in a per-share unique subdirectory, so same-titled documents never
/// collide and an in-flight share is never overwritten) whose on-disk name IS
/// the document title. Old share temp dirs are swept on each share so they do
/// not accumulate (share_plus never cleans them up).
Future<void> _sharePdf(String path, String title) async {
  final name = _pdfFileName(title);
  try {
    final base = await getTemporaryDirectory();
    final root = Directory('${base.path}/pdf-share');
    await _sweepOldShareTemps(root);
    final shareDir = Directory(
      '${root.path}/${DateTime.now().microsecondsSinceEpoch}',
    );
    await shareDir.create(recursive: true);
    final dest = File('${shareDir.path}/$name');
    await File(path).copy(dest.path);
    await SharePlus.instance.share(ShareParams(files: [XFile(dest.path)]));
  } catch (_) {
    // Fall back to sharing the cached file directly if the copy fails.
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], fileNameOverrides: [name]),
    );
  }
}

/// Best-effort removal of share temp dirs older than ~1h (a share sheet is never
/// open that long), so the temp area does not grow unbounded.
Future<void> _sweepOldShareTemps(Directory root) async {
  try {
    if (!await root.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entry in root.list()) {
      try {
        if ((await entry.stat()).modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      } catch (_) {}
    }
  } catch (_) {}
}

/// Builds a readable, filesystem-friendly share filename from the document title.
String _pdfFileName(String title) {
  // Keep Unicode letters/digits (umlauts, accents, CJK, …): Dart's `\w` is
  // ASCII-only even with `unicode: true`, so a German/CJK title would otherwise
  // be stripped to spaces. `\p{L}\p{N}` with `unicode: true` retains them.
  var base = title
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s._\-]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (base.length > 80) base = base.substring(0, 80).trim();
  if (base.isEmpty) base = 'document';
  return base.toLowerCase().endsWith('.pdf') ? base : '$base.pdf';
}

/// Fullscreen PDF route. Rasterizes pages to [ui.Image]s lazily around the
/// viewport and holds them under a hard byte budget with LRU eviction, so a
/// large document can never blow up memory while small documents stay fully
/// resident and flicker-free.
///
/// Why not pdfrx's `PdfViewer`: it rasterizes pages lazily on paint, drawing a
/// blank white rectangle until the async render lands — very visible in a debug
/// build. Showing only already-rasterized images means a page is never white;
/// not-yet-rendered pages show a neutral surface-colored loading box, and a
/// plain [ListView] gives real momentum/fling for free.
class _PdfFullscreenPage extends StatefulWidget {
  const _PdfFullscreenPage({required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<_PdfFullscreenPage> createState() => _PdfFullscreenPageState();
}

class _PdfFullscreenPageState extends State<_PdfFullscreenPage> {
  /// Hard ceiling on decoded bitmap memory held at once (~10 A4 pages at panel
  /// width). Small docs fit entirely → never evicted → never white. Large docs
  /// stay bounded regardless of page count.
  static const int _maxBitmapBytes = 64 * 1024 * 1024;

  PdfDocument? _doc;
  bool _disposed = false;
  bool _started = false;
  Object? _error;
  int _pageCount = 0;
  List<double> _aspects = const <double>[];
  double _targetWidth = 1080;

  final Map<int, ui.Image> _images = <int, ui.Image>{};
  final List<int> _lru = <int>[]; // most-recently-used at front
  final Set<int> _rendering = <int>{};
  final Set<int> _failed = <int>{};
  int _heldBytes = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final media = MediaQuery.of(context);
    // Render at panel-native pixel width (capped). Rendering wider than the
    // screen only wastes memory in a no-zoom viewer.
    _targetWidth = (media.size.width * media.devicePixelRatio).clamp(
      800.0,
      1080.0,
    );
    unawaited(_open());
  }

  Future<void> _open() async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(widget.path);
      if (_disposed) {
        await doc.dispose();
        return;
      }
      final pages = doc.pages;
      // Dispose any previous document first (a "Try again" re-open would
      // otherwise overwrite _doc and leak the old one).
      await _doc?.dispose();
      _doc = doc;
      doc = null; // ownership transferred to _doc
      setState(() {
        _pageCount = pages.length;
        _aspects = <double>[
          for (final p in pages) p.width / p.height,
        ];
      });
    } catch (error) {
      // If openFile succeeded but a later step threw (e.g. doc.pages on a
      // malformed file), the local doc still owns an open PDFium handle.
      await doc?.dispose();
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _ensureRendered(int index) async {
    final doc = _doc;
    if (_disposed || doc == null) return;
    if (_images.containsKey(index)) {
      _touch(index);
      return;
    }
    if (_rendering.contains(index)) return;
    _rendering.add(index);
    try {
      final page = doc.pages[index];
      final pdfImage = await page.render(
        fullWidth: _targetWidth,
        fullHeight: _targetWidth * page.height / page.width,
      );
      if (pdfImage == null) {
        if (!_disposed && mounted) setState(() => _failed.add(index));
        return;
      }
      ui.Image image;
      try {
        image = await pdfImage.createImage();
      } finally {
        pdfImage.dispose();
      }
      if (_disposed) {
        image.dispose();
        return;
      }
      _images[index] = image;
      _heldBytes += image.width * image.height * 4;
      _touch(index);
      _evictIfNeeded(keep: index);
      if (mounted) setState(() {});
    } catch (_) {
      if (!_disposed && mounted) setState(() => _failed.add(index));
    } finally {
      _rendering.remove(index);
    }
  }

  void _touch(int index) {
    _lru
      ..remove(index)
      ..insert(0, index);
  }

  void _evictIfNeeded({required int keep}) {
    while (_heldBytes > _maxBitmapBytes && _lru.length > 1) {
      final victim = _lru.lastWhere((i) => i != keep, orElse: () => -1);
      if (victim < 0) break;
      _lru.remove(victim);
      final img = _images.remove(victim);
      if (img != null) {
        _heldBytes -= img.width * img.height * 4;
        img.dispose();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    unawaited(_disposeDocWhenIdle());
    super.dispose();
  }

  /// Dispose the document only once no `render()` is in flight, so PDFium is
  /// never freed out from under an outstanding render call.
  Future<void> _disposeDocWhenIdle() async {
    var guard = 0;
    while (_rendering.isNotEmpty && guard < 600) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      guard++;
    }
    await _doc?.dispose();
    _doc = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerHighest,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            onPressed: () => unawaited(_sharePdf(widget.path, widget.title)),
            icon: const Icon(Icons.share),
            tooltip: 'Share',
          ),
        ],
      ),
      body: _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: scheme.error, size: 40),
            const SizedBox(height: 8),
            const Text('Could not load the document.'),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                setState(() => _error = null);
                unawaited(_open());
              },
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    if (_pageCount == 0) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _pageCount,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final image = _images[index];
        if (image != null) {
          // Mark this visible (already-rendered) page most-recently-used so it
          // is not evicted while on screen — but AFTER the frame. Mutating _lru
          // directly here would make build() impure (Flutter contract) and run
          // O(n) list ops for every visible item on every repaint.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_disposed && _images.containsKey(index)) _touch(index);
          });
          return Semantics(
            image: true,
            label: 'Page ${index + 1} of $_pageCount',
            child: AspectRatio(
              aspectRatio: _aspects[index],
              child: RawImage(image: image, fit: BoxFit.fill),
            ),
          );
        }
        // Not yet rasterized: kick off a render for this (visible) page and show
        // a neutral loading box — never a white flash.
        if (!_failed.contains(index)) {
          unawaited(_ensureRendered(index));
        }
        return AspectRatio(
          aspectRatio: _aspects[index],
          child: ColoredBox(
            color: scheme.surface,
            child: Center(
              child: _failed.contains(index)
                  ? Icon(Icons.broken_image_outlined, color: scheme.error)
                  : const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
            ),
          ),
        );
      },
    );
  }
}
