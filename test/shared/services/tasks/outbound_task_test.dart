import 'package:conduit/shared/services/tasks/outbound_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('send text tasks preserve pending folder id through JSON', () {
    final task = OutboundTask.sendTextMessage(
      id: 'send-task-1',
      conversationId: null,
      pendingFolderId: 'work',
      text: 'Hello from a folder draft',
    );

    final decoded = OutboundTask.fromJson(task.toJson());

    expect(decoded, isA<SendTextMessageTask>());
    expect((decoded as SendTextMessageTask).pendingFolderId, 'work');
  });
}
