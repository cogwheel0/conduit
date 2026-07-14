import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/services/api_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../providers/chat_providers.dart';
import '../services/chat_transport_dispatch.dart';
import '../utils/message_targeting.dart';

final _historicalRegenerationRegistryProvider =
    Provider<_HistoricalRegenerationRegistry>(
      (_) => _HistoricalRegenerationRegistry(),
    );

final class _HistoricalRegenerationRegistry {
  final Map<_HistoricalRegenerationOwnerKey, _HistoricalRegenerationMutation>
  _activeByConversation =
      <_HistoricalRegenerationOwnerKey, _HistoricalRegenerationMutation>{};

  _HistoricalRegenerationMutation? tryBegin({
    required dynamic ref,
    required ChatMutationOwnerToken mutationOwner,
    required String assistantMessageId,
  }) {
    // The archived target is deliberately left non-streaming while provider
    // preflight runs, so the ordinary isChatStreaming guard cannot prevent a
    // rapid second tap. Block only an operation that still owns its exact
    // preparation state. A navigation-away/back reload can reuse the same chat
    // id while replacing that state; the new replay must displace the stale
    // operation so the latter cannot reacquire ownership later.
    for (final active in _activeByConversation.values) {
      if (active.ownsAdmission(ref, this)) {
        return null;
      }
    }

    final ownerKey = _HistoricalRegenerationOwnerKey.from(mutationOwner);
    final mutation = _HistoricalRegenerationMutation(
      mutationOwner: mutationOwner,
      ownerKey: ownerKey,
      assistantMessageId: assistantMessageId,
    );
    _activeByConversation[ownerKey] = mutation;
    return mutation;
  }

  bool isCurrent(_HistoricalRegenerationMutation mutation) =>
      identical(_activeByConversation[mutation.ownerKey], mutation);

  void release(_HistoricalRegenerationMutation mutation) {
    if (isCurrent(mutation)) {
      _activeByConversation.remove(mutation.ownerKey);
    }
  }
}

final class _HistoricalRegenerationOwnerKey {
  const _HistoricalRegenerationOwnerKey({
    required this.ownerConversationId,
    required this.usesOpenWebUiContext,
    required this.openWebUiDatabase,
    required this.openWebUiApi,
    required this.openWebUiAuthSessionEpoch,
  });

  factory _HistoricalRegenerationOwnerKey.from(ChatMutationOwnerToken token) =>
      _HistoricalRegenerationOwnerKey(
        ownerConversationId: token.ownerConversationId,
        usesOpenWebUiContext: token.usesOpenWebUiContext,
        openWebUiDatabase: token.openWebUiDatabase,
        openWebUiApi: token.openWebUiApi,
        openWebUiAuthSessionEpoch: token.openWebUiAuthSessionEpoch,
      );

  final String? ownerConversationId;
  final bool usesOpenWebUiContext;
  final Object? openWebUiDatabase;
  final Object? openWebUiApi;
  final Object? openWebUiAuthSessionEpoch;

  @override
  bool operator ==(Object other) =>
      other is _HistoricalRegenerationOwnerKey &&
      other.ownerConversationId == ownerConversationId &&
      other.usesOpenWebUiContext == usesOpenWebUiContext &&
      identical(other.openWebUiDatabase, openWebUiDatabase) &&
      identical(other.openWebUiApi, openWebUiApi) &&
      identical(other.openWebUiAuthSessionEpoch, openWebUiAuthSessionEpoch);

  @override
  int get hashCode => Object.hash(
    ownerConversationId,
    usesOpenWebUiContext,
    identityHashCode(openWebUiDatabase),
    identityHashCode(openWebUiApi),
    identityHashCode(openWebUiAuthSessionEpoch),
  );
}

final class _HistoricalRegenerationMutation {
  _HistoricalRegenerationMutation({
    required this.mutationOwner,
    required this.ownerKey,
    required this.assistantMessageId,
  });

  final ChatMutationOwnerToken mutationOwner;
  final _HistoricalRegenerationOwnerKey ownerKey;
  final String assistantMessageId;
  List<ChatMessage>? _ownedPostArchivePrefix;

  void capturePostArchivePrefix(List<ChatMessage> messages) {
    _ownedPostArchivePrefix = List<ChatMessage>.unmodifiable(messages);
  }

  bool ownsContext(dynamic ref, _HistoricalRegenerationRegistry registry) {
    if (!registry.isCurrent(this)) return false;
    return chatMutationTokenStillActive(ref, mutationOwner);
  }

