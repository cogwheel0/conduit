import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/io_client.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/models/server_config.dart';
import '../../../../core/network/image_header_utils.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/services/server_tls_http_client_factory.dart';
import '../../../theme/theme_extensions.dart';

const Duration _pdfCacheStalePeriod = Duration(days: 7);
const Duration _pdfCacheNamespaceSweepInterval = Duration(minutes: 15);
const String _pdfCacheKeyPrefix = 'conduit_pdf_cache_';
const int _pdfCacheMaxObjects = 30;
const int _pdfCacheMaxContexts = 6;

final LinkedHashMap<String, _PdfCacheManagerEntry> _pdfCacheManagers =
    LinkedHashMap<String, _PdfCacheManagerEntry>();
final Map<String, int> _pdfCacheNamespaceRetainCounts = <String, int>{};
final Map<String, Future<void>> _pdfCacheManagerDisposals =
    <String, Future<void>>{};

DateTime? _lastPdfCacheNamespaceSweep;
bool _pdfCacheNamespaceSweepInFlight = false;

Config _pdfCacheConfig(String cacheKey, {FileService? fileService}) {
  if (fileService == null) {
    return Config(
      cacheKey,
      stalePeriod: _pdfCacheStalePeriod,
      maxNrOfCacheObjects: _pdfCacheMaxObjects,
    );
  }
  return Config(
    cacheKey,
    stalePeriod: _pdfCacheStalePeriod,
    maxNrOfCacheObjects: _pdfCacheMaxObjects,
    fileService: fileService,
  );
}

Future<_PdfCacheManagerLease> _leasePdfCacheManagerForContext({
  required ServerConfig? server,
  required Map<String, String>? headers,
}) async {
  final cacheKey = _pdfCacheKey(server: server, headers: headers);
  final pendingDisposal = _pdfCacheManagerDisposals[cacheKey];
  if (pendingDisposal != null) {
    await pendingDisposal;
  }

  final entry =
      _pdfCacheManagers.remove(cacheKey) ??
      _PdfCacheManagerEntry(
        cacheKey,
        _buildPdfCacheManager(cacheKey, server: server),
      );

  entry.activeUseCount += 1;
  _pdfCacheManagers[cacheKey] = entry;
  _trimPdfCacheManagers();
  _schedulePdfCacheNamespaceSweep();
  return _PdfCacheManagerLease(entry);
}

void _trimPdfCacheManagers() {
  while (_pdfCacheManagers.length > _pdfCacheMaxContexts) {
    String? evictionKey;
    _PdfCacheManagerEntry? evictionEntry;
    for (final entry in _pdfCacheManagers.entries) {
      if (entry.value.activeUseCount == 0 &&
          !_isPdfCacheNamespaceRetained(entry.key)) {
        evictionKey = entry.key;
        evictionEntry = entry.value;
        break;
      }
    }
    if (evictionKey == null || evictionEntry == null) {
      return;
    }

    _pdfCacheManagers.remove(evictionKey);
    unawaited(_disposePdfCacheManager(evictionEntry, clearFiles: true));
  }
}

Future<void> _disposePdfCacheManager(
  _PdfCacheManagerEntry entry, {
  required bool clearFiles,
}) {
  final pendingDisposal = _pdfCacheManagerDisposals[entry.cacheKey];
  if (pendingDisposal != null) {
    return pendingDisposal;
  }

  late final Future<void> cleanup;
  cleanup = entry
      .dispose(clearFiles: clearFiles)
      .catchError((_) {})
      .whenComplete(() {
        if (identical(_pdfCacheManagerDisposals[entry.cacheKey], cleanup)) {
          _pdfCacheManagerDisposals.remove(entry.cacheKey);
        }
        _schedulePdfCacheNamespaceSweep();
      });
  _pdfCacheManagerDisposals[entry.cacheKey] = cleanup;
  unawaited(cleanup);
  return cleanup;
}

