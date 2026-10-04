part of 'chat_providers.dart';

/// Whether [message] is an assistant message whose normalized [files]
/// contain at least one image entry (`type == 'image'`).
///
/// Used by the regeneration path to decide whether to force
/// `imageGenerationEnabled` during replay.
bool assistantHasNormalizedImageFiles(ChatMessage message) {
  if (message.role != 'assistant') return false;
  final files = message.files;
  if (files == null || files.isEmpty) return false;
  return files.any((f) => f['type'] == 'image');
}

// Regenerate last message
final regenerateLastMessageProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final messages = ref.read(chatMessagesProvider);
    if (messages.length < 2) return;

    // Find last user message with proper bounds checking
    ChatMessage? lastUserMessage;
    // Detect if last assistant message had generated images
    final ChatMessage? lastAssistantMessage = messages.isNotEmpty
        ? messages.last
        : null;
    final bool lastAssistantHadImages =
        lastAssistantMessage != null &&
        assistantHasNormalizedImageFiles(lastAssistantMessage);
    for (int i = messages.length - 2; i >= 0 && i < messages.length; i--) {
      if (i >= 0 && messages[i].role == 'user') {
        lastUserMessage = messages[i];
        break;
      }
    }

    if (lastUserMessage == null) return;

    // Mark previous assistant as an archived variant so UI can hide it
    final notifier = ref.read(chatMessagesProvider.notifier);
    if (lastAssistantMessage != null) {
      notifier.updateLastMessageWithFunction((m) {
        final meta = Map<String, dynamic>.from(m.metadata ?? const {});
        meta['archivedVariant'] = true;
        // Keep content/files intact for server persistence
        return m.copyWith(metadata: meta, isStreaming: false);
      });
    }

    // If previous assistant was image-only or had images, regenerate images instead of text
    if (lastAssistantHadImages) {
      // This is a request property, not a user preference. Keeping the force
      // flag local prevents replay from writing settings or racing a user's
      // toggle change while provider preflight is in flight.
      await regenerateMessage(
        ref,
        lastUserMessage.content,
        lastUserMessage.attachmentIds,
        forceImageGeneration: true,
      );
      return;
    }

    // Text regeneration without duplicating user message
    await regenerateMessage(
      ref,
      lastUserMessage.content,
      lastUserMessage.attachmentIds,
    );
  };
});

