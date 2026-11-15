import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart' show isTemporaryChat;

/// Conversations the server never stores.
///
/// A temporary chat has a `local:` id, which Open WebUI declines to persist
/// and the sync engine never pulls. Something still has to remember what
/// was said, or the second message goes out without the first. That
/// something is this, in memory. It is forgotten when the daemon exits,
/// which is the point of the feature.
final class TemporaryChats {
  final Map<String, List<ChatMessage>> _transcripts =
      <String, List<ChatMessage>>{};

  /// Ids deleted in this process. An answer still running, or a chat scope
  /// still lingering, would otherwise write a deleted chat back.
  final Set<String> _deleted = <String>{};

  static bool isTemporary(String? chatId) => isTemporaryChat(chatId);

  bool contains(String chatId) => _transcripts.containsKey(chatId);

  /// The conversation so far, oldest first. Empty for an unknown id.
  List<ChatMessage> transcript(String chatId) =>
      List<ChatMessage>.unmodifiable(_transcripts[chatId] ?? const []);

  /// Whether [chatId] was deleted: it is not written or answered again.
  bool isDeleted(String chatId) => _deleted.contains(chatId);

  void start(String chatId) {
    if (isDeleted(chatId)) return;
    _transcripts.putIfAbsent(chatId, () => []);
  }

  void append(String chatId, ChatMessage message) {
    if (isDeleted(chatId)) return;
    _transcripts.putIfAbsent(chatId, () => []).add(message);
  }

  /// Replaces the transcript with [messages]: the chat's scope held the
  /// conversation while it answered, and this is what remains of it after.
  void replace(String chatId, List<ChatMessage> messages) {
    if (isDeleted(chatId)) return;
    _transcripts[chatId] = <ChatMessage>[
      for (final message in messages) message.copyWith(isStreaming: false),
    ];
  }

  void forget(String chatId) => _transcripts.remove(chatId);

  /// Forgets [chatId] for good: the user deleted it.
  void delete(String chatId) {
    _transcripts.remove(chatId);
    _deleted.add(chatId);
  }

  /// Forgets them all: the account they were had under is no longer the
  /// one in use, and the next must not read or continue them.
  void clear() => _transcripts.clear();
}