_PdfCacheNamespaceLease _retainPdfCacheNamespace(String cacheKey) {
  _pdfCacheNamespaceRetainCounts[cacheKey] =
      (_pdfCacheNamespaceRetainCounts[cacheKey] ?? 0) + 1;
  return _PdfCacheNamespaceLease(cacheKey);
}

bool _isPdfCacheNamespaceRetained(String cacheKey) {
  return (_pdfCacheNamespaceRetainCounts[cacheKey] ?? 0) > 0;
}

void _releasePdfCacheNamespace(String cacheKey) {
  final count = _pdfCacheNamespaceRetainCounts[cacheKey] ?? 0;
  if (count <= 1) {
    _pdfCacheNamespaceRetainCounts.remove(cacheKey);
  } else {
    _pdfCacheNamespaceRetainCounts[cacheKey] = count - 1;
  }
  _trimPdfCacheManagers();
  _schedulePdfCacheNamespaceSweep();
}

void _schedulePdfCacheNamespaceSweep() {
  if (_pdfCacheNamespaceSweepInFlight) {
    return;
  }

  final now = DateTime.now();
  final lastSweep = _lastPdfCacheNamespaceSweep;
  if (lastSweep != null &&
      now.difference(lastSweep) < _pdfCacheNamespaceSweepInterval) {
    return;
  }

  _pdfCacheNamespaceSweepInFlight = true;
  unawaited(
    _sweepPdfCacheNamespaces().whenComplete(() {
      _lastPdfCacheNamespaceSweep = DateTime.now();
      _pdfCacheNamespaceSweepInFlight = false;
    }),
  );
}

Future<void> _sweepPdfCacheNamespaces() async {
  try {
    final tempDir = await getTemporaryDirectory();
    final candidatesByKey = <String, DateTime>{};
    final protectedCount = _protectedPdfCacheKeys().length;
    final retainedCandidateCount = (_pdfCacheMaxContexts - protectedCount)
        .clamp(0, _pdfCacheMaxContexts);

    await for (final entity in tempDir.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }

      final cacheKey = path.basename(entity.path);
      if (!_isPdfCacheKey(cacheKey) || _isPdfCacheNamespaceInUse(cacheKey)) {
        continue;
      }

      final stat = await entity.stat();
      _addPdfCacheNamespaceCandidate(candidatesByKey, cacheKey, stat.modified);
    }

    await _collectPdfCacheMetadataCandidates(candidatesByKey);

    final candidates = <_PdfCacheNamespaceDirectory>[
      for (final entry in candidatesByKey.entries)
        _PdfCacheNamespaceDirectory(entry.key, entry.value),
    ];

    if (candidates.length <= retainedCandidateCount) {
      return;
    }

    candidates.sort((a, b) => b.modified.compareTo(a.modified));
    for (final candidate in candidates.skip(retainedCandidateCount)) {
      if (_isPdfCacheNamespaceInUse(candidate.cacheKey)) {
        continue;
      }

      await _disposePdfCacheManager(
        _PdfCacheManagerEntry(
          candidate.cacheKey,
          _buildPdfCacheManager(candidate.cacheKey, server: null),
        ),
        clearFiles: true,
      );
    }
  } catch (_) {
    // Best effort cleanup only.
  }
}

void _addPdfCacheNamespaceCandidate(
  Map<String, DateTime> candidatesByKey,
  String cacheKey,
  DateTime modified,
) {
  if (!_isPdfCacheKey(cacheKey) || _isPdfCacheNamespaceInUse(cacheKey)) {
    return;
  }

  final previous = candidatesByKey[cacheKey];
  if (previous == null || modified.isAfter(previous)) {
    candidatesByKey[cacheKey] = modified;
  }
}

Future<void> _collectPdfCacheMetadataCandidates(
  Map<String, DateTime> candidatesByKey,
) async {
  try {
    final supportDir = await getApplicationSupportDirectory();
    await for (final entity in supportDir.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }

      final basename = path.basename(entity.path);
      final extension = path.extension(basename);
      if (extension != '.db' && extension != '.json') {
        continue;
      }

      final cacheKey = path.basenameWithoutExtension(basename);
      final stat = await entity.stat();
      _addPdfCacheNamespaceCandidate(candidatesByKey, cacheKey, stat.modified);
    }
  } catch (_) {
    // Best effort cleanup only.
  }
}

