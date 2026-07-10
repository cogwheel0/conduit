import 'dart:async';

import 'package:checks/checks.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/attachment_upload_queue.dart';

void main() {
  // The class is a singleton — obtain via factory and call deactivate()
  // between tests so leftover callbacks/timers do not bleed across.
  tearDown(() {
    AttachmentUploadQueue().deactivate();
  });

  group('AttachmentUploadQueue', () {
    test('timer stops after deactivate', () {
      int callCount = 0;

      fakeAsync((async) {
        final queue = AttachmentUploadQueue();
        queue.initialize(
          onUpload: (filePath, fileName, {cancelToken}) async {
            callCount++;
            return 'fake-file-id';
          },
          database: () => null,
        );

        // Enqueue one item so the periodic tick has something to attempt.
        queue.enqueue(
          filePath: '/tmp/test.txt',
          fileName: 'test.txt',
          fileSize: 42,
        );

        // Advance past several periodic ticks (period = 10s) plus the 500ms
        // one-shot kick. Drain microtasks after each tick so the async
        // processQueue future can run.
        async.elapse(const Duration(seconds: 25));
        async.flushMicrotasks();

        final countBeforeDeactivate = callCount;
        check(countBeforeDeactivate).isGreaterThan(0);

        queue.deactivate();

        // Advance well past another set of ticks — timer must be cancelled.
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        check(callCount).equals(countBeforeDeactivate);
      });
    });

    test('deactivate nulls the upload path so processQueue is a no-op', () async {
      int callCount = 0;

      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          callCount++;
          return 'fake-file-id';
        },
        database: () => null,
      );

      queue.enqueue(
        filePath: '/tmp/test.txt',
        fileName: 'test.txt',
        fileSize: 42,
      );

      queue.deactivate();
      await queue.processQueue();

      check(callCount).equals(0);
    });

    test('queueStream stays usable after deactivate', () async {
      final queue = AttachmentUploadQueue();
      final received = <List<QueuedAttachment>>[];

      final subscription = queue.queueStream.listen(received.add);
      addTearDown(subscription.cancel);

      queue.deactivate();

      // Re-initialize and enqueue — the broadcast stream must still deliver
      // events to the subscription opened before deactivate.
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          return 'fake-file-id';
        },
        database: () => null,
      );

      await queue.enqueue(
        filePath: '/tmp/test2.txt',
        fileName: 'test2.txt',
        fileSize: 10,
      );

      // Allow async work to settle.
      await Future<void>.delayed(Duration.zero);

      check(received).isNotEmpty();
    });

    test('deactivate is idempotent — calling twice does not throw', () {
      final queue = AttachmentUploadQueue();
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) async {
          return 'fake-file-id';
        },
        database: () => null,
      );

      queue.deactivate();
      // Second call must not throw.
      queue.deactivate();
    });

    test('deactivate terminalizes non-terminal items so awaiting listeners '
        'resolve instead of hanging', () async {
      final queue = AttachmentUploadQueue();
      // Upload that never resolves on its own, so the item stays non-terminal
      // (uploading) until deactivate() drives it to a terminal state.
      final uploadStarted = Completer<void>();
      final hang = Completer<String>();
      // Release the hanging upload during cleanup so its future does not leak.
      addTearDown(() {
        if (!hang.isCompleted) hang.complete('teardown');
      });
      queue.initialize(
        onUpload: (filePath, fileName, {cancelToken}) {
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          return hang.future;
        },
        database: () => null,
      );

      final id = await queue.enqueue(
        filePath: '/tmp/x.txt',
        fileName: 'x.txt',
        fileSize: 1,
      );
      // Wait until the upload actually starts (the item is now `uploading`),
      // rather than relying on a bare microtask having elapsed.
      await uploadStarted.future;

      // Subscribe after upload start so we only observe events from here on.
      final terminalEvents = <QueuedAttachmentStatus>[];
      final sub = queue.queueStream.listen((items) {
        for (final e in items) {
          if (e.id == id &&
              e.status != QueuedAttachmentStatus.pending &&
              e.status != QueuedAttachmentStatus.uploading) {
            terminalEvents.add(e.status);
          }
        }
      });
      addTearDown(sub.cancel);

      queue.deactivate();
      await Future<void>.delayed(Duration.zero);

      // A terminal event was emitted, so a MediaUploadController completer
      // awaiting queueStream would resolve rather than hang forever.
      check(terminalEvents).isNotEmpty();
      check(terminalEvents.last).equals(QueuedAttachmentStatus.cancelled);
      // And the in-memory item is terminal.
      check(
        queue.queue.where((e) => e.id == id).single.status,
      ).equals(QueuedAttachmentStatus.cancelled);
    });
  });
}
