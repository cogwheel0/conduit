import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import 'api_service.dart';

final _imageAttachmentCacheStore = ImageAttachmentCacheStore();

/// Whether [attachmentId] is resolved through the active Open WebUI account.
///
/// Literal data and HTTP sources own their cache identity themselves. Server
/// file IDs must also include the API and authentication-session owners because
/// Open WebUI file IDs are not globally unique.
bool usesAccountScopedImageCache(String attachmentId) =>
    !attachmentId.startsWith('data:') && !attachmentId.startsWith('http');

/// Process-local ownership identity for server/account-scoped image content.
///
/// API identity covers server and configuration replacement; auth epoch fences
/// same-server account transitions. Both identities deliberately use object
/// identity: this cache never persists its keys outside the current process.
@immutable
final class ImageAttachmentCacheScope {
  const ImageAttachmentCacheScope({
    required this.api,
    required this.authSessionEpoch,
  });

  final ApiService? api;
  final Object authSessionEpoch;

  @override
  bool operator ==(Object other) =>
      other is ImageAttachmentCacheScope &&
      identical(other.api, api) &&
      identical(other.authSessionEpoch, authSessionEpoch);

  @override
  int get hashCode => Object.hash(
    api == null ? null : identityHashCode(api!),
    identityHashCode(authSessionEpoch),
  );
}

@immutable
final class _ImageAttachmentCacheKey {
  const _ImageAttachmentCacheKey(this.attachmentId, this.scope);

  factory _ImageAttachmentCacheKey.forAttachment(
    String attachmentId,
    ImageAttachmentCacheScope? scope,
  ) {
    return _ImageAttachmentCacheKey(
      attachmentId,
      usesAccountScopedImageCache(attachmentId) ? scope : null,
    );
  }

  final String attachmentId;
  final ImageAttachmentCacheScope? scope;

  @override
  bool operator ==(Object other) =>
      other is _ImageAttachmentCacheKey &&
      other.attachmentId == attachmentId &&
      other.scope == scope;

  @override
  int get hashCode => Object.hash(attachmentId, scope);
}

final Object _imageAttachmentLoadContextZoneKey = Object();

final class _ImageAttachmentLoadContext {
  const _ImageAttachmentLoadContext({
    required this.store,
    required this.key,
    required this.generation,
  });

  final ImageAttachmentCacheStore store;
  final _ImageAttachmentCacheKey key;
  final int generation;
}

final class _ImageAttachmentInFlightLoad {
  const _ImageAttachmentInFlightLoad(this.future);

  final Future<ImageAttachmentCacheEntry> future;
}

/// A resolved attachment value retained by [ImageAttachmentCacheStore].
@immutable
final class ImageAttachmentCacheEntry {
  const ImageAttachmentCacheEntry({
    this.resolvedData,
    this.bytes,
    this.error,
    required this.isSvg,
  });

  final String? resolvedData;
  final Uint8List? bytes;
  final String? error;
  final bool isSvg;

  bool get needsDecode =>
      error == null &&
      bytes == null &&
      resolvedData != null &&
      !imageAttachmentContentIsRemote(resolvedData!);
}

/// The bounded, process-wide cache used by attachment image consumers.
///
/// This service lives in core because uploads, app lifecycle, and chat widgets
/// all participate in cache ownership. It retains no Flutter image objects and
/// is synchronously cleared whenever the authentication owner changes.
final class ImageAttachmentCacheStore {
  ImageAttachmentCacheStore();

  static const int _cacheKeyMaxCharacters = 8 * 1024;
  static const int _resolvedDataEntries = 80;
  static const int _byteEntries = 48;
  static const int _resolvedDataByteBudget = 16 * 1024 * 1024;
  static const int _decodedByteBudget = 32 * 1024 * 1024;
  static const int _metadataEntries = 96;
  static const int _errorEntries = 48;

