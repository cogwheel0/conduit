part of 'chat_providers.dart';

/// A Hermes approval waiting in the chat for the user: the agent wants to run
/// a command or write a file, and stops until someone answers.
///
/// Read from the answer's `hermesApproval` metadata, where the run transport
/// puts it. A host shows it and answers through [resolveHermesApproval];
/// mobile's composer card does the same over its widget state.
final class HermesPendingApproval {
  const HermesPendingApproval._({
    required this.messageId,
    required this.approvalId,
    required this.runId,
    required this.choices,
    this.summary,
    this.executionGeneration,
    this.storedSessionId,
    this.restoredDesktopDecision = false,
    HermesApprovalRun? run,
  }) : _run = run;

  /// The assistant message the approval belongs to.
  final String messageId;
  final String approvalId;
  final String runId;

  /// What the agent wants to do, in its own words.
  final String? summary;

  /// The answers the server offers, from `once`, `session`, `always` and
  /// `deny`. Empty means a plain yes or no.
  final List<String> choices;

  /// The run execution that asked, which newer Hermes servers require back
  /// with the answer.
  final int? executionGeneration;

  /// The desktop gateway's session, when the approval came from one.
  final String? storedSessionId;

  /// Whether this approval was restored from the gateway when the chat was
  /// reopened, rather than asked by a run this process started.
  final bool restoredDesktopDecision;

  /// The run that asked, as it was when the approval was read. Null for a
  /// restored approval, which is answered through its gateway session.
  final HermesApprovalRun? _run;
}

/// The exact run an approval was read from. The answer goes to that run
/// alone: one that replaced it, even under the same message and run ids, is
/// not answered.
final class HermesApprovalRun {
  const HermesApprovalRun._({
    required this.key,
    required this.generationToken,
    required this.cancelToken,
  });

  final HermesRunKey key;
  final Object generationToken;
  final CancelToken cancelToken;
}

/// The approval [message], in the chat open in [ref], is waiting on, or null
/// when it is not waiting or the run that asked is no longer running.
///
/// A `resolving` approval is not returned: it is already being answered. The
/// run that asked is captured here, as mobile's approval card captures it
/// when it is drawn, so [resolveHermesApproval] answers that run and no run
/// that replaces it while the user decides.
HermesPendingApproval? pendingHermesApprovalOf(
  dynamic ref,
  ChatMessage message,
) {
  final metadata = message.metadata;
  if (metadata == null ||
      metadata['transport'] != kHermesTransport ||
      metadata['archivedVariant'] == true) {
    return null;
  }
  final approval = metadata[kHermesApprovalMeta];
  if (approval is! Map) return null;
  final state = approval['state'];
  if (state != null && state != 'pending') return null;
  final approvalId = approval['approvalId'];
  final runId = approval['runId'];
  if (approvalId is! String ||
      approvalId.isEmpty ||
      runId is! String ||
      runId.isEmpty) {
    return null;
  }
  final storedSessionId = approval['storedSessionId']?.toString();
  final restored = metadata['restoredDesktopDecision'] == true;
  if (restored && (storedSessionId == null || storedSessionId.isEmpty)) {
    return null;
  }
  HermesApprovalRun? run;
  if (!restored) {
    run = _hermesApprovalRunOf(ref, messageId: message.id, runId: runId);
    if (run == null) return null;
  }
  return HermesPendingApproval._(
    messageId: message.id,
    approvalId: approvalId,
    runId: runId,
    summary: approval['summary'] is String
        ? approval['summary'] as String
        : null,
    choices: switch (approval['choices']) {
      final List values =>
        values
            .whereType<String>()
            .where(const {'once', 'session', 'always', 'deny'}.contains)
            .take(4)
            .toList(growable: false),
      _ => const <String>[],
    },
    executionGeneration: approval['executionGeneration'] is int
        ? approval['executionGeneration'] as int
        : null,
    storedSessionId: storedSessionId == null || storedSessionId.isEmpty
        ? null
        : storedSessionId,
    restoredDesktopDecision: restored,
    run: run,
  );
}