Set<String> _protectedPdfCacheKeys() {
  return <String>{
    ..._pdfCacheManagers.keys,
    ..._pdfCacheNamespaceRetainCounts.keys,
    ..._pdfCacheManagerDisposals.keys,
  };
}

bool _isPdfCacheNamespaceInUse(
  String cacheKey, {
  bool includePendingDisposal = true,
}) {
  return _pdfCacheManagers.containsKey(cacheKey) ||
      _isPdfCacheNamespaceRetained(cacheKey) ||
      (includePendingDisposal &&
          _pdfCacheManagerDisposals.containsKey(cacheKey));
}

bool _isPdfCacheKey(String cacheKey) {
  if (!cacheKey.startsWith(_pdfCacheKeyPrefix)) {
    return false;
  }
  final fingerprint = cacheKey.substring(_pdfCacheKeyPrefix.length);
  return fingerprint.length == 64 &&
      RegExp(r'^[0-9a-f]+$').hasMatch(fingerprint);
}

Future<void> _deletePdfCacheDirectoryIfUnprotected(String cacheKey) async {
  if (!_isPdfCacheKey(cacheKey)) {
    return;
  }
  if (_isPdfCacheNamespaceInUse(cacheKey, includePendingDisposal: false)) {
    return;
  }

  final tempDir = await getTemporaryDirectory();
  if (_isPdfCacheNamespaceInUse(cacheKey, includePendingDisposal: false)) {
    return;
  }

  await _deleteDirectoryIfPresent(Directory(path.join(tempDir.path, cacheKey)));
}

Future<void> _deleteDirectoryIfPresent(Directory directory) async {
  try {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  } catch (_) {
    // Best effort cleanup only.
  }
}

class _PdfCacheManagerEntry {
  _PdfCacheManagerEntry(this.cacheKey, this._resources);

  final String cacheKey;
  final _PdfCacheManagerResources _resources;
  int activeUseCount = 0;

  BaseCacheManager get manager => _resources.manager;

  Future<void> dispose({required bool clearFiles}) {
    return _resources.dispose(clearFiles: clearFiles);
  }
}

class _PdfCacheNamespaceDirectory {
  const _PdfCacheNamespaceDirectory(this.cacheKey, this.modified);

  final String cacheKey;
  final DateTime modified;
}

class _PdfCacheManagerLease {
  _PdfCacheManagerLease(this._entry);

  final _PdfCacheManagerEntry _entry;
  bool _released = false;

  String get cacheKey => _entry.cacheKey;
  BaseCacheManager get manager => _entry.manager;

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    if (_entry.activeUseCount > 0) {
      _entry.activeUseCount -= 1;
    }
    _trimPdfCacheManagers();
  }
}

class _PdfCacheNamespaceLease {
  _PdfCacheNamespaceLease(this.cacheKey);

  final String cacheKey;
  bool _released = false;

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _releasePdfCacheNamespace(cacheKey);
  }
}

_PdfCacheManagerResources _buildPdfCacheManager(
  String cacheKey, {
  required ServerConfig? server,
}) {
  final httpClient =
      server != null &&
          ServerTlsHttpClientFactory.requiresCustomHttpClient(server)
      ? ServerTlsHttpClientFactory.createHttpClient(server)
      : HttpClient();
  final fileService = _PdfHttpFileService(IOClient(httpClient));
  return _PdfCacheManagerResources(
    cacheKey,
    CacheManager(_pdfCacheConfig(cacheKey, fileService: fileService)),
    fileService,
  );
}

class _PdfCacheManagerResources {
  const _PdfCacheManagerResources(
    this.cacheKey,
    this.manager,
    this.fileService,
  );

  final String cacheKey;
  final BaseCacheManager manager;
  final _PdfHttpFileService? fileService;

