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
  });
}
