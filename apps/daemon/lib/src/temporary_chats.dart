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

  static bool isTemporary(String? chatId) => isTemporaryChat(chatId);

  bool contains(String chatId) => _transcripts.containsKey(chatId);

  /// The conversation so far, oldest first. Empty for an unknown id.
  List<ChatMessage> transcript(String chatId) =>
      List<ChatMessage>.unmodifiable(_transcripts[chatId] ?? const []);

  void start(String chatId) => _transcripts.putIfAbsent(chatId, () => []);

  void append(String chatId, ChatMessage message) =>
      _transcripts.putIfAbsent(chatId, () => []).add(message);

  void forget(String chatId) => _transcripts.remove(chatId);
}
