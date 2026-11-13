/// How a voice call puts what was said into its chat.
library;

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/models/chat_context_attachment.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show ChatSendPlaceholderHandle, ChatSendVoiceContext, durableSend;

/// One turn a call sends: the user's words in a Standard call, and in a
/// realtime call a request the voice hands to the chat's model, or what was
/// said with the voice's own reply to it. The same durable send a typed
/// message uses ([durableSend]), with [ref] the call's own.
typedef ChatVoiceSend = Future<void> Function(
  dynamic ref,
  String text, {
  List<String>? toolIds,
  List<ChatContextAttachment>? contextAttachments,
  bool isVoiceMode,
  ChatSendVoiceContext? voice,
  void Function(ChatSendPlaceholderHandle handle)?
  onAssistantPlaceholderCreated,
});

/// The send a call's turns go through. [durableSend] everywhere mobile runs;
/// a host that follows each turn it starts (the desktop daemon, which
/// projects a chat scope's turns onto its windows) overrides it in its chat
/// scopes, so what is said in a call streams into the chat like a typed
/// message.
final chatVoiceSendProvider = Provider<ChatVoiceSend>((_) => _durableVoiceSend);

Future<void> _durableVoiceSend(
  dynamic ref,
  String text, {
  List<String>? toolIds,
  List<ChatContextAttachment>? contextAttachments,
  bool isVoiceMode = false,
  ChatSendVoiceContext? voice,
  void Function(ChatSendPlaceholderHandle handle)?
  onAssistantPlaceholderCreated,
}) => durableSend(
  ref,
  text,
  null,
  toolIds: toolIds,
  contextAttachments: contextAttachments,
  isVoiceMode: isVoiceMode,
  voice: voice,
  onAssistantPlaceholderCreated: onAssistantPlaceholderCreated,
);
