import 'dart:async';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/attachment_upload_queue.dart';

/// Lifecycle tests for the per-server [AttachmentUploadQueue]. Each test builds
/// a fresh instance (the queue is no longer a singleton — it is owned and
/// disposed by `attachmentUploadQueueProvider`).
void main() {
  group('AttachmentUploadQueue lifecycle', () {
    test('periodic processing stops after dispose', () {
      fakeAsync((async) {
        var callCount = 0;
        final queue = AttachmentUploadQueue();
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            callCount++;
            return 'fake-file-id';
          },
          database: () => null,
        );
        // Let the initial (async) load settle before enqueueing.
        async.flushMicrotasks();
        queue.enqueue(filePath: '/tmp/a.txt', fileName: 'a.txt', fileSize: 1);

        async.elapse(const Duration(seconds: 25));
        async.flushMicrotasks();
        final before = callCount;
        check(before).isGreaterThan(0);

        queue.dispose();
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        check(callCount).equals(before);
      });
    });

    test('dispose closes queueStream so listeners receive onDone', () async {
      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'id',
        database: () => null,
      );
      var done = false;
      final sub = queue.queueStream.listen((_) {}, onDone: () => done = true);
      addTearDown(sub.cancel);

      queue.dispose();
      await Future<void>.delayed(Duration.zero);

      check(done).isTrue();
    });

    test('dispose is idempotent (does not double-close the controller)', () {
      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'id',
        database: () => null,
      );
      queue.dispose();
      queue.dispose();
    });

    test('an upload awaiting a terminal event resolves via onDone, and its '
        'token is cancelled, when the queue is disposed mid-upload', () async {
      final queue = AttachmentUploadQueue();
      final uploadStarted = Completer<void>();
      final hang = Completer<String>();
      CancelToken? capturedToken;
      // Release the hanging upload during cleanup so its future does not leak.
      addTearDown(() {
        if (!hang.isCompleted) hang.complete('teardown');
      });
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) {
          capturedToken = cancelToken;
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          return hang.future;
        },
        database: () => null,
      );
      await queue.ready; // load settled before enqueue (no enqueue-vs-load race)

      final id = await queue.enqueue(
        filePath: '/tmp/b.txt',
        fileName: 'b.txt',
        fileSize: 1,
      );
      // Wait until the upload actually starts (item is now `uploading`).
      await uploadStarted.future;

      // Model a MediaUploadController completer that resolves on a terminal
      // status OR when the stream closes (onDone).
      final resolved = Completer<void>();
      void tryResolve() {
        if (!resolved.isCompleted) resolved.complete();
      }

      final sub = queue.queueStream.listen(
        (items) {
          for (final e in items) {
            if (e.id == id &&
                e.status != QueuedAttachmentStatus.pending &&
                e.status != QueuedAttachmentStatus.uploading) {
              tryResolve();
            }
          }
        },
        onDone: tryResolve,
      );
      addTearDown(sub.cancel);

      queue.dispose();

      // Would hang forever before the provider-ownership refactor; now the
      // stream closes on dispose and the awaiting completer resolves.
      await resolved.future.timeout(const Duration(seconds: 1));
      check(resolved.isCompleted).isTrue();
      // Dispose aborts the in-flight upload so it cannot land on the old server.
      check(capturedToken?.isCancelled ?? false).isTrue();
    });

    test('ready resolves even when the queue is disposed mid-initialization',
        () async {
      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'id',
        database: () => null,
      );
      // Dispose before the initial load settles. `ready` is owned by the
      // instance (not a provider future), so awaiting it must still resolve
      // rather than hang — the guarantee the provider read relies on.
      queue.dispose();
      await queue.ready.timeout(const Duration(seconds: 1));
    });

    test('enqueue after dispose throws instead of silently dropping', () async {
      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'id',
        database: () => null,
      );
      await queue.ready;
      queue.dispose();

      var threw = false;
      try {
        await queue.enqueue(
          filePath: '/tmp/c.txt',
          fileName: 'c.txt',
          fileSize: 1,
        );
      } on StateError {
        threw = true;
      }
      check(threw).isTrue();
    });

    test('ready rejects on load failure and preserves the existing snapshot',
        () async {
      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'id',
        database: () => null,
      );
      await queue.ready;
      await queue.enqueue(
        filePath: '/tmp/kept.txt',
        fileName: 'kept.txt',
        fileSize: 1,
      );
      final before = queue.queue.map((e) => e.id).toList();

      // Re-initialize with a resolver that fails before the DAO read. The
      // failure must remain visible through `ready`, and staging the load means
      // the previous in-memory snapshot is not cleared on the failed attempt.
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async => 'id',
        database: () => throw StateError('load failed'),
      );
      var threw = false;
      try {
        await queue.ready;
      } on StateError {
        threw = true;
      }
      check(threw).isTrue();
      check(queue.queue.map((e) => e.id).toList()).deepEquals(before);
      queue.dispose();
    });
  });
}