// Stop generation provider
final stopGenerationProvider = Provider<void Function()>((ref) {
  return () {
    var stoppedClientOwnedRun = false;
    var hadStreamingAssistant = false;
    try {
      final messages = ref.read(chatMessagesProvider);
      if (messages.isNotEmpty &&
          messages.last.role == 'assistant' &&
          messages.last.isStreaming) {
        hadStreamingAssistant = true;
        final last = messages.last;

        if (last.metadata?['transport'] == kDirectTransport) {
          // Transport metadata remains authoritative after process death even
          // though the process-local registry is empty. Never let an orphaned
          // direct checkpoint fall through to an unrelated OpenWebUI stop.
          stoppedClientOwnedRun = true;
          final registry = ref.read(directRunRegistryProvider);
          final Conversation? active = ref.read(activeConversationProvider);
          final owner = active == null
              ? _pendingDirectRunOwner(last.id)
              : _directRunOwnerScopeForConversation(ref, active);
          final key = _directRunKeyForOwner(owner, last.id);
          var cancellationKey = key;
          var resolvedByMessageIdentity = false;
          var hadActiveRun = registry.runFor(cancellationKey) != null;
          var stop = registry.cancel(cancellationKey);
          if (stop == null) {
            final candidates = ref
                .read(_directRunStopIndexProvider)
                .keysForMessage(last.id)
                .where(registry.hasLiveIntent)
                .toList(growable: false);
            if (candidates.length == 1) {
              cancellationKey = candidates.single;
              resolvedByMessageIdentity = true;
              hadActiveRun = registry.runFor(cancellationKey) != null;
              stop = registry.cancel(cancellationKey);
            }
          }
          _observeDetachedCancellation(
            stop,
            scope: 'direct-connections/cancel',
          );
          // A registered dispatcher owns final rendering from its accumulator,
          // including reasoning `done=true`. A preflight reservation has no
          // dispatcher, so its empty optimistic placeholder is completed here.
          if (stop != null && (!hadActiveRun || resolvedByMessageIdentity)) {
            ref
                .read(chatMessagesProvider.notifier)
                .completeStoppedDirectStreamingUi(last.id);
          } else if (stop == null) {
            ref
                .read(chatMessagesProvider.notifier)
                .finishStreamingMessage(
                  last.id,
                  ownerConversationId: active == null
                      ? null
                      : chatMutationOwnerScopeForConversation(active),
                  requireConversationOwner: true,
                  persistTurn: false,
                );
          }
        } else if (last.metadata?['transport'] == kHermesTransport) {
          stoppedClientOwnedRun = true;
          // The registry owns the service/origin that created this run.
          final Conversation? active = ref.read(activeConversationProvider);
          final registry = ref.read(hermesRunRegistryProvider);
          final stop = active == null
              ? registry.cancelMessage(last.id)
              : registry.cancel(
                  hermesRunKeyForConversation(
                    ref,
                    conversation: active,
                    assistantMessageId: last.id,
                  ),
                );
          _observeDetachedCancellation(stop, scope: 'hermes/cancel');
          if (stop == null) {
            // A restored placeholder may outlive its registry generation (for
            // example after process death or a provenance/key migration). It
            // still belongs to the client transport, so settle only this exact
            // visible row locally rather than falling through to an unrelated
            // OpenWebUI task stop.
            ref
                .read(chatMessagesProvider.notifier)
                .finishStreamingMessage(
                  last.id,
                  ownerConversationId: active == null
                      ? null
                      : chatMutationOwnerScopeForConversation(active),
                  requireConversationOwner: true,
                );
          }
        } else {
          final api = ref.read(apiServiceProvider);

          // Use transport-aware stop which inspects message metadata to
          // choose the right cancellation path (abort handle, task stop, or
          // both).
          stopActiveTransport(last, api);
          final regenerationAttemptId =
              last.metadata?[_openWebUiRegenerationAttemptMetadataKey];
          if (regenerationAttemptId is String &&
              regenerationAttemptId.isNotEmpty) {
            _clearOpenWebUiRegenerationAttemptMarkerById(
              ref,
              assistantMessageId: last.id,
              attemptId: regenerationAttemptId,
            );
          }
        }

        // Cancel local stream subscription to stop propagating further chunks
        ref
            .read(chatMessagesProvider.notifier)
            .cancelActiveMessageStreamPreservingContent();
      }
    } catch (_) {}

    if (!hadStreamingAssistant) {
      unawaited(ref.read(hermesBusyTurnControllerProvider).stopRecoveredTurn());
      return;
    }

    // Client-owned direct and Hermes completions never create an OpenWebUI
    // completion task or requestCompletion outbox operation. Do not send a
    // broad server-side stop (or delete a queued completion) for an unrelated
    // OpenWebUI generation that happens to share the transcript.
    if (stoppedClientOwnedRun) return;

    // Best-effort: stop any background tasks associated with this chat
    // (parity with web) — covers tasks not tracked via message metadata.
    try {
      final api = ref.read(apiServiceProvider);
      final activeConv = ref.read(activeConversationProvider);
      if (api != null && activeConv != null) {
        unawaited(() async {
          try {
            await api.stopTasksByChat(activeConv.id);
          } catch (_) {}
        }());

        // Drop any PENDING requestCompletion op for this chat so a stopped
        // turn is not re-driven by the next drain (W14). An inFlight op (the
        // stream already started) is left to the transport-cancel above.
        try {
          final db = ref.read(appDatabaseProvider);
          if (db != null) {
            final chatLocks = ref.read(chatLocksProvider);
            // Fire-and-forget; the lock serializes against the drainer.
            // ignore: unawaited_futures
            chatLocks.runExclusive(
              activeConv.id,
              () => db.chatsDao.cancelPendingCompletion(activeConv.id),
            );
          }
        } catch (_) {}
      }
    } catch (_) {}

    // Ensure UI transitions out of streaming state
    ref.read(chatMessagesProvider.notifier).finishStreaming();
  };
});
