import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/sync/pull_sync.dart';

/// The sync of whichever account owns the Chats tab: Open WebUI's
/// `SyncEngine` today, a LibreChat engine when a LibreChat account does.
///
/// App-wide triggers (start, foreground, connectivity, the periodic timer)
/// and the user's own refreshes go through `primarySyncProvider`, so they
/// reach the right server without knowing which one it is. Work that belongs
/// to one backend's own storage -- an Open WebUI send, a remap, a note --
/// keeps talking to that backend's engine directly.
abstract interface class PrimarySync {
  /// Whether the account is signed in with its database open, so a refresh
  /// can reach anything.
  bool get canSync;

  /// Debounced, single-flight pull of the chat list. Completes when the
  /// cycle the call joined finishes; null when the engine is idle.
  Future<PullResult?> requestPull({required String reason});

  /// Resets outbox backoff, then drains it (connectivity regained).
  Future<void> drainNow();

  /// Drains the outbox without resetting backoff.
  Future<void> drainOutbox();

  /// Removes local chats deleted on the server, skipping any throttle.
  Future<void> reconcileNow();

  /// Pulls one chat at once, bypassing the debounce.
  Future<Conversation?> pullChatNow(String chatId);
}
