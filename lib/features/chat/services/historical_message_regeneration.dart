import '../../../core/providers/app_providers.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/services/api_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../providers/chat_providers.dart';
import '../services/chat_transport_dispatch.dart';
import '../utils/message_targeting.dart';

Future<void> regenerateHistoricalMessageById(
  dynamic ref,
  String assistantMessageId,
) async {
  final selectedModel = ref.read(selectedModelProvider);
  if (selectedModel == null) {
    return;
  }

  if (ref.read(isChatStreamingProvider)) {
    DebugLogger.log(
      'historical regenerate blocked while another message streams',
      scope: 'chat/regeneration',
      data: {'assistantMessageId': assistantMessageId},
    );
    return;
  }

  final originalMessages = List<ChatMessage>.from(
    ref.read(chatMessagesProvider),
    growable: false,
  );
  final target = resolveAssistantRegenerationTarget(
    originalMessages,
    assistantMessageId,
  );
  if (target == null) {
    return;
  }

  final targetAssistant = target.assistantMessage;
  final targetUser = target.userMessage;
  final truncatedMessages = truncateMessagesAfterId(
    originalMessages,
    assistantMessageId,
    includeTarget: true,
  );
  final notifier = ref.read(chatMessagesProvider.notifier);
  final isImageRegeneration = assistantHasNormalizedImageFiles(targetAssistant);
  final previousImageGenerationEnabled = ref.read(
    imageGenerationEnabledProvider,
  );
  var mutatedState = false;

  try {
    if (truncatedMessages.length != originalMessages.length) {
      notifier.setMessages(truncatedMessages);
      mutatedState = true;
    }

    notifier.updateLastMessageWithFunction((ChatMessage message) {
      final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
      metadata['archivedVariant'] = true;
      return message.copyWith(metadata: metadata, isStreaming: false);
    });
    mutatedState = true;

    if (isImageRegeneration) {
      ref.read(imageGenerationEnabledProvider.notifier).set(true);
    }

    await regenerateMessage(ref, targetUser.content, targetUser.attachmentIds);
  } catch (error, stackTrace) {
    _cancelPendingHistoricalRegeneration(
      ref: ref,
      api: ref.read(apiServiceProvider),
    );
    if (mutatedState) {
      notifier.setMessages(originalMessages);
    }
    Error.throwWithStackTrace(error, stackTrace);
  } finally {
    if (isImageRegeneration) {
      ref
          .read(imageGenerationEnabledProvider.notifier)
          .set(previousImageGenerationEnabled);
    }
  }
}

void _cancelPendingHistoricalRegeneration({
  required dynamic ref,
  required ApiService? api,
}) {
  final messages = ref.read(chatMessagesProvider);
  if (messages.isEmpty) {
    return;
  }

  final lastMessage = messages.last;
  if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
    return;
  }

  stopActiveTransport(lastMessage, api);
  ref.read(chatMessagesProvider.notifier).cancelActiveMessageStream();
  ref.read(chatMessagesProvider.notifier).finishStreaming();
}
