import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../shared/services/tasks/outbound_task.dart';
import '../../../shared/services/tasks/task_queue.dart';
import 'chat_providers.dart';

part 'message_delivery_status_provider.g.dart';

/// Live delivery status for a chat message that originated from a persistent
/// [OutboundTask]. Returns `null` when the message is not associated with a
/// task (e.g. older messages, or sends that bypassed the queue) or when the
/// task has already succeeded — in which case the bubble shows no badge.
///
/// Wiring: [_sendMessageInternal] writes the task id into the user message's
/// `metadata['outboundTaskId']` (Phase 2.5). This provider walks that pointer
/// and watches the [taskQueueProvider] state for changes.
@riverpod
TaskStatus? messageDeliveryStatus(Ref ref, String messageId) {
  // Look up the message in the chat state to find its task id.
  final messages = ref.watch(chatMessagesProvider);
  String? taskId;
  for (final m in messages) {
    if (m.id == messageId) {
      final raw = m.metadata?['outboundTaskId'];
      if (raw is String && raw.isNotEmpty) {
        taskId = raw;
      }
      break;
    }
  }
  if (taskId == null) return null;

  final tasks = ref.watch(taskQueueProvider);
  for (final t in tasks) {
    if (t.id == taskId) {
      // Hide the badge once the message has been accepted by the server.
      if (t.status == TaskStatus.succeeded) return null;
      return t.status;
    }
  }
  // Task was pruned from the queue (e.g. completed and saved as non-retained)
  // — no badge needed.
  return null;
}