  Future<void> dispose({required bool clearFiles}) async {
    try {
      try {
        if (clearFiles) {
          await manager.emptyCache();
        }
      } finally {
        await manager.dispose();
      }
    } finally {
      fileService?.close();
      if (clearFiles) {
        await _deletePdfCacheDirectoryIfUnprotected(cacheKey);
      }
    }
  }
}

class _PdfHttpFileService extends HttpFileService {
  _PdfHttpFileService(this._client) : super(httpClient: _client);

  final IOClient _client;

  void close() => _client.close();
}

String _pdfCacheKey({
  required ServerConfig? server,
  required Map<String, String>? headers,
}) {
  final fingerprint = sha256.convert(
    utf8.encode(
      jsonEncode(<Object?>[
        server?.id ?? '',
        server?.url ?? '',
        _canonicalHeaders(headers),
        server?.allowSelfSignedCertificates ?? false,
        sha256
            .convert(utf8.encode(server?.mtlsCertificateChainPem ?? ''))
            .toString(),
        sha256.convert(utf8.encode(server?.mtlsPrivateKeyPem ?? '')).toString(),
        sha256
            .convert(utf8.encode((server?.mtlsPrivateKeyPassword ?? '').trim()))
            .toString(),
      ]),
    ),
  );
  return '$_pdfCacheKeyPrefix$fingerprint';
}

List<List<String>> _canonicalHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) {
    return const <List<String>>[];
  }
  final entries =
      headers.entries
          .map((entry) => <String>[entry.key.toLowerCase(), entry.value])
          .toList()
        ..sort((a, b) {
          final keyCompare = a.first.compareTo(b.first);
          if (keyCompare != 0) return keyCompare;
          return a.last.compareTo(b.last);
        });
  return entries;
}

/// Inline PDF preview rendered for markdown links whose path ends in `.pdf`.
class PdfInlineView extends ConsumerStatefulWidget {
  const PdfInlineView({super.key, required this.url, this.label});

  final String url;
  final String? label;

  static bool isPdfLink(String href) {
    final trimmed = href.trim();
    if (trimmed.isEmpty) return false;

    final uri = Uri.tryParse(trimmed);
    final rawPath = uri?.path.isNotEmpty == true
        ? uri!.path
        : trimmed.split('?').first.split('#').first;
    return _decodeUriComponent(rawPath).toLowerCase().endsWith('.pdf');
  }

  @override
  ConsumerState<PdfInlineView> createState() => _PdfInlineViewState();
}

class _PdfInlineViewState extends ConsumerState<PdfInlineView> {
  static const double _previewRenderWidth = 720;
  static const double _previewHeight = 320;

  int _loadGeneration = 0;
  String? _filePath;
  _PdfCacheNamespaceLease? _cacheNamespaceLease;
  ui.Image? _previewImage;
  bool _documentReady = false;
  bool _previewSettled = false;
  Object? _loadError;
  bool _started = false;
  bool _disposed = false;

