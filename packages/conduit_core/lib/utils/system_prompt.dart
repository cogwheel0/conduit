/// Which system prompt a turn is sent with, as Open WebUI decides it.
///
/// The conversation's own prompt when it has one, otherwise the user's
/// default from Settings > General. Shared by both apps, because a desktop
/// turn that ignored the default -- which it did -- answers differently
/// from the same question asked on the phone.
library;

/// The user's default prompt from their settings, wherever this server
/// version keeps it: top-level `system`, or `ui.system`.
String? systemPromptFromSettings(Map<String, dynamic>? settings) {
  if (settings == null) return null;
  for (final candidate in <Object?>[
    settings['system'],
    (settings['ui'] is Map ? settings['ui'] as Map : null)?['system'],
  ]) {
    if (candidate is String && candidate.trim().isNotEmpty) {
      return candidate.trim();
    }
  }
  return null;
}

/// The conversation's prompt if it has one, else the settings default.
String? effectiveSystemPrompt({
  String? conversationPrompt,
  Map<String, dynamic>? settings,
}) {
  final own = conversationPrompt?.trim();
  if (own != null && own.isNotEmpty) return own;
  return systemPromptFromSettings(settings);
}

/// [messages] with [prompt] as a leading system message, unless there is
/// no prompt or the list already carries a system message of its own.
List<Map<String, dynamic>> withSystemMessage(
  List<Map<String, dynamic>> messages,
  String? prompt,
) {
  if (prompt == null || prompt.isEmpty) return messages;
  final hasSystem = messages.any(
    (message) => '${message['role']}'.toLowerCase() == 'system',
  );
  if (hasSystem) return messages;
  return <Map<String, dynamic>>[
    <String, dynamic>{'role': 'system', 'content': prompt},
    ...messages,
  ];
}
