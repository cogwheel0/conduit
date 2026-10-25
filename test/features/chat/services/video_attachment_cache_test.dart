import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/video_attachment_cache.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _clipA = 'https://cdn.example.com/a/clip.mp4';
const _clipB = 'https://cdn.example.com/b/clip.mp4';
final _bytes = Uint8List.fromList(List<int>.generate(32, (i) => i));

/// Serves each request from a body the test finishes or leaves open.
final class _HeldAdapter implements HttpClientAdapter {
  final List<String> requests = <String>[];
  final List<StreamController<Uint8List>> bodies = [];
  final List<bool> cancelled = <bool>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = requests.length;
    requests.add(options.uri.toString());
    cancelled.add(false);
    final body = StreamController<Uint8List>(
      onCancel: () => cancelled[index] = true,
    );
    bodies.add(body);
    return ResponseBody(body.stream, 200);
  }

  void finish(int index) {
    bodies[index]
      ..add(_bytes)
      ..close();
  }

  @override
  void close({bool force = false}) {}
}

/// Waits for IO and transfer callbacks that land on later event-loop turns.
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  check(condition()).isTrue();
}

void main() {
  late Directory dir;
  late _HeldAdapter adapter;
  late Dio client;

  VideoTransport transport(String url) =>
      (client: client, headers: const <String, String>{}, ownsClient: false);

  Future<File> fetch(
    VideoAttachmentCache cache,
    VideoDownloadClaim claim, {
    String url = _clipA,
    bool Function()? isCurrent,
  }) => cache.fetchForPlayback(
    claim: claim,
    url: url,
    cacheIdentity: url,
    extension: 'mp4',
    transport: transport,
    isCurrent: isCurrent ?? () => true,
  );

  File write(String name, DateTime modified, {int size = 8}) {
    final file = File('${dir.path}/$name')
      ..writeAsBytesSync(List<int>.filled(size, 1));
    file.setLastModifiedSync(modified);
    return file;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('video_cache_test_');
    adapter = _HeldAdapter();
    client = Dio()..httpClientAdapter = adapter;
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('playback transfers', () {
    test('two players of one clip join a single transfer', () async {
      final cache = VideoAttachmentCache(cacheDirectory: () async => dir);
      var joined = 0;
      bool current() {
        joined++;
        return true;
      }

      final first = fetch(cache, VideoDownloadClaim(), isCurrent: current);
      final second = fetch(cache, VideoDownloadClaim(), isCurrent: current);
      // Each attempt joins synchronously once it reports itself current.
      await _until(() => joined == 2 && adapter.bodies.isNotEmpty);
      adapter.finish(0);

      final files = await Future.wait([first, second]);
      check(adapter.requests).deepEquals([_clipA]);
      check(files[1].path).equals(files[0].path);
      check(files[0].readAsBytesSync()).deepEquals(_bytes);
    });

    test('the transfer is canceled only when its last player leaves', () async {
      final cache = VideoAttachmentCache(cacheDirectory: () async => dir);
      final firstClaim = VideoDownloadClaim();
      final secondClaim = VideoDownloadClaim();
      var joined = 0;
      bool current() {
        joined++;
        return true;
      }

      final first = fetch(cache, firstClaim, isCurrent: current);
      final second = fetch(cache, secondClaim, isCurrent: current);
      await _until(() => joined == 2 && adapter.bodies.isNotEmpty);

      cache.releaseDownload(firstClaim);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      check(adapter.cancelled.single).isFalse();

      cache.releaseDownload(secondClaim);
      await Future.wait([
        check(first).throws<DioException>(),
        check(second).throws<DioException>(),
      ]);
      check(adapter.cancelled.single).isTrue();
      // Neither a partial nor a cache file is left behind.
      check(dir.listSync()).isEmpty();

      // A player reopening the clip starts a fresh transfer.
      final reopened = fetch(cache, VideoDownloadClaim());
      await _until(() => adapter.bodies.length == 2);
      adapter.finish(1);
      check((await reopened).readAsBytesSync()).deepEquals(_bytes);
      check(adapter.requests).deepEquals([_clipA, _clipA]);
    });

    test('a stale attempt neither joins nor drops the newer transfer', () async {
      final staleDirectory = Completer<Directory>();
      var lookups = 0;
      final cache = VideoAttachmentCache(
        cacheDirectory: () =>
            lookups++ == 0 ? staleDirectory.future : Future.value(dir),
      );
      final claim = VideoDownloadClaim();
      var request = 1;

      final stale = fetch(cache, claim, isCurrent: () => request == 1);
      request = 2;
      final fresh = fetch(
        cache,
        claim,
        url: _clipB,
        isCurrent: () => request == 2,
      );
      await _until(() => adapter.bodies.isNotEmpty);

      // The replaced source's attempt resumes after the newer one joined.
      staleDirectory.complete(dir);
      await check(stale).throws<DioException>();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      check(adapter.cancelled.single).isFalse();
      check(adapter.requests).deepEquals([_clipB]);

      adapter.finish(0);
      check((await fresh).readAsBytesSync()).deepEquals(_bytes);
    });
  });

  group('pruning', () {
    test('skips held and in-flight files and evicts the oldest', () async {
      final cache = VideoAttachmentCache(
        cacheDirectory: () async => dir,
        maxCacheBytes: 10,
      );
      final oldest = write('video_held.mp4', DateTime(2026, 1, 1));
      final partial = write('video_live.mp4.0.part', DateTime(2026, 1, 1));
      final older = write('video_older.mp4', DateTime(2026, 1, 2));
      final recent = write('video_recent.mp4', DateTime(2026, 1, 3));
      final export = write('export_1.mp4', DateTime(2026, 1, 1));
      cache.retainCachePath(oldest.path);

      await cache.prune();

      check(oldest.existsSync()).isTrue();
      check(partial.existsSync()).isTrue();
      check(export.existsSync()).isTrue();
      check(older.existsSync()).isFalse();
      check(recent.existsSync()).isTrue();

      // Released, the oldest file is the first to go.
      cache.releaseCachePath(oldest.path);
      await cache.prune();
      check(oldest.existsSync()).isFalse();
      check(recent.existsSync()).isTrue();
    });
  });

  group('exports', () {
    test('an export holds the playback file after its player lets go', () async {
      final cache = VideoAttachmentCache(
        cacheDirectory: () async => dir,
        maxCacheBytes: 0,
      );
      final played = write('video_clip.mp4', DateTime(2026, 1, 1));
      cache.retainCachePath(played.path);

      final export = await cache.openForExport(
        cachedPath: played.path,
        url: _clipA,
        extension: 'mp4',
        transport: transport,
        token: CancelToken(),
        isCurrent: () => true,
      );
      check(export.file.path).equals(played.path);
      check(adapter.requests).isEmpty();

      // The player is disposed mid-export.
      cache.releaseCachePath(played.path);
      await cache.prune();
      check(played.existsSync()).isTrue();

      await export.close();
      await cache.prune();
      check(played.existsSync()).isFalse();
    });

    test('an export with no playback file downloads a scratch copy', () async {
      final cache = VideoAttachmentCache(cacheDirectory: () async => dir);

      final opening = cache.openForExport(
        cachedPath: '${dir.path}/video_missing.mp4',
        url: _clipA,
        extension: 'mp4',
        transport: transport,
        token: CancelToken(),
        isCurrent: () => true,
      );
      await _until(() => adapter.bodies.isNotEmpty);
      adapter.finish(0);
      final export = await opening;

      check(export.file.path).contains('${dir.path}/export_');
      check(export.file.readAsBytesSync()).deepEquals(_bytes);
      await export.close();
      check(export.file.existsSync()).isFalse();
    });
  });
}