  final _LruCache<_ImageAttachmentCacheKey, String> _resolvedData =
      _LruCache<_ImageAttachmentCacheKey, String>(
        maxEntries: _resolvedDataEntries,
        maxWeight: _resolvedDataByteBudget,
        weightOf: (value) => value.length * 2,
      );
  final _LruCache<_ImageAttachmentCacheKey, Uint8List> _decodedBytes =
      _LruCache<_ImageAttachmentCacheKey, Uint8List>(
        maxEntries: _byteEntries,
        maxWeight: _decodedByteBudget,
        weightOf: (value) => value.lengthInBytes,
      );
  final _LruCache<_ImageAttachmentCacheKey, bool> _svgFlags =
      _LruCache<_ImageAttachmentCacheKey, bool>(maxEntries: _metadataEntries);
  final _LruCache<_ImageAttachmentCacheKey, String> _errors =
      _LruCache<_ImageAttachmentCacheKey, String>(maxEntries: _errorEntries);
  // In-flight work is never an eviction cache. Evicting an unresolved entry
  // permits a duplicate request for the same account/file while the first is
  // still consuming transport and decode resources.
  final Map<_ImageAttachmentCacheKey, _ImageAttachmentInFlightLoad>
  _inFlightLoads = <_ImageAttachmentCacheKey, _ImageAttachmentInFlightLoad>{};
  final Set<ImageAttachmentCacheScope> _seenAccountScopes =
      <ImageAttachmentCacheScope>{};
  final Set<Object> _invalidatedAuthSessionEpochs = HashSet<Object>.identity();
  int _cacheGeneration = 0;

  _ImageAttachmentCacheKey _key(
    String attachmentId,
    ImageAttachmentCacheScope? scope,
  ) => _ImageAttachmentCacheKey.forAttachment(attachmentId, scope);

  bool _hasCacheOwner(String attachmentId, ImageAttachmentCacheScope? scope) {
    if (!usesAccountScopedImageCache(attachmentId)) return true;
    if (scope == null ||
        _invalidatedAuthSessionEpochs.contains(scope.authSessionEpoch)) {
      return false;
    }
    _seenAccountScopes.add(scope);
    return true;
  }

  bool _canWriteForCurrentLoad(_ImageAttachmentCacheKey key) {
    final context = Zone.current[_imageAttachmentLoadContextZoneKey];
    if (context is! _ImageAttachmentLoadContext ||
        !identical(context.store, this)) {
      return true;
    }
    return context.generation == _cacheGeneration && context.key == key;
  }

  ImageAttachmentCacheEntry? read(
    String attachmentId, {
    ImageAttachmentCacheScope? scope,
  }) {
    // A server file ID is meaningful only inside an authenticated account.
    // When that owner is unavailable, bypass every process-wide cache surface
    // rather than collapsing unrelated accounts into a shared null scope.
    if (!_hasCacheOwner(attachmentId, scope)) return null;
    final key = _key(attachmentId, scope);
    final error = _errors.read(key);
    if (error != null) {
      return ImageAttachmentCacheEntry(
        error: error,
        isSvg: _svgFlags.read(key) ?? false,
      );
    }

    final data = _resolvedData.read(key);
    final bytes = _decodedBytes.read(key);
    final isSvg =
        _svgFlags.read(key) ??
        (bytes != null && imageAttachmentBytesAreSvg(bytes)) ||
            (data != null &&
                (imageAttachmentDataIsSvg(data) ||
                    imageAttachmentUrlIsSvg(data)));
    if (data == null && bytes == null) {
      return null;
    }
    return ImageAttachmentCacheEntry(
      resolvedData: data,
      bytes: bytes,
      isSvg: isSvg,
    );
  }

  void cacheBytes(
    String attachmentId,
    Uint8List bytes, {
    ImageAttachmentCacheScope? scope,
    bool? isSvg,
  }) {
    if (!_hasCacheOwner(attachmentId, scope)) return;
    final key = _key(attachmentId, scope);
    if (!_canWriteForCurrentLoad(key)) return;
    _errors.remove(key);
    if (attachmentId.length > _cacheKeyMaxCharacters) {
      // Inline data URLs can themselves be tens of megabytes. Let the mounted
      // widget use the decoded result, but do not retain that payload again as
      // a global cache key.
      _decodedBytes.remove(key);
      _svgFlags.remove(key);
      return;
    }
    _decodedBytes.write(key, bytes);
    _cacheSvgFlag(key, isSvg ?? imageAttachmentBytesAreSvg(bytes));
  }

