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

/// The newest assistant still streaming among the answers that end [messages].
/// A single-answer turn has just one candidate, the last message.
ChatMessage? _trailingStreamingAssistant(List<ChatMessage> messages) {
  for (var index = messages.length - 1; index >= 0; index -= 1) {
    final message = messages[index];
    if (message.role != 'assistant') return null;
    if (message.isStreaming) return message;
  }
  return null;
}

// Stop generation provider
final stopGenerationProvider = Provider<void Function()>((ref) {
  return () => unawaited(_stopGeneration(ref));
});

/// Stops the Open WebUI response the visible chat is streaming and completes
/// once that is settled: the transport and the server's task for the chat are
/// told to stop, and a requestCompletion that has not started is removed. The
/// result is whether all of that was accepted.
///
/// A response that is not streaming has nothing to stop. A Direct or Hermes
/// response belongs to another transport, which this does not stop, so it is
/// reported as not stopped; neither is ever touched from here.
///
/// A model comparison has one response per model, and any of them may be the
/// one still running, so the check covers every answer that ends the transcript
/// and not only the last.
Future<bool> stopOpenWebUiMainResponse(Ref ref) {
  final running = _trailingStreamingAssistant(ref.read(chatMessagesProvider));
  if (running == null) return Future<bool>.value(true);
  final transport = running.metadata?['transport'];
  if (transport == kDirectTransport || transport == kHermesTransport) {
    return Future<bool>.value(false);
  }
  return _stopGeneration(ref);
}

/// Every server-side effect of a stop is collected rather than abandoned, so a
/// caller that needs the cancellation to have happened can wait for it. The
/// synchronous part, and its order, is what the Stop button always did.
Future<bool> _stopGeneration(Ref ref) {
  final settled = <Future<bool>>[];
  Future<bool> allSettled() async =>
      (await Future.wait(settled)).every((accepted) => accepted);
  var stoppedClientOwnedRun = false;
  var stoppedOpenWebUiRun = false;
  var hadStreamingAssistant = false;
  try {
    final messages = ref.read(chatMessagesProvider);
    // The tail of a multi-model turn may have finished while a sibling is
    // still streaming; stopping must still reach that sibling.
    final streamingTail = _trailingStreamingAssistant(messages);
    if (streamingTail != null) {
      hadStreamingAssistant = true;
      final last = streamingTail;

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
        stoppedOpenWebUiRun = true;
        settled.add(stopActiveTransport(last, api));
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
      // Every answer of a multi-model turn stops with it; none is left
      // spinning because it was not the list tail. Direct and Hermes runs
      // have no such turns and settle through their own dispatchers. The
      // server keeps their last checkpoint as running, so a caller that sends
      // the next turn waits for the settled rows to be stored, and does not
      // count the stop as done when they were not.
      if (stoppedOpenWebUiRun) {
        settled.add(
          ref
              .read(chatMessagesProvider.notifier)
              .settleTrailingStreamingAnswers(),
        );
      }
    }
  } catch (_) {}

  if (!hadStreamingAssistant) {
    unawaited(ref.read(hermesBusyTurnControllerProvider).stopRecoveredTurn());
    return Future<bool>.value(true);
  }

  // Client-owned direct and Hermes completions never create an OpenWebUI
  // completion task or requestCompletion outbox operation. Do not send a
  // broad server-side stop (or delete a queued completion) for an unrelated
  // OpenWebUI generation that happens to share the transcript.
  if (stoppedClientOwnedRun) return Future<bool>.value(true);

  // Best-effort: stop any background tasks associated with this chat
  // (parity with web) — covers tasks not tracked via message metadata.
  try {
    final api = ref.read(apiServiceProvider);
    final activeConv = ref.read(activeConversationProvider);
    if (api != null && activeConv != null) {
      settled.add(() async {
        try {
          await api.stopTasksByChat(activeConv.id);
          return true;
        } catch (_) {
          return false;
        }
      }());

      // Drop any PENDING requestCompletion op for this chat so a stopped
      // turn is not re-driven by the next drain (W14). An inFlight op (the
      // stream already started) is left to the transport-cancel above.
      try {
        final db = ref.read(appDatabaseProvider);
        if (db != null) {
          final chatLocks = ref.read(chatLocksProvider);
          // The lock serializes against the drainer.
          settled.add(() async {
            try {
              await chatLocks.runExclusive(
                activeConv.id,
                () => db.chatsDao.cancelPendingCompletion(activeConv.id),
              );
              return true;
            } catch (_) {
              return false;
            }
          }());
        }
      } catch (_) {}
    }
  } catch (_) {}

  // Ensure UI transitions out of streaming state
  ref.read(chatMessagesProvider.notifier).finishStreaming();
  return allSettled();
}
