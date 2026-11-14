part of 'chat_providers.dart';

/// A question Hermes is waiting on in the chat: a clarify form (one or more
/// questions), a sudo password, a secret (an API key or a token), an MCP
/// server's set-up, or a plain reply with choices.
///
/// Read from the answer's `hermesDecision` metadata, where the run transport
/// puts it. A host shows it and answers through [answerHermesDecision];
/// mobile's composer card does the same.
final class HermesPendingDecision {
  const HermesPendingDecision({
    required this.messageId,
    required this.requestId,
    required this.runtimeId,
    required this.kind,
    required this.expiresAt,
    this.storedSessionId,
    this.prompt,
    this.choices = const <String>[],
    this.multiSelect = false,
    this.mcpServer,
    this.mcpAction,
    this.questions = const <HermesClarifyQuestion>[],
    this.executionGeneration,
  });

  /// The assistant message the question belongs to.
  final String messageId;
  final String requestId;
  final String runtimeId;
  final HermesDecisionKind kind;

  /// When Hermes stops waiting for the answer.
  final DateTime expiresAt;

  /// The gateway session it was asked in; null for a REST run's question.
  final String? storedSessionId;
  final String? prompt;

  /// A plain reply's choices (a clarification asked without question text).
  final List<String> choices;
  final bool multiSelect;
  final String? mcpServer;
  final String? mcpAction;

  /// A clarification's questions, answered as one form; empty for every
  /// other kind, and for a clarification asked without question text.
  final List<HermesClarifyQuestion> questions;

  /// A REST run's question: the execution it belongs to.
  final int? executionGeneration;

  /// Whether the answer is a form: every question with one Submit.
  bool get isForm =>
      kind == HermesDecisionKind.clarification && questions.isNotEmpty;

  /// Whether the answer must never be shown or kept: a password or a secret.
  bool get sensitive =>
      kind == HermesDecisionKind.sudo || kind == HermesDecisionKind.secret;
}