  void cacheError(
    String attachmentId,
    String error, {
    ImageAttachmentCacheScope? scope,
  }) {
    if (!_hasCacheOwner(attachmentId, scope)) return;
    final key = _key(attachmentId, scope);
    if (!_canWriteForCurrentLoad(key)) return;
    if (attachmentId.length > _cacheKeyMaxCharacters) {
      _errors.remove(key);
      _resolvedData.remove(key);
      _decodedBytes.remove(key);
      _svgFlags.remove(key);
      return;
    }
    _errors.write(key, error);
    _resolvedData.remove(key);
    _decodedBytes.remove(key);
    _svgFlags.remove(key);
  }

  void cacheResolvedData(
    String attachmentId,
    String resolvedData, {
    required bool isSvg,
    ImageAttachmentCacheScope? scope,
  }) {
    if (!_hasCacheOwner(attachmentId, scope)) return;
    final key = _key(attachmentId, scope);
    if (!_canWriteForCurrentLoad(key)) return;
    _errors.remove(key);
    if (attachmentId.length > _cacheKeyMaxCharacters) {
      _resolvedData.remove(key);
      _svgFlags.remove(key);
      return;
    }
    _resolvedData.write(key, resolvedData);
    _cacheSvgFlag(key, isSvg);
  }

  /// Deduplicates concurrent loading for one attachment owner.
  Future<ImageAttachmentCacheEntry> load(
    String attachmentId, {
    ImageAttachmentCacheScope? scope,
    required Future<ImageAttachmentCacheEntry> Function(
      ImageAttachmentCacheEntry? cached,
    )
    loader,
  }) {
    if (!_hasCacheOwner(attachmentId, scope)) {
      return loader(null);
    }
    final key = _key(attachmentId, scope);
    final cached = read(attachmentId, scope: scope);
    if (cached != null &&
        (!cached.needsDecode || cached.bytes != null || cached.error != null)) {
      return Future<ImageAttachmentCacheEntry>.value(cached);
    }

    final inFlight = _inFlightLoads[key];
    if (inFlight != null) {
      return inFlight.future;
    }

    final loadGeneration = _cacheGeneration;
    late final Future<ImageAttachmentCacheEntry> future;
    future = runZoned(
      () async {
        try {
          final result = await loader(cached);
          // A clear() is an ownership boundary, not just a cache eviction.
          // Returning bytes resolved before that boundary could briefly paint
          // content owned by the previous authenticated account even though
          // every attempted cache write was correctly rejected.
          if (loadGeneration != _cacheGeneration) {
            throw StateError('Image attachment load was invalidated.');
          }
          return result;
        } finally {
          final current = _inFlightLoads[key];
          if (current != null && identical(current.future, future)) {
            _inFlightLoads.remove(key);
          }
        }
      },
      zoneValues: {
        _imageAttachmentLoadContextZoneKey: _ImageAttachmentLoadContext(
          store: this,
          key: key,
          generation: loadGeneration,
        ),
      },
    );
    _inFlightLoads[key] = _ImageAttachmentInFlightLoad(future);
    return future;
  }

  void clear({Object? invalidatedAuthSessionEpoch}) {
    if (invalidatedAuthSessionEpoch != null) {
      _invalidatedAuthSessionEpochs.add(invalidatedAuthSessionEpoch);
    }
    for (final scope in _seenAccountScopes) {
      _invalidatedAuthSessionEpochs.add(scope.authSessionEpoch);
    }
    _seenAccountScopes.clear();
    _cacheGeneration += 1;
    _resolvedData.clear();
    _decodedBytes.clear();
    _svgFlags.clear();
    _errors.clear();
    _inFlightLoads.clear();
  }

