import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' as dio;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// The client and headers one video fetch uses. [ownsClient] marks a
/// throwaway client that is closed when the transfer ends; ApiService.dio is
/// shared with the rest of the app and is never closed.
typedef VideoTransport = ({
  dio.Dio client,
  Map<String, String> headers,
  bool ownsClient,
});

/// The process-wide video cache shared by every chat video player.
final videoAttachmentCacheProvider = Provider<VideoAttachmentCache>(
  (ref) => VideoAttachmentCache(),
);

/// One player's interest in at most one shared playback transfer.
final class VideoDownloadClaim {
  _SharedVideoDownload? _active;
}

/// A local copy of a video handed to an exporter. [close] releases the hold
/// on a playback cache file, or deletes a scratch download.
final class VideoExportFile {
  VideoExportFile._(this._cache, this.file, {required bool scratch})
    : _scratch = scratch;

  final VideoAttachmentCache _cache;
  final File file;
  final bool _scratch;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_scratch) {
      _cache.releaseCachePath(file.path);
      return;
    }
    // Scratch downloads belong to the export; the playback cache may still
    // be in use by the player, so it stays put.
    try {
      await file.delete();
    } catch (_) {}
  }
}

/// Downloads chat videos into an on-disk playback cache.
///
/// Players rendering the same URL join one shared transfer per cache path;
/// each [VideoDownloadClaim] counts as one interested player, so the
/// download is canceled only when the last one is gone. Cache files are
/// reference counted, and pruning never evicts a file that a player or an
/// export still holds.
class VideoAttachmentCache {
  VideoAttachmentCache({
    Future<Directory> Function()? cacheDirectory,
    this.maxVideoBytes = 512 * 1024 * 1024,
    this.maxCacheBytes = 1024 * 1024 * 1024,
  }) : _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory;

  static Future<Directory> _defaultCacheDirectory() async {
    final dir = await getTemporaryDirectory();
    return Directory('${dir.path}/conduit_attachments');
  }

  final Future<Directory> Function() _cacheDirectory;

  /// Downloads larger than this are canceled.
  final int maxVideoBytes;

  /// Aggregate playback cache ceiling: each distinct clip keeps a persistent
  /// cache file, so the oldest unreferenced files are evicted once the video
  /// cache passes this budget instead of accumulating until the OS clears it.
  final int maxCacheBytes;

  static const Duration _downloadStallTimeout = Duration(seconds: 45);

  // One shared transfer per cache path, joined by every player rendering the
  // same URL; refs tracks how many live players still care.
  final Map<String, _SharedVideoDownload> _sharedDownloads = {};
  final Map<String, int> _cacheRefs = {};
  bool _pruning = false;
  int _scratchSeq = 0;

  /// Keeps [path] from pruning until a matching [releaseCachePath].
  void retainCachePath(String? path) {
    if (path == null) return;
    _cacheRefs[path] = (_cacheRefs[path] ?? 0) + 1;
  }

  void releaseCachePath(String? path) {
    if (path == null) return;
    final refs = (_cacheRefs[path] ?? 1) - 1;
    if (refs <= 0) {
      _cacheRefs.remove(path);
    } else {
      _cacheRefs[path] = refs;
    }
  }

