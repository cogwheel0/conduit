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
final regenerateLastMessageProvider = Provider<Future<void> Function()>(
  _regenerateLastMessage,
);

Future<void> Function() _regenerateLastMessage(Ref ref) {
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

    final question = lastUserMessage;
    final notifier = ref.read(chatMessagesProvider.notifier);
    // The marker below holds stored copies of the chat off only while the
    // regeneration prepares; one that gives up leaves the answer to them.
    await notifier.whileRegenerationPrepares(() async {
      // Mark previous assistant as an archived variant so UI can hide it
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
          question.content,
          question.attachmentIds,
          forceImageGeneration: true,
        );
        return;
      }

      // Text regeneration without duplicating user message
      await regenerateMessage(ref, question.content, question.attachmentIds);
    });
  };
}

/// The newest assistant still streaming among the answers that end [messages].
/// A single-answer turn has just one candidate, the last message.
/// The newest answer streaming in the turn that ends [messages]; with
/// [writtenBy], the newest that account wrote.
ChatMessage? _trailingStreamingAssistant(
  List<ChatMessage> messages, {
  String? writtenBy,
}) {
  for (var index = messages.length - 1; index >= 0; index -= 1) {
    final message = messages[index];
    if (message.role != 'assistant') return null;
    if (message.isStreaming && message.isWrittenBy(writtenBy)) return message;
  }
  return null;
}

/// The task ids of this account's answers still running at the end of
/// [messages]: the ones a Stop ends, and whether those are all of them. An
/// answer with no task id of its own, or another unfinished answer of this
/// account's beside one ([versionsOf], which may list the answer itself),
/// leaves them unknown.
({Set<String> ids, bool known}) _tasksOfRunningAnswers(
  List<ChatMessage> messages,
  String? userId,
  List<String> Function(String messageId) versionsOf,
) {
  final ids = <String>{};
  var known = true;
  for (final message in messages.reversed) {
    if (message.role != 'assistant') break;
    if (versionsOf(message.id).any((id) => id != message.id)) known = false;
    if (!message.isStreaming || !message.isWrittenBy(userId)) continue;
    final taskId = message.metadata?['taskId'];
    if (taskId is String && taskId.isNotEmpty) {
      ids.add(taskId);
    } else {
      known = false;
    }
  }
  return (ids: ids, known: known && ids.isNotEmpty);
}

/// A Stop the server refused, or never answered, asked again; whether it is
/// done with. Only an administrator may stop a single task, so it is asked
/// through the chat's stop, which ends every task the account runs in the
/// chat, and with none running finishes the account's unfinished answers,
/// rejecting a tool call one waits on. Another device may answer there by
/// now, so it is asked only while nothing but [own] runs, and with nothing
/// running, while no answer of [userId]'s waits for a tool's approval on any
/// branch of the chat as the server stores it.
/// With [own] gone and another's task running, nothing is left to stop, and
/// the answers' stored update finishes them once the chat runs no task.
/// Otherwise it stays owed.
///
/// Every request goes as the session the ask starts under, the one that owes
/// the Stop: once another has replaced it, none is sent, and the Stop stays
/// owed.
Future<bool> _askStopAgain(
  ApiService api,
  String chatId,
  ({Set<String> ids, bool known}) own,
  String? userId,
) {
  final session = api.captureAuthSnapshot();
  // The chat's stop ends every task the account runs there, one a request
  // sent after the task list was read would start among them.
  return api.holdingChatCompletions(chatId, () async {
    Future<bool> stopChat() async {
      if (!api.authSnapshotIsCurrent(session)) return false;
      await api.stopChatTasksRaw(chatId, authSnapshot: session);
      return true;
    }

    final running = await api.getChatTaskIdsRaw(chatId, authSnapshot: session);
    if (!api.authSnapshotIsCurrent(session)) return false;
    if (running.isEmpty) {
      // Open WebUI stores no temporary chat, and answers a read of one 401 as
      // it does a refused session; its stop there finishes no stored answer.
      if (!isTemporaryChat(chatId)) {
        final chat = await api.getChatRaw(chatId, authSnapshot: session);
        if (openWebUiChatStopRejectsPrompt(chat, userId: userId)) return false;
      }
      return stopChat();
    }
    if (!own.known) return false;
    if (running.every(own.ids.contains)) return stopChat();
    return !running.any(own.ids.contains);
  });
}