  @visibleForTesting
  void debugReset() {
    clear();
    _seenAccountScopes.clear();
    _invalidatedAuthSessionEpochs.clear();
  }

  @visibleForTesting
  void debugSeedResolvedData(
    String attachmentId,
    String resolvedData, {
    ImageAttachmentCacheScope? scope,
  }) {
    cacheResolvedData(
      attachmentId,
      resolvedData,
      isSvg: imageAttachmentDataIsSvg(resolvedData),
      scope: scope,
    );
  }

  @visibleForTesting
  bool debugHasResolvedData(
    String attachmentId, {
    ImageAttachmentCacheScope? scope,
  }) =>
      _hasCacheOwner(attachmentId, scope) &&
      _resolvedData.containsKey(_key(attachmentId, scope));

  @visibleForTesting
  bool debugHasDecodedBytes(
    String attachmentId, {
    ImageAttachmentCacheScope? scope,
  }) =>
      _hasCacheOwner(attachmentId, scope) &&
      _decodedBytes.containsKey(_key(attachmentId, scope));

  @visibleForTesting
  bool debugHasError(String attachmentId, {ImageAttachmentCacheScope? scope}) =>
      _hasCacheOwner(attachmentId, scope) &&
      _errors.containsKey(_key(attachmentId, scope));

  @visibleForTesting
  int get debugResolvedDataCount => _resolvedData.length;

  @visibleForTesting
  int get debugDecodedByteCount => _decodedBytes.length;

  @visibleForTesting
  int get debugDecodedByteWeight => _decodedBytes.totalWeight;

  @visibleForTesting
  static int get debugDecodedByteBudget => _decodedByteBudget;

  void _cacheSvgFlag(_ImageAttachmentCacheKey key, bool isSvg) {
    if (key.attachmentId.length <= _cacheKeyMaxCharacters) {
      _svgFlags.write(key, isSvg);
    }
  }
}

/// Pre-caches uploaded image bytes for immediate display by server file ID.
void preCacheImageBytes(
  String fileId,
  Uint8List bytes, {
  ImageAttachmentCacheScope? scope,
}) {
  if (fileId.isEmpty || bytes.isEmpty) return;
  _imageAttachmentCacheStore.cacheBytes(fileId, bytes, scope: scope);
}

/// Clears retained image content at every authentication ownership transition.
final imageAttachmentCacheLifecycleProvider = Provider<void>((ref) {
  ref.listen<Object>(openWebUiAuthSessionEpochProvider, (previous, next) {
    if (previous != null && !identical(previous, next)) {
      _imageAttachmentCacheStore.clear(invalidatedAuthSessionEpoch: previous);
    }
  });
});

bool imageAttachmentDataIsSvg(String data) =>
    data.toLowerCase().startsWith('data:image/svg+xml');

bool imageAttachmentUrlIsSvg(String url) {
  final parsed = Uri.tryParse(url.trim());
  if (parsed != null) {
    if (parsed.path.toLowerCase().endsWith('.svg')) return true;
    if (parsed.query.toLowerCase().contains('image/svg+xml')) return true;
    if (parsed.queryParameters.values.any(
      (value) => value.toLowerCase().contains('image/svg+xml'),
    )) {
      return true;
    }
    return false;
  }

  // Keep malformed-but-displayable sources on the legacy best-effort path,
  // while ensuring a fragment can never become part of the extension/query.
  final withoutFragment = url.split('#').first.toLowerCase();
  final queryIndex = withoutFragment.indexOf('?');
  final pathPart = queryIndex >= 0
      ? withoutFragment.substring(0, queryIndex)
      : withoutFragment;
  final queryPart = queryIndex >= 0
      ? withoutFragment.substring(queryIndex + 1)
      : '';
  return pathPart.endsWith('.svg') || queryPart.contains('image/svg+xml');
}

