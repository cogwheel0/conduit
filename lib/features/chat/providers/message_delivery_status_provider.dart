import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/persistence/conversation_store.dart';
import '../../../core/persistence/persistence_providers.dart';
import '../../../shared/services/outbox/message_outbox.dart';

part 'message_delivery_status_provider.g.dart';

/// Live delivery status for a chat message, sourced directly from the
/// SQLite outbox. Returns [MessageSendStatus.sent] for messages the server
/// has acknowledged (the bubble suppresses the badge in that case).
///
/// Reactive: watches [messageOutboxProvider] so any state change in the
/// outbox (a fresh send, a retry being scheduled, a markSent) re-fetches
/// the row's status. Single source of truth: the row's `send_status`
/// column. There is no in-memory mirror that can drift.
@riverpod
Future<MessageSendStatus> messageDeliveryStatus(
  Ref ref,
  String messageId,
) async {
  ref.watch(messageOutboxProvider);
  final store = ref.read(conversationStoreProvider);
  return store.getSendStatus(messageId);
}