  /// Returns the local cache copy for [url], sharing one in-flight transfer
  /// per cache key: two players rendering the same clip join the same
  /// download instead of racing on the same scratch file. The transfer
  /// lands on a transfer-unique scratch path and is renamed only after a
  /// complete download, so a canceled or stale request never clobbers a
  /// live one and never leaves a half-written file that a later length() > 0
  /// cache hit would accept.
  ///
  /// The returned file is held for the caller, who releases it with
  /// [releaseCachePath]. [cacheIdentity] scopes the cache name (Open WebUI
  /// file URLs are the same for every account on a server). [isCurrent]
  /// reports whether the caller still wants this attempt.
  Future<File> fetchForPlayback({
    required VideoDownloadClaim claim,
    required String url,
    required String cacheIdentity,
    required String extension,
    required VideoTransport Function(String url) transport,
    required bool Function() isCurrent,
  }) async {
    final dir = await _cacheDirectory();
    final target = File(
      '${dir.path}/video_${_cacheNameFor(url, cacheIdentity)}.$extension',
    );
    if (await target.exists() && await target.length() > 0) {
      // Reserve before returning: player initialization awaits afterwards,
      // and a prune from another player must not evict this file mid-open.
      retainCachePath(target.path);
      return target;
    }
    await target.parent.create(recursive: true);

    // If the player was disposed during the awaits above, it could not have
    // released anything (no download was tracked yet). Stop before joining
    // or starting a transfer nobody would ever release.
    if (!isCurrent()) {
      // Disposed, or a replaced source already started a newer open: never
      // release or join transfers on behalf of a stale attempt.
      throw dio.DioException(
        requestOptions: dio.RequestOptions(path: url),
        message: 'Video open attempt is no longer current',
      );
    }

    // A player can only be interested in one playback transfer at a time;
    // drop interest in any earlier attempt before joining a new one.
    releaseDownload(claim);
    final key = target.path;
    var entry = _sharedDownloads[key];
    if (entry != null && entry.token.isCancelled) {
      // A canceled transfer is never reusable: a player reopening the video
      // must start a fresh download, not join the dying one.
      _sharedDownloads.remove(key);
      entry = null;
    }
    if (entry == null) {
      entry = _SharedVideoDownload(dio.CancelToken(), key);
      entry.refs = 1;
      final created = entry;
      created.future = _runVideoDownload(url, target, created.token, transport)
          .whenComplete(() {
            if (_sharedDownloads[key] == created) {
              _sharedDownloads.remove(key);
            }
          });
      _sharedDownloads[key] = entry;
    } else {
      entry.refs += 1;
    }
    claim._active = entry;
    File downloaded;
    try {
      downloaded = await entry.future;
    } finally {
      // This attempt's transfer is finished; forget it so a later release
      // cannot decrement references on a newer transfer for the same key.
      if (claim._active == entry) {
        claim._active = null;
      }
    }
    // Reserve before handing the file to the player: the shared transfer
    // is gone from the registry, and the player awaits initialize().
    retainCachePath(downloaded.path);
    return downloaded;
  }

  /// Drops [claim]'s interest in its shared download; the transfer is
  /// canceled only when the last interested player is gone. The shared Dio
  /// client is never closed here.
  void releaseDownload(VideoDownloadClaim claim) {
    final entry = claim._active;
    if (entry == null) return;
    claim._active = null;
    entry.refs -= 1;
    if (entry.refs <= 0) {
      // Retire the entry immediately so a reopening player cannot join a
      // transfer that is about to be canceled.
      if (_sharedDownloads[entry.key] == entry) {
        _sharedDownloads.remove(entry.key);
      }
      entry.token.cancel('video player disposed');
    }
  }

  /// Opens a local copy of the video for an export: the playback cache file
  /// at [cachedPath] while it is complete, held until the export closes so
  /// pruning cannot delete it mid-copy, or else a scratch download of [url].
  /// [token] cancels the scratch download; [isCurrent] reports whether the
  /// caller still wants it.
  Future<VideoExportFile> openForExport({
    required String? cachedPath,
    required String? url,
    required String extension,
    required VideoTransport Function(String url) transport,
    required dio.CancelToken token,
    required bool Function() isCurrent,
  }) async {
    if (cachedPath != null) {
      // The player's hold on its cache file can end mid-export; keep the
      // file from pruning until the save has copied it.
      retainCachePath(cachedPath);
      final cachedFile = File(cachedPath);
      var complete = false;
      try {
        complete = await cachedFile.exists() && await cachedFile.length() > 0;
      } finally {
        // A missing or unreadable file gives the hold back.
        if (!complete) {
          releaseCachePath(cachedPath);
        }
      }
      if (complete) {
        return VideoExportFile._(this, cachedFile, scratch: false);
      }
    }
    if (url == null || url.isEmpty) {
      throw StateError('Video source unavailable');
    }
    final dir = await _cacheDirectory();
    // The sequence keeps exports started in the same millisecond apart.
    final target = File(
      '${dir.path}/export_'
      '${DateTime.now().millisecondsSinceEpoch}_${_scratchSeq++}.$extension',
    );
    await target.parent.create(recursive: true);
    // Disposed during the awaits above: a transfer started now could never
    // be stopped.
    if (!isCurrent()) {
      throw dio.DioException(
        requestOptions: dio.RequestOptions(path: url),
        message: 'Video widget was disposed',
      );
    }
    final (:client, :headers, :ownsClient) = transport(url);
    try {
      await _streamToFile(client, url, target.path, headers, token);
    } catch (error) {
      // A stall, network error, or dispose-time cancel can leave a partial
      // copy of a potentially large video; delete it instead of leaving it
      // for the OS to clear.
      try {
        if (await target.exists()) {
          await target.delete();
        }
      } catch (_) {}
      rethrow;
    } finally {
      // Never close ApiService.dio: it is shared with the rest of the app.
      if (ownsClient) {
        client.close(force: true);
      }
    }
    return VideoExportFile._(this, target, scratch: true);
  }