/// Whether the signed-in account may stop a single Open WebUI task by its
/// id: `POST /api/tasks/stop/{id}` is for administrators only.
bool _maySingleTasksBeStopped(dynamic ref) =>
    (ref.read(currentUserProvider2) as User?)?.role == 'admin';

/// Stops [taskIds], the tasks of one Open WebUI request that ended badly
/// here, by their ids, as [session]. No one pressed Stop for them, so they
/// are never stopped through the chat: that would end every task the account
/// runs there and finish its other unfinished answers. Unless the account is
/// an [administrator], they run on. It never fails, and reports nothing.
Future<void> _stopRequestTasksQuietly(
  ApiService? api, {
  required bool administrator,
  required Iterable<String> taskIds,
  required ApiAuthSnapshot? session,
}) async {
  final ids = taskIds.where((id) => id.isNotEmpty).toSet();
  if (api == null || ids.isEmpty) return;
  if (!administrator) {
    DebugLogger.log(
      'request-tasks-left-running',
      scope: 'chat/stop',
      data: {'tasks': ids.length},
    );
    return;
  }
  final asked = session ?? api.captureAuthSnapshot();
  for (final id in ids) {
    if (!api.authSnapshotIsCurrent(asked)) return;
    try {
      await api.stopTaskRaw(id, authSnapshot: asked);
    } catch (error) {
      // A refusal is a task that could not be stopped, never one that was.
      DebugLogger.log(
        'request-task-not-stopped',
        scope: 'chat/stop',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }
}

// Stop generation provider
final stopGenerationProvider = Provider<void Function()>(_stopGenerationAction);

void Function() _stopGenerationAction(Ref ref) =>
    () => unawaited(_stopGeneration(ref));

/// Stops what the open chat is answering, as [stopGenerationProvider] does,
/// and completes once the stop has settled, with whether it was accepted.
final stopGenerationSettledProvider = Provider<Future<bool> Function()>(
  _stopGenerationSettledAction,
);

Future<bool> Function() _stopGenerationSettledAction(Ref ref) =>
    () => _stopGeneration(ref);

/// Stops the Open WebUI response the visible chat is streaming and completes
/// once that is settled: the transport and the server's task for the chat are
/// told to stop, and a requestCompletion that has not started is removed. The
/// result is whether all of that was accepted.
///
/// A response that is not streaming has nothing new to stop. An earlier Stop
/// settles the visible answers before the server answers, so when its
/// cancellation is still pending or was refused for this chat and sign-in, that
/// one is what is waited for and asked again. A Direct or Hermes response
/// belongs to another transport, which this does not stop, so it is reported as
/// not stopped; neither is ever touched from here.
///
/// A model comparison has one response per model, and any of them may be the
/// one still running, so the check covers every answer that ends the transcript
/// and not only the last.
Future<bool> stopOpenWebUiMainResponse(Ref ref) {
  final running = _trailingStreamingAssistant(ref.read(chatMessagesProvider));
  if (running != null && !_goesToOpenWebUi(running)) {
    return Future<bool>.value(false);
  }
  if (running == null) {
    final active = ref.read(activeConversationProvider);
    return active == null
        ? Future<bool>.value(true)
        : ref
                  .read(chatMessagesProvider.notifier)
                  .settlePendingCancellation(
                    chatId: active.id,
                    database: _readAppDatabaseOrNull(ref),
                    api: _readApiServiceOrNull(ref),
                    authSessionEpoch: _readOpenWebUiAuthSessionEpoch(ref),
                  ) ??
              Future<bool>.value(true);
  }
  return _stopGeneration(ref);
}

/// Whether [reply] streams from the Open WebUI server: not a Direct (or
/// Apple), Hermes or LibreChat run, whatever stores the chat.
bool _goesToOpenWebUi(ChatMessage reply) {
  final transport = reply.metadata?['transport'];
  return transport != kDirectTransport &&
      transport != kHermesTransport &&
      transport != kLibreChatTransport;
}

/// Whether the server runs a task for [chatId], as its list of the account's
/// tasks says: null when that is not asked (a temporary chat, or an [answer]
/// that never had a task) or cannot be read.
Future<bool?> _openWebUiTaskRuns(
  ApiService? api,
  String chatId,
  ChatMessage answer,
) {
  final metadata = answer.metadata;
  if (api == null ||
      chatId.isEmpty ||
      isTemporaryChat(chatId) ||
      (metadata?['taskId'] == null &&
          metadata?['taskConversationId'] == null)) {
    return Future<bool?>.value();
  }
  return api
      .getTaskIdsByChat(chatId)
      .then<bool?>((ids) => ids.isNotEmpty, onError: (Object _) => null);
}

/// [stopOpenWebUiMainResponse] for the chat this provider's container has
/// open: a chat session scope's own, in a scope ([chatSessionScopeOverrides]).
final stopOpenWebUiMainResponseProvider = Provider<Future<bool> Function()>(
  _stopOpenWebUiMainResponseAction,
);

Future<bool> Function() _stopOpenWebUiMainResponseAction(Ref ref) =>
    () => stopOpenWebUiMainResponse(ref);

/// Whether the chat this provider's container has open is streaming a reply
/// from the Open WebUI server, by the running turn's transport rather than
/// the chat's storage, as [stopOpenWebUiMainResponse] decides: a Direct,
/// Apple, Hermes or LibreChat reply does not count, whatever stores the chat.
final openWebUiReplyStreamingProvider = Provider<bool>(
  _openWebUiReplyStreaming,
);

bool _openWebUiReplyStreaming(Ref ref) {
  final running = _trailingStreamingAssistant(ref.watch(chatMessagesProvider));
  return running != null && _goesToOpenWebUi(running);
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
  // This account's Open WebUI answer that was stopped, whether the server ran
  // a task for the chat as Stop was pressed, and the asks that stop it on
  // the server: the answer is kept once they are answered.
  String? stoppedAnswerId;
  String? stoppedTaskChatId;
  var taskRan = Future<bool?>.value();
  final serverStops = <Future<bool>>[];
  // The chat whose stop the stopped answer's own stop asks, and that ask.
  ({String chatId, Future<bool> taken})? answerStopsChat;
  // The server-side effects of this stop, kept so that a refusal can be asked
  // again after the visible answers have settled (see [_oweCancellation]).
  final cancellation = <_CancellationStep>[];
  final stoppedChatId = ref.read(activeConversationProvider)?.id ?? '';
  // Stop ends this account's answers alone. In a chat shared with Allow
  // replies another person's answer can run in the same turn, even as the one
  // shown: only they can stop it, so it is neither stopped nor settled here,
  // and the chat keeps following it. The server's stop of the chat's tasks
  // ends this account's tasks alone.
  final userId = ref.read(currentUserProvider2)?.id;
  bool othersAnswerRunsLast() {
    final tail = ref.read(chatMessagesProvider).lastOrNull;
    return tail != null &&
        tail.role == 'assistant' &&
        tail.isStreaming &&
        !tail.isWrittenBy(userId);
  }

  Future<bool> cancelOnServer(
    Future<bool> Function(String chatId) run, {
    bool chatScoped = false,
    Future<bool> Function(String chatId)? retry,
  }) {
    final step = _CancellationStep(run, chatScoped: chatScoped, retry: retry);
    cancellation.add(step);
    return step.attempt(stoppedChatId);
  }

  // The tasks of the answers this Stop ends, and one ask again for every step
  // of it at a time.
  final stopping = ref.read(chatMessagesProvider.notifier);
  final ownTasks = _tasksOfRunningAnswers(
    ref.read(chatMessagesProvider),
    userId,
    (messageId) => stopping._answersThisAccountRuns(inMessage: messageId),
  );
  Future<bool>? askingAgain;
  Future<bool> Function(String chatId)? askAgainWith(ApiService? api) =>
      api == null
      ? null
      : (chatId) => askingAgain ??= _askStopAgain(
          api,
          chatId,
          ownTasks,
          userId,
        ).whenComplete(() => askingAgain = null);

  try {
    final messages = ref.read(chatMessagesProvider);
    // The tail of a multi-model turn may have finished while a sibling is
    // still streaming; stopping must still reach that sibling.
    final streamingTail = _trailingStreamingAssistant(messages);
    if (streamingTail != null) {
      hadStreamingAssistant = true;
      final last = _trailingStreamingAssistant(messages, writtenBy: userId);

      if (last == null) {
        // Only another person's answers show running. Stop was offered for
        // this account's among their versions, which the chat's stop ends.
        stoppedOpenWebUiRun = true;
      } else if (last.metadata?['transport'] == kDirectTransport) {
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
        _observeDetachedCancellation(stop, scope: 'direct-connections/cancel');
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
      } else if (last.metadata?['transport'] == kLibreChatTransport ||
          isLibreChatConversation(ref.read(activeConversationProvider))) {
        stoppedClientOwnedRun = true;
        // The server keeps generating whether or not anyone listens; only
        // its abort stops the reply, and its final frame settles it here.
        final stop = _stopLibreChatTurn(ref, last);
        _observeDetachedCancellation(stop, scope: 'librechat/cancel');
        if (stop == null) {
          final Conversation? active = ref.read(activeConversationProvider);
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
      } else {
        final api = ref.read(apiServiceProvider);

        // Use transport-aware stop which inspects message metadata to
        // choose the right cancellation path (abort handle, task stop, or
        // both).
        stoppedOpenWebUiRun = true;
        stoppedAnswerId = last.id;
        stoppedTaskChatId = last.metadata?['taskConversationId']?.toString();
        // Asked before the server is told to stop: only a task running then
        // saves the stopped answer itself.
        final lookup = taskRan = _openWebUiTaskRuns(api, stoppedChatId, last);
        final transportStop = cancelOnServer(
          (_) => stopActiveTransport(last, api, beforeTaskStop: lookup),
          retry: askAgainWith(api),
        );
        serverStops.add(transportStop);
        settled.add(transportStop);
        final taskChatId = last.metadata?['taskConversationId']?.toString();
        if (taskChatId != null && taskChatId.isNotEmpty) {
          answerStopsChat = (chatId: taskChatId, taken: transportStop);
        }
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

      // Cancel local stream subscription to stop propagating further chunks.
      // Another person's answer at the end is what it follows, and runs on.
      if (!othersAnswerRunsLast()) {
        ref
            .read(chatMessagesProvider.notifier)
            .cancelActiveMessageStreamPreservingContent();
      }
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
      final lookup = taskRan;
      final answerStop = answerStopsChat;
      final chatStop = cancelOnServer(
        (chatId) async {
          // The answer's own stop asks this chat's stop already.
          if (answerStop?.chatId == chatId) return answerStop!.taken;
          await lookup;
          await api.stopTasksByChat(chatId);
          return true;
        },
        chatScoped: true,
        retry: askAgainWith(api),
      );
      serverStops.add(chatStop);
      settled.add(chatStop);
      // Its stops of the chat end every task the account runs there: a
      // request sent there before they are answered waits for them.
      final asked = Future.wait(serverStops);
      for (final chatId in {activeConv.id, ?stoppedTaskChatId}) {
        if (chatId.isEmpty) continue;
        unawaited(api.holdingChatCompletions(chatId, () => asked));
      }
      final stopped = stoppedAnswerId;
      if (stopped != null) {
        settled.add(
          ref
              .read(chatMessagesProvider.notifier)
              ._keepStoppedAnswerText(
                stopped,
                api: api,
                taskRan: taskRan,
                serverStopped: Future.wait(serverStops),
              ),
        );
      }
      // The stop is owed to the chat, store, sign-in and server it was asked
      // under until the server has accepted all of it. Everything above ran in
      // this one synchronous turn, so nothing can read the settled answers
      // before this is recorded.
      ref
          .read(chatMessagesProvider.notifier)
          ._oweCancellation(
            owner: captureChatMutationOwner(ref, activeConv),
            chatId: activeConv.id,
            steps: cancellation,
          );

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

  // Ensure UI transitions out of streaming state, unless another person's
  // answer still runs at the end.
  if (!othersAnswerRunsLast()) {
    ref.read(chatMessagesProvider.notifier).finishStreaming();
  }
  return allSettled();
}