  bool ownsAdmission(dynamic ref, _HistoricalRegenerationRegistry registry) {
    if (!ownsContext(ref, registry)) return false;
    final ownedPostArchivePrefix = _ownedPostArchivePrefix;
    // There is no event-loop yield before capture, but retaining the lock in
    // this tiny synchronous window also protects re-entrant provider listeners.
    if (ownedPostArchivePrefix == null) return true;
    final current = ref.read(chatMessagesProvider) as List<ChatMessage>;
    return historicalRegenerationStateMatchesForTesting(
      current: current,
      ownedPostArchivePrefix: ownedPostArchivePrefix,
      assistantMessageId: assistantMessageId,
    );
  }

  bool ownsCurrentState(dynamic ref, _HistoricalRegenerationRegistry registry) {
    if (!ownsContext(ref, registry)) return false;

    final ownedPostArchivePrefix = _ownedPostArchivePrefix;
    if (ownedPostArchivePrefix == null) return false;
    final current = ref.read(chatMessagesProvider) as List<ChatMessage>;
    return historicalRegenerationStateMatchesForTesting(
      current: current,
      ownedPostArchivePrefix: ownedPostArchivePrefix,
      assistantMessageId: assistantMessageId,
    );
  }
}

@visibleForTesting
bool historicalRegenerationStateMatchesForTesting({
  required List<ChatMessage> current,
  required List<ChatMessage> ownedPostArchivePrefix,
  required String assistantMessageId,
}) {
  if (ownedPostArchivePrefix.isEmpty ||
      current.length != ownedPostArchivePrefix.length) {
    return false;
  }

  final ownedTarget = ownedPostArchivePrefix.last;
  if (ownedTarget.id != assistantMessageId ||
      ownedTarget.role != 'assistant' ||
      ownedTarget.metadata?['archivedVariant'] != true) {
    return false;
  }

  // The entire archived prefix is immutable ownership state.
  // Comparing the complete value (Freezed uses deep collection equality) keeps
  // a late failure from rolling back a same-id edit, metadata update, or status
  // update that landed while regeneration was preparing its transport.
  for (var index = 0; index < ownedPostArchivePrefix.length; index++) {
    if (current[index] != ownedPostArchivePrefix[index]) {
      return false;
    }
  }

  // Once any transport appends or replaces an assistant, its expected output
  // and an independent same-id mutation are no longer distinguishable. Fail
  // closed and preserve that state; only the exact synchronous archive mutation
  // is safe to roll back.
  return true;
}

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
  final activeAtStart = ref.read(activeConversationProvider);
  final mutationOwner = captureChatMutationOwner(ref, activeAtStart);
  final mutationRegistry = ref.read(_historicalRegenerationRegistryProvider);
  final notifier = ref.read(chatMessagesProvider.notifier);
  final isImageRegeneration = assistantHasNormalizedImageFiles(targetAssistant);
  final mutation = mutationRegistry.tryBegin(
    ref: ref,
    mutationOwner: mutationOwner,
    assistantMessageId: assistantMessageId,
  );
  if (mutation == null) {
    DebugLogger.log(
      'historical regenerate blocked while another replay is preparing',
      scope: 'chat/regeneration',
      data: {'assistantMessageId': assistantMessageId},
    );
    return;
  }
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
    mutation.capturePostArchivePrefix(
      ref.read(chatMessagesProvider) as List<ChatMessage>,
    );

    await regenerateMessage(
      ref,
      targetUser.content,
      targetUser.attachmentIds,
      forceImageGeneration: isImageRegeneration,
      ownsPreparationState: () =>
          mutation.ownsCurrentState(ref, mutationRegistry),
    );
  } catch (error, stackTrace) {
    final ownsMutation =
        mutatedState && mutation.ownsCurrentState(ref, mutationRegistry);
    if (ownsMutation) {
      _cancelPendingHistoricalRegeneration(
        ref: ref,
        api: ref.read(apiServiceProvider),
      );
      notifier.setMessages(originalMessages);
    } else if (mutatedState) {
      DebugLogger.log(
        'historical regeneration recovery skipped after ownership changed',
        scope: 'chat/regeneration',
        data: {'assistantMessageId': assistantMessageId},
      );
    }
    Error.throwWithStackTrace(error, stackTrace);
  } finally {
    mutationRegistry.release(mutation);
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
  ref
      .read(chatMessagesProvider.notifier)
      .cancelActiveMessageStreamPreservingContent();
  ref
      .read(chatMessagesProvider.notifier)
      .finishStreamingMessage(lastMessage.id);
}