  Future<File> _runVideoDownload(
    String url,
    File target,
    dio.CancelToken token,
    VideoTransport Function(String url) transport,
  ) async {
    final part = File('${target.path}.${_scratchSeq++}.part');
    final (:client, :headers, :ownsClient) = transport(url);
    try {
      await _streamToFile(client, url, part.path, headers, token);
      await part.rename(target.path);
      unawaited(prune());
      return target;
    } finally {
      // Never close ApiService.dio: it is shared with the rest of the app.
      if (ownsClient) {
        client.close(force: true);
      }
      try {
        if (await part.exists()) {
          await part.delete();
        }
      } catch (_) {}
    }
  }

  /// Downloads [url] to [path] with a stalled-transfer watchdog instead of a
  /// fixed total-transfer deadline: the request is aborted only when no data
  /// arrives for [_downloadStallTimeout] (45s) or the headers never arrive
  /// (60s), not because the file is large. Cancelable via [token].
  Future<void> _streamToFile(
    dio.Dio client,
    String url,
    String path,
    Map<String, String> headers,
    dio.CancelToken token,
  ) async {
    var lastChunkAt = DateTime.now();
    final watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (DateTime.now().difference(lastChunkAt) > _downloadStallTimeout) {
        token.cancel('video download stalled');
      }
    });
    try {
      await client.download(
        url,
        path,
        cancelToken: token,
        onReceiveProgress: (received, total) {
          lastChunkAt = DateTime.now();
          if (received > maxVideoBytes) {
            token.cancel('video exceeds size limit');
          }
        },
        options: dio.Options(
          headers: headers,
          responseType: dio.ResponseType.stream,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );
    } finally {
      watchdog.cancel();
    }
  }

  /// Evicts the oldest completed playback files once the video cache passes
  /// [maxCacheBytes], skipping files live players, exports or in-flight
  /// shared transfers still reference.
  Future<void> prune() async {
    if (_pruning) return;
    _pruning = true;
    try {
      final dir = await _cacheDirectory();
      if (!dir.existsSync()) return;
      final candidates = <({File file, int size, DateTime modified})>[];
      int total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('video_')) continue;
        // An in-flight playback download writes video_<key>.<seq>.part;
        // _sharedDownloads keys the FINAL path, so the reference check below
        // cannot protect it. Scratch owners delete their own partials.
        if (name.endsWith('.part')) continue;
        if (_cacheRefs.containsKey(entity.path) ||
            _sharedDownloads.containsKey(entity.path)) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.size <= 0) continue;
        candidates.add((
          file: entity,
          size: stat.size,
          modified: stat.modified,
        ));
        total += stat.size;
      }
      if (total <= maxCacheBytes) return;
      candidates.sort((a, b) => a.modified.compareTo(b.modified));
      for (final candidate in candidates) {
        if (total <= maxCacheBytes) break;
        // A player may have opened (or a transfer may have finished into)
        // this file after the scan; re-verify before deleting it.
        if (_cacheRefs.containsKey(candidate.file.path) ||
            _sharedDownloads.containsKey(candidate.file.path)) {
          continue;
        }
        try {
          await candidate.file.delete();
          total -= candidate.size;
        } catch (_) {}
      }
    } catch (_) {
      // Cache bookkeeping must never break playback.
    } finally {
      _pruning = false;
    }
  }

  String _cacheNameFor(String url, String cacheIdentity) {
    final uri = Uri.tryParse(url);
    final segments = uri == null
        ? const <String>[]
        : uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    final label = segments.isEmpty
        ? 'video'
        : segments.last.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final trimmed = label.length > 48 ? label.substring(0, 48) : label;
    final digest = sha256.convert(utf8.encode(cacheIdentity)).toString();
    return '${trimmed}_${digest.substring(0, 32)}';
  }
}

/// One in-flight video download shared by every player that requested the
/// same cache path. Cancel happens only when the last interested player is
/// gone; the shared Dio client itself is never closed.
class _SharedVideoDownload {
  _SharedVideoDownload(this.token, this.key);

  final dio.CancelToken token;
  final String key;
  late final Future<File> future;
  int refs = 0;
}