  bool get _canOpen => _filePath != null && _documentReady;
  bool get _canShare => _filePath != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _startLoad(refresh: false, notify: false);
  }

  @override
  void didUpdateWidget(covariant PdfInlineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _startLoad(refresh: false);
    }
  }

  void _startLoad({required bool refresh, bool notify = true}) {
    final generation = ++_loadGeneration;
    _resetLoadState();
    if (notify && mounted) {
      setState(() {});
    }
    unawaited(_load(generation, refresh: refresh));
  }

  void _resetLoadState() {
    _previewImage?.dispose();
    _previewImage = null;
    _filePath = null;
    _cacheNamespaceLease?.release();
    _cacheNamespaceLease = null;
    _documentReady = false;
    _previewSettled = false;
    _loadError = null;
  }

  Future<void> _load(int generation, {required bool refresh}) async {
    final loadingUrl = widget.url;
    File? cachedFile;
    _PdfCacheManagerLease? cacheLease;
    try {
      final container = ProviderScope.containerOf(context, listen: false);
      final headers = buildImageHeadersFromContainer(container);
      final api = container.read(apiServiceProvider);
      final requestUrl = _resolvePdfRequestUrl(loadingUrl, api?.baseUrl);
      cacheLease = await _leasePdfCacheManagerForContext(
        server: api?.serverConfig,
        headers: headers,
      );
      if (!_isCurrentLoad(generation, loadingUrl)) return;
      final cacheManager = cacheLease.manager;

      await pdfrxFlutterInitialize();
      if (refresh) {
        await cacheManager.removeFile(requestUrl);
      }
      cachedFile = await cacheManager.getSingleFile(
        requestUrl,
        headers: headers ?? const <String, String>{},
      );
      if (!_isCurrentLoad(generation, loadingUrl)) return;

      PdfDocument? doc;
      try {
        doc = await PdfDocument.openFile(cachedFile.path);
        final pages = doc.pages;
        if (!_isCurrentLoad(generation, loadingUrl)) return;

        _replaceCacheNamespaceLease(cacheLease.cacheKey);
        setState(() {
          _filePath = cachedFile!.path;
          _documentReady = true;
          _loadError = null;
        });

        if (pages.isEmpty) {
          if (_isCurrentLoad(generation, loadingUrl)) {
            setState(() => _previewSettled = true);
          }
          return;
        }

        ui.Image? image;
        try {
          image = await _renderPreviewPage(pages.first);
        } catch (_) {
          image = null;
        }

        if (!_isCurrentLoad(generation, loadingUrl)) {
          image?.dispose();
          return;
        }
        setState(() {
          _previewImage = image;
          _previewSettled = true;
        });
      } finally {
        await doc?.dispose();
      }
    } catch (error) {
      if (!_isCurrentLoad(generation, loadingUrl)) return;
      if (cachedFile != null && cacheLease != null) {
        _replaceCacheNamespaceLease(cacheLease.cacheKey);
      }
      setState(() {
        _filePath = cachedFile?.path;
        _documentReady = false;
        _previewSettled = true;
        _loadError = error;
      });
    } finally {
      cacheLease?.release();
    }
  }

  void _replaceCacheNamespaceLease(String cacheKey) {
    if (_cacheNamespaceLease?.cacheKey == cacheKey) {
      return;
    }
    _cacheNamespaceLease?.release();
    _cacheNamespaceLease = _retainPdfCacheNamespace(cacheKey);
  }

  Future<ui.Image?> _renderPreviewPage(PdfPage page) async {
    final pdfImage = await page.render(
      fullWidth: _previewRenderWidth,
      fullHeight: _heightForWidth(
        pageWidth: page.width,
        pageHeight: page.height,
        width: _previewRenderWidth,
      ),
    );
    if (pdfImage == null) return null;
    try {
      return await pdfImage.createImage();
    } finally {
      pdfImage.dispose();
    }
  }

  bool _isCurrentLoad(int generation, String loadingUrl) {
    return !_disposed &&
        mounted &&
        generation == _loadGeneration &&
        widget.url == loadingUrl;
  }

  @override
  void dispose() {
    _disposed = true;
    _previewImage?.dispose();
    _cacheNamespaceLease?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = _pdfTitle(
      rawLabel: widget.label,
      url: widget.url,
      fallback: l10n?.document ?? 'PDF document',
    );
    final scheme = Theme.of(context).colorScheme;
    final conduitTheme = context.conduitTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Material(
          color: conduitTheme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            button: true,
            label: _semanticsLabel(title),
            child: InkWell(
              onTap: _canOpen
                  ? () => _openFullscreen(context, _filePath!, title)
                  : (_loadError != null
                        ? () => _startLoad(refresh: true)
                        : null),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    height: _previewHeight,
                    child: ColoredBox(
                      color: conduitTheme.surfaceBackground,
                      child: _buildPreview(scheme, conduitTheme, title),
                    ),
                  ),
                  _buildBar(context, title, scheme, conduitTheme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(
    ColorScheme scheme,
    ConduitThemeExtension conduitTheme,
    String title,
  ) {
    final image = _previewImage;
    final Widget content;
    if (_loadError != null && !_canOpen) {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.broken_image_outlined, color: scheme.error),
            const SizedBox(height: Spacing.xs),
            Text(
              AppLocalizations.of(context)?.retry ?? 'Retry',
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
    } else if (_previewSettled && _canOpen) {
      content = Center(
        child: Icon(
          Icons.picture_as_pdf,
          size: 48,
          color: conduitTheme.iconSecondary,
        ),
      );
    } else {
      content = Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: conduitTheme.loadingIndicator,
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        content,
        if (_canOpen)
          Positioned(
            right: Spacing.sm,
            bottom: Spacing.sm,
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

  Widget _buildBar(
    BuildContext context,
    String title,
    ColorScheme scheme,
    ConduitThemeExtension conduitTheme,
  ) {
    final l10n = AppLocalizations.of(context);
    final status = _canOpen
        ? 'Open'
        : (_loadError != null
              ? (l10n?.retry ?? 'Retry')
              : '${l10n?.loadingShort ?? 'Loading'}...');

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.picture_as_pdf, size: 18, color: scheme.primary),
          const SizedBox(width: Spacing.sm),
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
          const SizedBox(width: Spacing.sm),
          if (_canShare)
            IconButton(
              onPressed: () => unawaited(_sharePdf(_filePath!, title)),
              icon: Icon(Icons.share, size: 19, color: scheme.primary),
              tooltip: 'Share',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            ),
          Text(
            status,
            style: TextStyle(color: conduitTheme.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _openFullscreen(BuildContext context, String filePath, String title) {
    final cacheKey = _cacheNamespaceLease?.cacheKey;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _PdfFullscreenPage(
          path: filePath,
          title: title,
          cacheKey: cacheKey,
        ),
      ),
    );
  }

  String _semanticsLabel(String title) {
    if (_canOpen) return 'Open PDF: $title';
    if (_loadError != null) return 'PDF failed to load: $title';
    return 'PDF loading: $title';
  }
}

class _PdfFullscreenPage extends StatefulWidget {
  const _PdfFullscreenPage({
    required this.path,
    required this.title,
    required this.cacheKey,
  });

  final String path;
  final String title;
  final String? cacheKey;

  @override
  State<_PdfFullscreenPage> createState() => _PdfFullscreenPageState();
}

class _PdfFullscreenPageState extends State<_PdfFullscreenPage> {
  static const int _maxBitmapBytes = 64 * 1024 * 1024;

  PdfDocument? _doc;
  bool _disposed = false;
  bool _started = false;
  bool _opened = false;
  Object? _error;
  int _pageCount = 0;
  List<double> _aspects = const <double>[];
  double _targetWidth = 1080;

  final Map<int, ui.Image> _images = <int, ui.Image>{};
  final List<int> _lru = <int>[];
  final Map<int, PdfPageRenderCancellationToken> _rendering =
      <int, PdfPageRenderCancellationToken>{};
  final Set<int> _failed = <int>{};
  int _heldBytes = 0;
  _PdfCacheNamespaceLease? _cacheNamespaceLease;

  @override
  void initState() {
    super.initState();
    final cacheKey = widget.cacheKey;
    if (cacheKey != null) {
      _cacheNamespaceLease = _retainPdfCacheNamespace(cacheKey);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final media = MediaQuery.of(context);
    _targetWidth = (media.size.width * media.devicePixelRatio).clamp(
      800.0,
      1080.0,
    );
    unawaited(_open());
  }

  Future<void> _open() async {
    PdfDocument? doc;
    try {
      await pdfrxFlutterInitialize();
      doc = await PdfDocument.openFile(widget.path);
      if (_disposed) {
        await doc.dispose();
        return;
      }

      final pages = doc.pages;
      await _doc?.dispose();
      _doc = doc;
      doc = null;

      setState(() {
        _opened = true;
        _error = null;
        _pageCount = pages.length;
        _aspects = <double>[for (final page in pages) _pageAspect(page)];
      });
    } catch (error) {
      await doc?.dispose();
      if (!mounted) return;
      setState(() {
        _opened = true;
        _error = error;
      });
    }
  }

  Future<void> _ensureRendered(int index) async {
    final doc = _doc;
    if (_disposed || doc == null || index < 0 || index >= _pageCount) {
      return;
    }
    if (_images.containsKey(index)) {
      _touch(index);
      return;
    }
    if (_rendering.containsKey(index)) return;

    PdfPageRenderCancellationToken? token;
    try {
      final page = doc.pages[index];
      token = page.createCancellationToken();
      _rendering[index] = token;
      final pdfImage = await page.render(
        fullWidth: _targetWidth,
        fullHeight: _heightForWidth(
          pageWidth: page.width,
          pageHeight: page.height,
          width: _targetWidth,
        ),
        cancellationToken: token,
      );
      if (pdfImage == null) {
        if (!_disposed && mounted && !token.isCanceled) {
          setState(() => _failed.add(index));
        }
        return;
      }

      ui.Image image;
      try {
        image = await pdfImage.createImage();
      } finally {
        pdfImage.dispose();
      }

      if (_disposed || token.isCanceled) {
        image.dispose();
        return;
      }

      _images[index] = image;
      _heldBytes += image.width * image.height * 4;
      _touch(index);
      _evictIfNeeded(keep: index);
      if (mounted) setState(() {});
    } catch (_) {
      if (!_disposed && mounted) {
        setState(() => _failed.add(index));
      }
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
      final victim = _lru.lastWhere((index) => index != keep, orElse: () => -1);
      if (victim < 0) break;
      _lru.remove(victim);
      final image = _images.remove(victim);
      if (image == null) continue;
      _heldBytes -= image.width * image.height * 4;
      image.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final token in _rendering.values) {
      token.cancel();
    }
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _lru.clear();
    _heldBytes = 0;
    final cacheNamespaceLease = _cacheNamespaceLease;
    _cacheNamespaceLease = null;
    unawaited(
      _disposeDocWhenIdle().whenComplete(() => cacheNamespaceLease?.release()),
    );
    super.dispose();
  }

  Future<void> _disposeDocWhenIdle() async {
    var guard = 0;
    while (_rendering.isNotEmpty && guard < 600) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      guard += 1;
    }
    await _doc?.dispose();
    _doc = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final conduitTheme = context.conduitTheme;
    return Scaffold(
      backgroundColor: conduitTheme.surfaceBackground,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            onPressed: () => unawaited(_sharePdf(widget.path, widget.title)),
            icon: const Icon(Icons.share),
            tooltip: 'Share',
          ),
        ],
      ),
      body: _buildBody(scheme, conduitTheme),
    );
  }

  Widget _buildBody(ColorScheme scheme, ConduitThemeExtension conduitTheme) {
    final l10n = AppLocalizations.of(context);
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, color: scheme.error, size: 40),
            const SizedBox(height: Spacing.sm),
            Text(l10n?.failedToLoadFiles ?? 'Could not load the document.'),
            const SizedBox(height: Spacing.md),
            TextButton(
              onPressed: () {
                setState(() {
                  _error = null;
                  _opened = false;
                });
                unawaited(_open());
              },
              child: Text(l10n?.retry ?? 'Try again'),
            ),
          ],
        ),
      );
    }
    if (!_opened) {
      return Center(
        child: CircularProgressIndicator(color: conduitTheme.loadingIndicator),
      );
    }
    if (_pageCount == 0) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.picture_as_pdf,
              color: conduitTheme.iconSecondary,
              size: 40,
            ),
            const SizedBox(height: Spacing.sm),
            const Text('No pages to display.'),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      scrollCacheExtent: const ScrollCacheExtent.pixels(900),
      itemCount: _pageCount,
      separatorBuilder: (_, _) => const SizedBox(height: Spacing.sm),
      itemBuilder: (context, index) {
        final image = _images[index];
        final aspect = index < _aspects.length ? _aspects[index] : 0.707;
        if (image != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_disposed && _images.containsKey(index)) _touch(index);
          });
          return Semantics(
            image: true,
            label: 'Page ${index + 1} of $_pageCount',
            child: AspectRatio(
              aspectRatio: aspect,
              child: RawImage(image: image, fit: BoxFit.fill),
            ),
          );
        }

        if (!_failed.contains(index)) {
          unawaited(_ensureRendered(index));
        }
        return AspectRatio(
          aspectRatio: aspect,
          child: ColoredBox(
            color: conduitTheme.surfaceContainer,
            child: Center(
              child: _failed.contains(index)
                  ? Icon(Icons.broken_image_outlined, color: scheme.error)
                  : SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: conduitTheme.loadingIndicator,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> _sharePdf(String filePath, String title) async {
  final name = _pdfFileName(title);
  try {
    final base = await getTemporaryDirectory();
    final root = Directory(path.join(base.path, 'pdf-share'));
    await _sweepOldShareTemps(root);
    final shareDir = Directory(
      path.join(root.path, DateTime.now().microsecondsSinceEpoch.toString()),
    );
    await shareDir.create(recursive: true);
    final dest = File(path.join(shareDir.path, name));
    await File(filePath).copy(dest.path);
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[
          XFile(dest.path, mimeType: 'application/pdf', name: name),
        ],
      ),
    );
  } catch (_) {
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[
          XFile(filePath, mimeType: 'application/pdf', name: name),
        ],
        fileNameOverrides: <String>[name],
      ),
    );
  }
}