/// The live run [runId] of answer [messageId] in the chat open in [ref].
HermesApprovalRun? _hermesApprovalRunOf(
  dynamic ref, {
  required String messageId,
  required String runId,
}) {
  final conversation = ref.read(activeConversationProvider) as Conversation?;
  if (conversation == null) return null;
  final registry = ref.read(hermesRunRegistryProvider) as HermesRunRegistry;
  final key = hermesRunKeyForConversation(
    ref,
    conversation: conversation,
    assistantMessageId: messageId,
  );
  final generationToken = registry.generationTokenFor(key, runId: runId);
  if (generationToken == null) return null;
  final cancelToken = registry.cancelTokenForGeneration(
    key,
    generationToken: generationToken,
    runId: runId,
  );
  if (cancelToken == null) return null;
  return HermesApprovalRun._(
    key: key,
    generationToken: generationToken,
    cancelToken: cancelToken,
  );
}

/// Answers [approval] with [choice] (`once`, `session`, `always` or `deny`)
/// for the chat open in [ref], and reports whether Hermes took the answer.
///
/// The same steps as mobile's approval card: the run read with the approval
/// must still be the one running (a replacement that reuses the message or
/// run id cannot receive the old run's answer), the approval moves from
/// `pending` to `resolving` while the answer is sent, and then to `approved`
/// or `denied`. A failed send puts it back to `pending`, unless Hermes said
/// the prompt is no longer waiting or belongs to an older execution: it is
/// then `settled`, since offering it again could only fail the same way. A
/// restored desktop approval is answered through its gateway session.
Future<bool> resolveHermesApproval(
  dynamic ref,
  HermesPendingApproval approval, {
  required String choice,
}) async {
  final approved = choice != 'deny';
  final service = ref.read(hermesApiServiceProvider) as HermesBackendService?;
  if (service == null) {
    DebugLogger.warning('approval-no-service', scope: 'chat/hermes_approval');
    return false;
  }
  final conversation = ref.read(activeConversationProvider) as Conversation?;
  if (conversation == null) return false;
  if (approval.restoredDesktopDecision) {
    return _resolveRestoredHermesDesktopApproval(
      ref,
      service: service,
      conversation: conversation,
      approval: approval,
      choice: choice,
    );
  }

  final run = approval._run;
  if (run == null) return false;
  final generationToken = run.generationToken;
  final registry = ref.read(hermesRunRegistryProvider) as HermesRunRegistry;
  final runKey = hermesRunKeyForConversation(
    ref,
    conversation: conversation,
    assistantMessageId: approval.messageId,
  );
  // The chat's key may have moved from a local id to the server's since.
  if (!registry.ownsGeneration(
        run.key,
        generationToken: generationToken,
        runId: approval.runId,
      ) &&
      (runKey == run.key ||
          !registry.ownsGeneration(
            runKey,
            generationToken: generationToken,
            runId: approval.runId,
          ))) {
    return false;
  }
  final capabilities = (ref.read(
    hermesCapabilitiesProvider,
  ) as AsyncValue<HermesCapabilities>).asData?.value;
  if (capabilities != null && !capabilities.runApproval) return false;

  final messagesNotifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  final updateProjectionState = captureHermesApprovalProjectionStateUpdater(
    ref,
    cancelToken: run.cancelToken,
    messageId: approval.messageId,
    runId: approval.runId,
    approvalId: approval.approvalId,
  );

  bool setState(String next, {required String expected}) {
    final projection = updateProjectionState(
      expectedState: expected,
      nextState: next,
    );
    if (projection.found && !projection.changed) return false;
    final current = ref.read(activeConversationProvider) as Conversation?;
    final currentKey = current == null
        ? null
        : hermesRunKeyForConversation(
            ref,
            conversation: current,
            assistantMessageId: approval.messageId,
          );
    final visibleOwnsGeneration =
        currentKey != null &&
        (projection.found
            ? currentKey == projection.key
            : registry.ownsGeneration(
                currentKey,
                generationToken: generationToken,
                runId: approval.runId,
              ));
    var visibleChanged = false;
    if (visibleOwnsGeneration) {
      messagesNotifier.updateMessageById(approval.messageId, (message) {
        if (message.metadata?['transport'] != kHermesTransport) return message;
        final metadata = Map<String, dynamic>.from(
          message.metadata ?? const {},
        );
        final stored = metadata[kHermesApprovalMeta];
        if (stored is! Map ||
            stored['approvalId'] != approval.approvalId ||
            stored['runId'] != approval.runId ||
            (stored['state'] ?? 'pending') != expected) {
          return message;
        }
        metadata[kHermesApprovalMeta] = {
          ...stored.cast<String, dynamic>(),
          'state': next,
        };
        visibleChanged = true;
        return message.copyWith(metadata: metadata);
      });
    }
    return projection.found ? projection.changed : visibleChanged;
  }

  if (!setState('resolving', expected: 'pending')) return false;
  try {
    final storedSessionId = approval.storedSessionId;
    if (service is HermesDesktopApiService && storedSessionId != null) {
      await service.resolveApprovalChoiceForSession(
        storedSessionId,
        approvalId: approval.approvalId,
        choice: choice,
      );
    } else if (service is HermesDesktopApiService) {
      await service.resolveApprovalChoice(
        approval.runId,
        approvalId: approval.approvalId,
        choice: choice,
      );
    } else if (service is HermesApiService) {
      await service.resolveApproval(
        approval.runId,
        approvalId: approval.approvalId,
        approved: approved,
        executionGeneration: approval.executionGeneration,
        // The scope picked (`session`, `always`) when the approval offered
        // it; otherwise once or deny.
        choice: approval.choices.contains(choice) ? choice : null,
      );
    } else {
      await service.resolveApproval(
        approval.runId,
        approvalId: approval.approvalId,
        approved: approved,
      );
    }
  } catch (error) {
    DebugLogger.error(
      'approval-resolve-failed',
      scope: 'chat/hermes_approval',
      data: {'errorType': error.runtimeType.toString()},
    );
    final settled =
        error is HermesApiException &&
        (error.code == HermesApiErrorCode.approvalNotPending ||
            error.code == HermesApiErrorCode.staleGeneration);
    setState(settled ? 'settled' : 'pending', expected: 'resolving');
    return false;
  }
  setState(approved ? 'approved' : 'denied', expected: 'resolving');
  return true;
}

