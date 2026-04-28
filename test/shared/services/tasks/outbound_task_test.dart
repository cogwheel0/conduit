import 'package:checks/checks.dart';
import 'package:conduit/shared/services/tasks/outbound_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OutboundTask.failedPermanently', () {
    // The reconnect-revives-exhausted-failures path in TaskQueue depends on
    // this discriminator to leave 4xx-style failures alone while reviving
    // network/timeout failures. Cover both shapes here.

    test('returns false for a fresh queued task', () {
      const task = OutboundTask.sendTextMessage(id: 't1', text: 'hi');
      check(task.failedPermanently).isFalse();
      check(task.failureError).isNull();
    });

    test('returns false when the error is a transient network message', () {
      const task = OutboundTask.sendTextMessage(
        id: 't2',
        text: 'hi',
        status: TaskStatus.failed,
        error: 'SocketException: Connection refused',
      );
      check(task.failedPermanently).isFalse();
    });

    test('returns true when the error is a PermanentTaskError', () {
      // Mirrors how TaskQueue records permanent failures: it stores the
      // stringified PermanentTaskError, which prefixes with the type name.
      final permanent = PermanentTaskError('400 bad request');
      final task = OutboundTask.sendTextMessage(
        id: 't3',
        text: 'hi',
        status: TaskStatus.failed,
        error: permanent.toString(),
      );
      check(task.failedPermanently).isTrue();
      check(task.failureError!).startsWith('PermanentTaskError');
    });

    test('discriminator works across all task variants', () {
      final permanentString = PermanentTaskError('nope').toString();
      final variants = <OutboundTask>[
        OutboundTask.sendTextMessage(
          id: 'a',
          text: 'x',
          status: TaskStatus.failed,
          error: permanentString,
        ),
        OutboundTask.uploadMedia(
          id: 'b',
          filePath: '/tmp/x',
          fileName: 'x',
          status: TaskStatus.failed,
          error: permanentString,
        ),
        OutboundTask.executeToolCall(
          id: 'c',
          toolName: 't',
          status: TaskStatus.failed,
          error: permanentString,
        ),
        OutboundTask.generateImage(
          id: 'd',
          prompt: 'p',
          status: TaskStatus.failed,
          error: permanentString,
        ),
        OutboundTask.imageToDataUrl(
          id: 'e',
          filePath: '/tmp/x',
          fileName: 'x',
          status: TaskStatus.failed,
          error: permanentString,
        ),
      ];
      for (final v in variants) {
        check(
          v.failedPermanently,
          because: '${v.runtimeType} should report permanent failure',
        ).isTrue();
      }
    });
  });
}