Future<void> _sweepOldShareTemps(Directory root) async {
  try {
    if (!await root.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entry in root.list()) {
      try {
        if ((await entry.stat()).modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      } catch (_) {
        // Best effort cleanup only.
      }
    }
  } catch (_) {
    // Best effort cleanup only.
  }
}

String _pdfFileName(String title) {
  var base = title
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s._\-]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (base.length > 80) base = base.substring(0, 80).trim();
  if (base.isEmpty) base = 'document';
  return base.toLowerCase().endsWith('.pdf') ? base : '$base.pdf';
}

String _pdfTitle({
  required String? rawLabel,
  required String url,
  required String fallback,
}) {
  final label = (rawLabel ?? '')
      .replaceFirst(RegExp(r'^\s*\u{1F4C4}\s*', unicode: true), '')
      .trim();
  if (label.isNotEmpty && label != url.trim()) {
    return label;
  }

  final fileName = _fileNameFromUrl(url);
  if (fileName != null && fileName.isNotEmpty) {
    return fileName;
  }
  return fallback;
}

String? _fileNameFromUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  final rawPath = uri?.path.isNotEmpty == true
      ? uri!.path
      : trimmed.split('?').first.split('#').first;
  final segments = rawPath.split('/').where((part) => part.isNotEmpty);
  if (segments.isEmpty) return null;
  return _decodeUriComponent(segments.last).trim();
}