/// Whether [a] and [b] ask the same question of the same answer: the same
/// message, kind, prompt, choices, MCP server and form questions. The ids
/// Hermes keys the request by and its expiry are left out: a resumed session
/// replays its open requests under its new runtime (and may renew them), and
/// such a replay is the question already shown, not a new one. A question's
/// lock is left out too, as a lock does not make it another question.
bool hermesDecisionsAskTheSame(
  HermesPendingDecision a,
  HermesPendingDecision b,
) {
  bool sameList(List<String> x, List<String> y) {
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  if (a.messageId != b.messageId ||
      a.kind != b.kind ||
      (a.prompt?.trim() ?? '') != (b.prompt?.trim() ?? '') ||
      !sameList(a.choices, b.choices) ||
      a.multiSelect != b.multiSelect ||
      a.mcpServer != b.mcpServer ||
      a.mcpAction != b.mcpAction ||
      a.questions.length != b.questions.length) {
    return false;
  }
  for (var i = 0; i < a.questions.length; i++) {
    final (x, y) = (a.questions[i], b.questions[i]);
    if (x.id != y.id ||
        x.text != y.text ||
        x.multiSelect != y.multiSelect ||
        !sameList(x.choices, y.choices)) {
      return false;
    }
  }
  return true;
}

String? _nonEmptyDecisionString(Object? value) {
  final text = value?.toString();
  return text == null || text.isEmpty ? null : text;
}

/// The question [message] is waiting on, or null when it waits on none, it
/// has expired at [now], or it cannot be answered from here.
///
/// The same rules as mobile's composer card: a pending, unexpired request
/// with its request and runtime ids, asked in a gateway session (or a REST
/// run's clarification, answered by its run).
HermesPendingDecision? pendingHermesDecisionOf(
  ChatMessage message, {
  DateTime? now,
}) {
  final metadata = message.metadata;
  if (metadata == null ||
      metadata['archivedVariant'] == true ||
      metadata['transport'] != kHermesTransport) {
    return null;
  }
  final decision = metadata[kHermesDecisionMeta];
  if (decision is! Map || decision['state'] != 'pending') return null;
  final expiresAt = DateTime.tryParse(decision['expiresAt']?.toString() ?? '');
  if (expiresAt == null || !expiresAt.isAfter(now ?? clock.now().toUtc())) {
    return null;
  }
  final requestId = _nonEmptyDecisionString(decision['requestId']);
  final runtimeId = _nonEmptyDecisionString(decision['runtimeId']);
  if (requestId == null || runtimeId == null) return null;
  final kind = HermesDecisionKind.values.firstWhere(
    (value) => value.name == decision['kind'],
    orElse: () => HermesDecisionKind.clarification,
  );
  final storedSessionId =
      _nonEmptyDecisionString(decision['storedSessionId']) ??
      _nonEmptyDecisionString(metadata['hermesSessionId']);
  final runQuestion =
      metadata['restoredDesktopDecision'] != true &&
      kind == HermesDecisionKind.clarification &&
      decision['executionGeneration'] is int;
  if (storedSessionId == null && !runQuestion) return null;
  final questions = kind == HermesDecisionKind.clarification
      ? hermesClarifyQuestionsFromPayload(decision)
      : const <HermesClarifyQuestion>[];
  // A plain reply card needs the gateway session it answers through.
  if (questions.isEmpty && storedSessionId == null) return null;
  return HermesPendingDecision(
    messageId: message.id,
    requestId: requestId,
    runtimeId: runtimeId,
    kind: kind,
    expiresAt: expiresAt,
    storedSessionId: storedSessionId,
    prompt: decision['prompt']?.toString(),
    choices: switch (decision['choices']) {
      final List values => values.whereType<String>().toList(growable: false),
      _ => const <String>[],
    },
    multiSelect: decision['multiSelect'] == true,
    mcpServer: decision['mcpServer']?.toString(),
    mcpAction: decision['mcpAction']?.toString(),
    questions: questions,
    executionGeneration: decision['executionGeneration'] is int
        ? decision['executionGeneration'] as int
        : null,
  );
}

/// What answering a Hermes question came to.
enum HermesDecisionAnswerOutcome {
  /// Hermes took the answer; the question is closed.
  answered,

  /// Hermes had already settled it (answered elsewhere, or it expired); the
  /// question is closed and the answer was not sent.
  settled,

  /// The answer did not arrive, or the chat changed under it: the question
  /// stays open to be answered again.
  failed,
}

/// Answers [decision], asked in the chat [ownerConversationId] open in
/// [ref], as mobile's composer card does: a form with [answers] (question
/// id to answer, null to skip one), any other question with [value].
///
/// The answer goes only while the chat that asked is still the one open in
/// [ref] on the same connection, and [isCurrent] (the card still shown)
/// holds; once Hermes takes it, the question is marked resolved, which
/// closes its card.
Future<HermesDecisionAnswerOutcome> answerHermesDecision(
  dynamic ref,
  HermesPendingDecision decision, {
  required String ownerConversationId,
  String? value,
  Map<String, String?>? answers,
  bool Function()? isCurrent,
}) async {
  bool current() => isCurrent?.call() ?? true;
  if (!decision.expiresAt.isAfter(clock.now().toUtc())) {
    return HermesDecisionAnswerOutcome.failed;
  }
  final service = ref.read(hermesApiServiceProvider) as HermesBackendService?;
  final configController =
      ref.read(hermesConfigProvider.notifier) as HermesConfigController;
  final admission = configController.captureSessionActionAdmission();
  final storedSessionId = decision.storedSessionId;

  bool ownsDesktop(HermesDesktopApiService desktop) {
    if (!current() || !identical(ref.read(hermesApiServiceProvider), desktop)) {
      return false;
    }
    final active = ref.read(activeConversationProvider) as Conversation?;
    final activeStoredId = active?.metadata['hermesSessionId']?.toString();
    return storedSessionId != null &&
        active?.id == ownerConversationId &&
        activeStoredId != null &&
        desktop.sessionIdsReferToSameBinding(activeStoredId, storedSessionId);
  }

  bool owns() => switch (service) {
    final HermesDesktopApiService desktop => ownsDesktop(desktop),
    final HermesApiService rest =>
      current() &&
          identical(ref.read(hermesApiServiceProvider), rest) &&
          (ref.read(activeConversationProvider) as Conversation?)?.id ==
              ownerConversationId,
    _ => false,
  };

  if (decision.isForm) {
    if (admission == null || !owns()) return HermesDecisionAnswerOutcome.failed;
    final sent = answers ?? const <String, String?>{};
    try {
      switch (service) {
        case final HermesDesktopApiService desktop:
          await desktop.respondToClarifyForm(
            runtimeId: decision.runtimeId,
            storedSessionId: storedSessionId,
            requestId: decision.requestId,
            answers: sent,
          );
        case final HermesApiService rest
            when decision.executionGeneration != null:
          // A run's question takes one answer; empty skips it.
          await rest.answerClarify(
            decision.runtimeId,
            promptId: decision.requestId,
            executionGeneration: decision.executionGeneration!,
            answer: sent.values.firstOrNull ?? '',
          );
        default:
          return HermesDecisionAnswerOutcome.failed;
      }
    } on HermesDecisionAlreadySettled {
      // Answered elsewhere or expired: the card closes, and says the answer
      // was not sent.
      if (owns()) {
        closeHermesDecision(ref, decision.messageId, decision.requestId);
        return HermesDecisionAnswerOutcome.settled;
      }
      return HermesDecisionAnswerOutcome.failed;
    } catch (_) {
      DebugLogger.warning(
        'clarify-answer-failed',
        scope: 'chat/hermes_clarify',
      );
      return HermesDecisionAnswerOutcome.failed;
    }
    if (!configController.sessionActionAdmissionIsCurrent(admission) ||
        !owns()) {
      return HermesDecisionAnswerOutcome.failed;
    }
    closeHermesDecision(ref, decision.messageId, decision.requestId);
    return HermesDecisionAnswerOutcome.answered;
  }

  if (service is! HermesDesktopApiService || storedSessionId == null) {
    return HermesDecisionAnswerOutcome.failed;
  }
  if (admission == null || !ownsDesktop(service)) {
    return HermesDecisionAnswerOutcome.failed;
  }
  try {
    await service.respondToDecision(
      runtimeId: decision.runtimeId,
      storedSessionId: storedSessionId,
      requestId: decision.requestId,
      kind: decision.kind,
      value: value ?? '',
      mcpServer: decision.mcpServer,
      mcpAction: decision.mcpAction,
    );
  } catch (_) {
    return HermesDecisionAnswerOutcome.failed;
  }
  if (!configController.sessionActionAdmissionIsCurrent(admission) ||
      !ownsDesktop(service)) {
    return HermesDecisionAnswerOutcome.failed;
  }
  closeHermesDecision(ref, decision.messageId, decision.requestId);
  return HermesDecisionAnswerOutcome.answered;
}

/// Marks the question [requestId] on message [messageId] resolved, which
/// closes its card.
void closeHermesDecision(dynamic ref, String messageId, String requestId) {
  (ref.read(
    chatMessagesProvider.notifier,
  ) as ChatMessagesNotifier).updateMessageById(messageId, (message) {
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
    final current = metadata[kHermesDecisionMeta];
    if (current is Map && current['requestId'] == requestId) {
      metadata[kHermesDecisionMeta] = {
        ...current.cast<String, dynamic>(),
        'state': 'resolved',
      };
    }
    return message.copyWith(metadata: metadata);
  });
}