Future<bool> _resolveRestoredHermesDesktopApproval(
  dynamic ref, {
  required HermesBackendService service,
  required Conversation conversation,
  required HermesPendingApproval approval,
  required String choice,
}) async {
  final storedSessionId = approval.storedSessionId;
  if (service is! HermesDesktopApiService || storedSessionId == null) {
    return false;
  }
  final configController =
      ref.read(hermesConfigProvider.notifier) as HermesConfigController;
  final admission = configController.captureSessionActionAdmission();
  bool ownsDecision() {
    if (!identical(ref.read(hermesApiServiceProvider), service)) return false;
    final active = ref.read(activeConversationProvider) as Conversation?;
    final activeStoredId = active?.metadata['hermesSessionId']?.toString();
    return active?.id == conversation.id &&
        activeStoredId != null &&
        service.sessionIdsReferToSameBinding(activeStoredId, storedSessionId);
  }

  if (admission == null || !ownsDecision()) return false;
  final messagesNotifier =
      ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier;
  bool update(String expected, String next) {
    var changed = false;
    messagesNotifier.updateMessageById(approval.messageId, (message) {
      final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
      final stored = metadata[kHermesApprovalMeta];
      if (stored is! Map ||
          stored['approvalId'] != approval.approvalId ||
          (stored['state'] ?? 'pending') != expected) {
        return message;
      }
      metadata[kHermesApprovalMeta] = <String, dynamic>{
        ...stored.cast<String, dynamic>(),
        'state': next,
      };
      changed = true;
      return message.copyWith(metadata: metadata);
    });
    return changed;
  }

  // Only the answer that moved it from pending is sent: another one already
  // under way owns it.
  if (!update('pending', 'resolving')) return false;
  try {
    await service.resolveApprovalChoiceForSession(
      storedSessionId,
      approvalId: approval.approvalId,
      choice: choice,
    );
  } catch (_) {
    if (ownsDecision()) update('resolving', 'pending');
    return false;
  }
  if (!configController.sessionActionAdmissionIsCurrent(admission) ||
      !ownsDecision()) {
    return false;
  }
  update('resolving', choice == 'deny' ? 'denied' : 'approved');
  return true;
}
