import 'dart:async';
import 'dart:io' show HttpClient, HttpHeaders, Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/services/native_sheet_bridge.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/utils/adaptive_glass.dart';
import '../../../../shared/utils/external_link_launcher.dart';
import '../../../../shared/widgets/markdown/source_reference_helper.dart';
import '../../../../shared/widgets/sheet_handle.dart';
import '../../../../shared/widgets/themed_sheets.dart';

typedef SourceFaviconDomainResolver = Future<String> Function(String url);

const _googleGroundingRedirectHost = 'vertexaisearch.cloud.google.com';
const _googleGroundingRedirectPath = '/grounding-api-redirect';

bool _isGoogleGroundingRedirect(Uri? uri) =>
    uri != null &&
    uri.scheme.toLowerCase() == 'https' &&
    uri.host.toLowerCase() == _googleGroundingRedirectHost &&
    (uri.path == _googleGroundingRedirectPath ||
        uri.path.startsWith('$_googleGroundingRedirectPath/'));

/// Resolves the display domain hidden behind Gemini grounding redirect URLs.
///
/// OpenRouter intentionally returns an opaque Google redirect for Gemini web
/// citations. Resolving only this exact HTTPS endpoint keeps ordinary source
/// rendering free of extra network requests and never forwards app headers or
/// credentials to the cited site.
Future<String> resolveSourceFaviconDomain(
  String sourceUrl, {
  Future<Uri?> Function(Uri source)? redirectResolver,
}) async {
  final source = Uri.tryParse(sourceUrl);
  final fallback = SourceReferenceHelper.extractDomain(sourceUrl).trim();
  if (!_isGoogleGroundingRedirect(source)) {
    return fallback;
  }

  try {
    final destination = await (redirectResolver ?? _resolveGroundingRedirect)(
      source!,
    ).timeout(const Duration(seconds: 3));
    if (destination == null ||
        destination.scheme.toLowerCase() != 'https' ||
        destination.userInfo.isNotEmpty ||
        destination.host.trim().isEmpty) {
      return fallback;
    }
    var domain = destination.host.trim().toLowerCase();
    if (domain.startsWith('www.')) {
      domain = domain.substring(4);
    }
    return domain;
  } catch (_) {
    return fallback;
  }
}

Future<Uri?> _resolveGroundingRedirect(Uri source) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(source);
    request
      ..followRedirects = false
      ..maxRedirects = 0;
    final response = await request.close().timeout(const Duration(seconds: 3));
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (response.statusCode < 300 ||
        response.statusCode >= 400 ||
        location == null ||
        location.trim().isEmpty) {
      return null;
    }
    return source.resolve(location.trim());
  } finally {
    client.close(force: true);
  }
}

/// OpenWebUI-style sources component with a compact chip and details sheet.
class OpenWebUISourcesWidget extends StatelessWidget {
  const OpenWebUISourcesWidget({
    super.key,
    required this.sources,
    this.messageId,
    this.faviconImageProvider,
    this.faviconDomainResolver,
  });

  final List<ChatSourceReference> sources;
  final String? messageId;
  final ImageProvider<Object> Function(String url)? faviconImageProvider;
  final SourceFaviconDomainResolver? faviconDomainResolver;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = context.conduitTheme;
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    final urlSources = sources
        .where((source) {
          return SourceReferenceHelper.getSourceUrl(source) != null;
        })
        .toList(growable: false);
    final chipContent = _buildChipContent(context, urlSources);