String _resolvePdfRequestUrl(String url, String? baseUrl) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return url;

  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.hasScheme) {
    return trimmed;
  }

  var baseUri = baseUrl == null
      ? null
      : ServerTlsHttpClientFactory.parseBaseUri(baseUrl);
  if (baseUri == null) {
    return trimmed;
  }

  if (trimmed.startsWith('/')) {
    return '${_baseUrlWithoutTrailingSlash(baseUri)}$trimmed';
  }

  if (!baseUri.path.endsWith('/')) {
    baseUri = baseUri.replace(path: '${baseUri.path}/');
  }

  return baseUri.resolveUri(uri).toString();
}

String _baseUrlWithoutTrailingSlash(Uri uri) {
  final withoutFragment = uri.removeFragment();
  final withoutQuery = withoutFragment.replace(query: null);
  return withoutQuery.toString().replaceFirst(RegExp(r'/+$'), '');
}

String _decodeUriComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}

double _heightForWidth({
  required double pageWidth,
  required double pageHeight,
  required double width,
}) {
  if (pageWidth <= 0 || pageHeight <= 0) {
    return width * 1.414;
  }
  return width * pageHeight / pageWidth;
}

double _pageAspect(PdfPage page) {
  if (page.width <= 0 || page.height <= 0) {
    return 0.707;
  }
  return page.width / page.height;
}