bool imageAttachmentBytesAreSvg(Uint8List bytes) {
  final checkLength = bytes.length < 1024 ? bytes.length : 1024;
  final header = utf8.decode(
    bytes.sublist(0, checkLength),
    allowMalformed: true,
  );
  return header.toLowerCase().contains('<svg');
}

bool imageAttachmentContentIsRemote(String data) => data.startsWith('http');

@visibleForTesting
void debugResetImageAttachmentCaches() =>
    _imageAttachmentCacheStore.debugReset();

@visibleForTesting
void debugSeedResolvedImageAttachment(
  String attachmentId,
  String resolvedData, {
  ImageAttachmentCacheScope? scope,
}) {
  _imageAttachmentCacheStore.debugSeedResolvedData(
    attachmentId,
    resolvedData,
    scope: scope,
  );
}

@visibleForTesting
void debugSeedImageAttachmentError(
  String attachmentId,
  String error, {
  ImageAttachmentCacheScope? scope,
}) {
  _imageAttachmentCacheStore.cacheError(attachmentId, error, scope: scope);
}

@visibleForTesting
bool debugHasResolvedImageAttachment(
  String attachmentId, {
  ImageAttachmentCacheScope? scope,
}) =>
    _imageAttachmentCacheStore.debugHasResolvedData(attachmentId, scope: scope);

@visibleForTesting
bool debugHasDecodedImageAttachment(
  String attachmentId, {
  ImageAttachmentCacheScope? scope,
}) =>
    _imageAttachmentCacheStore.debugHasDecodedBytes(attachmentId, scope: scope);

@visibleForTesting
bool debugHasImageAttachmentError(
  String attachmentId, {
  ImageAttachmentCacheScope? scope,
}) => _imageAttachmentCacheStore.debugHasError(attachmentId, scope: scope);

@visibleForTesting
int debugResolvedImageAttachmentCount() =>
    _imageAttachmentCacheStore.debugResolvedDataCount;

@visibleForTesting
int debugDecodedImageAttachmentCount() =>
    _imageAttachmentCacheStore.debugDecodedByteCount;

@visibleForTesting
int debugDecodedImageAttachmentWeight() =>
    _imageAttachmentCacheStore.debugDecodedByteWeight;

@visibleForTesting
int get debugDecodedImageAttachmentByteBudget =>
    ImageAttachmentCacheStore.debugDecodedByteBudget;

/// Package API used by the attachment widget to read and populate the store.
ImageAttachmentCacheStore get imageAttachmentCacheStore =>
    _imageAttachmentCacheStore;

final class _LruCache<K, V> {
  _LruCache({
    required this.maxEntries,
    this.maxWeight,
    int Function(V value)? weightOf,
  }) : _weightOf = weightOf ?? _unitWeight;

  final int maxEntries;
  final int? maxWeight;
  final int Function(V value) _weightOf;
  final LinkedHashMap<K, V> _entries = LinkedHashMap<K, V>();
  int _totalWeight = 0;

  static int _unitWeight(Object? _) => 1;

  V? read(K key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value;
    return value;
  }

  void write(K key, V value) {
    final previous = _entries.remove(key);
    if (previous != null) {
      _totalWeight -= _weightOf(previous);
    }
    final weight = _weightOf(value);
    final budget = maxWeight;
    if (budget != null && weight > budget) return;

    _entries[key] = value;
    _totalWeight += weight;
    while (_entries.length > maxEntries ||
        (budget != null && _totalWeight > budget)) {
      final removed = _entries.remove(_entries.keys.first);
      if (removed != null) {
        _totalWeight -= _weightOf(removed);
      }
    }
  }

  void remove(K key) {
    final removed = _entries.remove(key);
    if (removed != null) {
      _totalWeight -= _weightOf(removed);
    }
  }

  void removeIfSame(K key, V value) {
    final existing = _entries[key];
    if (identical(existing, value)) remove(key);
  }

  void clear() {
    _entries.clear();
    _totalWeight = 0;
  }

  bool containsKey(K key) => _entries.containsKey(key);

  int get length => _entries.length;

  int get totalWeight => _totalWeight;
}