    return LayoutBuilder(
      builder: (context, constraints) {
        final labelStyle = AppTypography.labelMediumStyle.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.textPrimary.withValues(alpha: 0.8),
        );
        final textPainter = TextPainter(
          text: TextSpan(
            text: _sourceCountLabel(sources.length),
            style: labelStyle,
          ),
          maxLines: 1,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        )..layout();
        final faviconWidth = urlSources.isNotEmpty
            ? (urlSources.length > 3 ? 52.0 : urlSources.length * 18.0) + 8.0
            : 0.0;
        final desiredWidth = faviconWidth + textPainter.width + 20.0;
        final targetWidth = constraints.maxWidth.isFinite
            ? desiredWidth.clamp(0.0, constraints.maxWidth).toDouble()
            : desiredWidth;

        return Semantics(
          button: true,
          label: _sourceCountLabel(sources.length),
          child: AdaptiveButton.child(
            onPressed: () => _showSourcesBottomSheet(context),
            style: usesOpaqueFallback
                ? AdaptiveButtonStyle.filled
                : AdaptiveButtonStyle.glass,
            color: usesOpaqueFallback
                ? theme.surfaceContainerHighest.withValues(alpha: 0.95)
                : null,
            size: AdaptiveButtonSize.small,
            padding: EdgeInsets.zero,
            minSize: Size(targetWidth, 28),
            useSmoothRectangleBorder: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: chipContent,
            ),
          ),
        );
      },
    );
  }

  Widget _buildChipContent(
    BuildContext context,
    List<ChatSourceReference> urlSources,
  ) {
    final theme = context.conduitTheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (urlSources.isNotEmpty) ...[
          SizedBox(
            width: urlSources.length > 3 ? 52 : urlSources.length * 18.0,
            height: 16,
            child: Stack(
              children: [
                for (
                  int i = 0;
                  i < (urlSources.length > 3 ? 3 : urlSources.length);
                  i++
                )
                  Positioned(
                    left: i * 12.0,
                    child: _SourceFavicon(
                      url: SourceReferenceHelper.getSourceUrl(urlSources[i])!,
                      size: 16,
                      imageProvider: faviconImageProvider,
                      domainResolver:
                          faviconDomainResolver ?? resolveSourceFaviconDomain,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ],
        Text(
          _sourceCountLabel(sources.length),
          style: AppTypography.labelMediumStyle.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.textPrimary.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  void _showSourcesBottomSheet(BuildContext context) async {
    if (Platform.isIOS) {
      try {
        final resolver = faviconDomainResolver ?? resolveSourceFaviconDomain;
        final faviconDomains = await Future.wait<String?>([
          for (final source in sources)
            if (SourceReferenceHelper.getSourceUrl(source) case final url?)
              resolver(url)
            else
              Future<String?>.value(),
        ]);
        if (!context.mounted) {
          return;
        }
        await NativeSheetBridge.instance.presentSheet(
          root: NativeSheetDetailConfig(
            id: 'chat-sources',
            title: _sourceCountLabel(sources.length),
            items: [
              for (var index = 0; index < sources.length; index++)
                _buildNativeSourceItem(
                  sources[index],
                  index,
                  faviconDomain: faviconDomains[index],
                ),
            ],
          ),
          rethrowErrors: true,
        );
        return;
      } catch (_) {
        if (!context.mounted) {
          return;
        }
      }
    }

    if (!context.mounted) {
      return;
    }

    ThemedSheets.showSurface<void>(
      context: context,
      isScrollControlled: true,
      showHandle: false,
      padding: EdgeInsets.zero,
      builder: (sheetContext) {
        final liveTheme = sheetContext.conduitTheme;

        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.35,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, controller) {
            return SafeArea(
              top: false,
              child: Column(
                children: [
                  const SheetHandle(
                    margin: EdgeInsets.only(
                      top: Spacing.sm,
                      bottom: Spacing.sm,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.lg,
                      0,
                      Spacing.md,
                      Spacing.sm,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.link_rounded,
                          size: IconSize.md,
                          color: liveTheme.textPrimary,
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Text(
                            _sourceCountLabel(sources.length),
                            style: AppTypography.bodyLargeStyle.copyWith(
                              fontWeight: FontWeight.w600,
                              color: liveTheme.textPrimary,
                            ),
                          ),
                        ),
                        SheetCloseButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          color: liveTheme.textSecondary,
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: liveTheme.dividerColor.withValues(alpha: 0.3),
                  ),
                  Expanded(
                    child: ListView.separated(
                      controller: controller,
                      padding: const EdgeInsets.all(Spacing.lg),
                      itemCount: sources.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: Spacing.sm),
                      itemBuilder: (itemContext, index) {
                        return _buildSourceItem(
                          itemContext,
                          sources[index],
                          index,
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSourceItem(
    BuildContext context,
    ChatSourceReference source,
    int index,
  ) {
    final theme = context.conduitTheme;
    final url = SourceReferenceHelper.getSourceUrl(source);
    final displayText = SourceReferenceHelper.getSourceLabel(source, index);
    final snippet = _sourceSnippet(source);
    final type = source.type?.trim();
    final hasType = type != null && type.isNotEmpty;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: url == null
          ? null
          : () => launchExternalLink(url, scope: 'chat/sources'),
      child: Container(
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: theme.surfaceContainer.withValues(alpha: 0.36),
          borderRadius: BorderRadius.circular(AppBorderRadius.card),
          border: Border.all(
            color: theme.dividerColor.withValues(alpha: 0.32),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SourceIndexBadge(index: index + 1),
                const SizedBox(width: Spacing.sm),
                if (url != null) ...[
                  _SourceFavicon(
                    url: url,
                    size: 18,
                    imageProvider: faviconImageProvider,
                    domainResolver:
                        faviconDomainResolver ?? resolveSourceFaviconDomain,
                  ),
                  const SizedBox(width: Spacing.sm),
                ] else ...[
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      color: theme.surfaceContainerHighest,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.description_outlined,
                      size: 11,
                      color: theme.textSecondary,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayText,
                        style: AppTypography.bodyMediumStyle.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.textPrimary,
                        ),
                      ),
                      if (url != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          url,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodySmallStyle.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                      ] else if (hasType) ...[
                        const SizedBox(height: 2),
                        Text(
                          type,
                          style: AppTypography.bodySmallStyle.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (url != null) ...[
                  const SizedBox(width: Spacing.sm),
                  Icon(
                    Icons.open_in_new_rounded,
                    size: IconSize.sm,
                    color: theme.textSecondary,
                  ),
                ],
              ],
            ),
            if (snippet != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                snippet,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodySmallStyle.copyWith(
                  height: 1.45,
                  color: theme.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  NativeSheetItemConfig _buildNativeSourceItem(
    ChatSourceReference source,
    int index, {
    String? faviconDomain,
  }) {
    final url = SourceReferenceHelper.getSourceUrl(source);
    final snippet = _sourceSnippet(source);
    final type = _sourceType(source);

    return NativeSheetItemConfig(
      id: 'source-$index',
      title: SourceReferenceHelper.getSourceLabel(source, index),
      subtitle: snippet,
      sfSymbol: url == null ? 'doc.text' : 'link',
      url: url,
      kind: NativeSheetItemKind.source,
      sourceIndex: index + 1,
      sourceUrl: url,
      sourceType: type,
      snippet: snippet,
      faviconUrl: _sourceFaviconUrl(url, domain: faviconDomain),
    );
  }

  String _sourceCountLabel(int count) {
    return count == 1 ? '1 Source' : '$count Sources';
  }

  String? _sourceType(ChatSourceReference source) {
    final type = source.type?.trim();
    return type == null || type.isEmpty ? null : type;
  }

  String? _sourceSnippet(ChatSourceReference source) {
    final candidates = <dynamic>[
      source.snippet,
      ..._metadataSnippetCandidates(source),
    ];

    for (final candidate in candidates) {
      final normalized = _normalizeSnippet(candidate);
      if (normalized != null) {
        return normalized;
      }
    }

    return null;
  }

  Iterable<dynamic> _metadataSnippetCandidates(
    ChatSourceReference source,
  ) sync* {
    final metadata = source.metadata;
    if (metadata == null) {
      return;
    }

    final documents = metadata['documents'];
    if (documents is List) {
      for (final document in documents) {
        yield document;
      }
    }

    final primaryMetadata = SourceReferenceHelper.primaryMetadata(source);
    final nestedSource = SourceReferenceHelper.nestedSourceMetadata(source);
    for (final entry in [primaryMetadata, nestedSource]) {
      if (entry == null) {
        continue;
      }
      yield entry['snippet'];
      yield entry['content'];
      yield entry['description'];
      yield entry['text'];
    }
  }

  String? _normalizeSnippet(dynamic value) {
    if (value == null) {
      return null;
    }

    final text = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? null : text;
  }

  String? _sourceFaviconUrl(String? url, {String? domain}) {
    if (url == null) {
      return null;
    }

    final resolvedDomain =
        domain?.trim() ?? SourceReferenceHelper.extractDomain(url).trim();
    if (resolvedDomain.isEmpty) {
      return null;
    }

    return 'https://www.google.com/s2/favicons?sz=32&domain=$resolvedDomain';
  }
}

class _SourceIndexBadge extends StatelessWidget {
  const _SourceIndexBadge({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(7),
      ),
      alignment: Alignment.center,
      child: Text(
        index.toString(),
        style: AppTypography.labelMediumStyle.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.textPrimary,
        ),
      ),
    );
  }
}

class _SourceFavicon extends StatefulWidget {
  const _SourceFavicon({
    required this.url,
    required this.size,
    required this.domainResolver,
    this.imageProvider,
  });

  final String url;
  final double size;
  final SourceFaviconDomainResolver domainResolver;
  final ImageProvider<Object> Function(String url)? imageProvider;

  @override
  State<_SourceFavicon> createState() => _SourceFaviconState();
}

class _SourceFaviconState extends State<_SourceFavicon> {
  late String _domain;
  int _resolutionGeneration = 0;
  bool _waitingForGroundingRedirect = false;

  @override
  void initState() {
    super.initState();
    _beginDomainResolution();
  }

  @override
  void didUpdateWidget(covariant _SourceFavicon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.domainResolver != widget.domainResolver) {
      _beginDomainResolution();
    }
  }

  void _beginDomainResolution() {
    final generation = ++_resolutionGeneration;
    _domain = SourceReferenceHelper.extractDomain(widget.url);
    final source = Uri.tryParse(widget.url);
    _waitingForGroundingRedirect = _isGoogleGroundingRedirect(source);
    if (!_waitingForGroundingRedirect) {
      return;
    }
    unawaited(() async {
      try {
        final domain = await widget.domainResolver(widget.url);
        if (!mounted || generation != _resolutionGeneration) {
          return;
        }
        final normalized = domain.trim();
        setState(() {
          if (normalized.isNotEmpty) {
            _domain = normalized;
          }
          _waitingForGroundingRedirect = false;
        });
      } catch (_) {
        if (!mounted || generation != _resolutionGeneration) {
          return;
        }
        setState(() => _waitingForGroundingRedirect = false);
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.size / 2),
        border: Border.all(color: theme.surfaceBackground, width: 1),
        color: theme.surfaceBackground,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular((widget.size / 2) - 1),
        child: _waitingForGroundingRedirect
            ? _fallback(theme)
            : Image(
                image:
                    widget.imageProvider?.call(
                      'https://www.google.com/s2/favicons?sz=32&domain=$_domain',
                    ) ??
                    CachedNetworkImageProvider(
                      'https://www.google.com/s2/favicons?sz=32&domain=$_domain',
                    ),
                width: widget.size - 2,
                height: widget.size - 2,
                fit: BoxFit.contain,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  return wasSynchronouslyLoaded || frame != null
                      ? child
                      : _fallback(theme);
                },
                errorBuilder: (context, error, stackTrace) => _fallback(theme),
              ),
      ),
    );
  }

  Widget _fallback(ConduitThemeExtension theme) {
    return Container(
      width: widget.size - 2,
      height: widget.size - 2,
      color: theme.textSecondary.withValues(alpha: 0.1),
      alignment: Alignment.center,
      child: Icon(
        Icons.language,
        size: widget.size * 0.55,
        color: theme.textSecondary.withValues(alpha: 0.6),
      ),
    );
  }
}
