// How a message's sources are presented: the snippet, favicon and count the
// sources sheet (lib/features/chat/widgets/sources/openwebui_sources.dart)
// shows.
import 'dart:async';
import 'dart:collection';
import 'dart:io' show HttpClient, HttpHeaders;

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/utils/source_reference_helper.dart';
import 'package:meta/meta.dart';

typedef SourceFaviconDomainResolver = Future<String> Function(String url);
typedef SourceGroundingRedirectResolver = Future<Uri?> Function(Uri source);

const _googleGroundingRedirectHost = 'vertexaisearch.cloud.google.com';
const _googleGroundingRedirectPath = '/grounding-api-redirect';
const _sourceFaviconDomainCacheLimit = 256;

typedef _SourceFaviconDomainCacheKey = ({
  String sourceUrl,
  SourceGroundingRedirectResolver? redirectResolver,
});

final LinkedHashMap<_SourceFaviconDomainCacheKey, Future<String>>
_sourceFaviconDomainCache =
    LinkedHashMap<_SourceFaviconDomainCacheKey, Future<String>>();

/// Whether [uri] is a Gemini grounding redirect (an opaque Google URL that
/// hides the cited site).
bool isGoogleGroundingRedirect(Uri? uri) =>
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
  SourceGroundingRedirectResolver? redirectResolver,
}) {
  final key = (sourceUrl: sourceUrl.trim(), redirectResolver: redirectResolver);
  final cached = _sourceFaviconDomainCache.remove(key);
  if (cached != null) {
    _sourceFaviconDomainCache[key] = cached;
    return cached;
  }

  final result = _resolveSourceFaviconDomainUncached(
    sourceUrl,
    redirectResolver: redirectResolver,
  );
  _sourceFaviconDomainCache[key] = result;
  while (_sourceFaviconDomainCache.length > _sourceFaviconDomainCacheLimit) {
    _sourceFaviconDomainCache.remove(_sourceFaviconDomainCache.keys.first);
  }
  return result;
}

Future<String> _resolveSourceFaviconDomainUncached(
  String sourceUrl, {
  SourceGroundingRedirectResolver? redirectResolver,
}) async {
  final source = Uri.tryParse(sourceUrl);
  final fallback = SourceReferenceHelper.extractDomain(sourceUrl).trim();
  if (!isGoogleGroundingRedirect(source)) {
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

@visibleForTesting
void debugResetSourceFaviconDomainCache() {
  _sourceFaviconDomainCache.clear();
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

/// The sources chip's and sheet's title. English only, as Open WebUI's.
String sourceCountLabel(int count) =>
    count == 1 ? '1 Source' : '$count Sources';

/// The source's type ("web_search", "file"), or null when blank.
String? sourceType(ChatSourceReference source) {
  final type = source.type?.trim();
  return type == null || type.isEmpty ? null : type;
}

/// The first non-blank excerpt of a source, whitespace collapsed: its
/// snippet, then its documents, then the snippet-like fields of its
/// metadata.
String? sourceSnippet(ChatSourceReference source) {
  final candidates = <dynamic>[
    source.snippet,
    ..._metadataSnippetCandidates(source),
  ];
  for (final candidate in candidates) {
    final normalized = _normalizeSnippet(candidate);
    if (normalized != null) return normalized;
  }
  return null;
}

Iterable<dynamic> _metadataSnippetCandidates(ChatSourceReference source) sync* {
  final metadata = source.metadata;
  if (metadata == null) return;

  final documents = metadata['documents'];
  if (documents is List) {
    yield* documents;
  }

  final primaryMetadata = SourceReferenceHelper.primaryMetadata(source);
  final nestedSource = SourceReferenceHelper.nestedSourceMetadata(source);
  for (final entry in [primaryMetadata, nestedSource]) {
    if (entry == null) continue;
    yield entry['snippet'];
    yield entry['content'];
    yield entry['description'];
    yield entry['text'];
  }
}

String? _normalizeSnippet(dynamic value) {
  if (value == null) return null;
  final text = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isEmpty ? null : text;
}

/// Google's favicon service URL for the site behind [url] ([domain] when
/// already resolved), or null.
String? sourceFaviconUrl(String? url, {String? domain}) {
  if (url == null) return null;
  final resolved =
      domain?.trim() ?? SourceReferenceHelper.extractDomain(url).trim();
  if (resolved.isEmpty) return null;
  return 'https://www.google.com/s2/favicons?sz=32&domain=$resolved';
}
