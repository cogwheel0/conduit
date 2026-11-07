import 'dart:async';

import 'package:clock/clock.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeConversationProvider;
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        captureHermesApprovalProjectionStateUpdater,
        chatMessagesProvider,
        hermesRunKeyForConversation;

import 'package:conduit_core/features/hermes/models/hermes_clarify_form.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';

import 'hermes_approval_card.dart';
import 'hermes_approval_cost_chip.dart';
import 'hermes_clarify_form_card.dart';
import 'hermes_decision_card.dart';

typedef _HermesApprovalBinding = ({
  HermesRunKey runKey,
  Object generationToken,
  CancelToken cancelToken,
  String messageId,
  String runId,
  String approvalId,
  String? storedSessionId,
  int? executionGeneration,
  List<String> choices,
});

String? _nonEmptyString(Object? value) {
  final text = value?.toString();
  return text == null || text.isEmpty ? null : text;
}

ChatMessage? findPendingHermesComposerPrompt(List<ChatMessage> messages) {
  for (final message in messages.reversed) {
    if (message.metadata?['archivedVariant'] == true) continue;
    if (message.metadata?['transport'] != kHermesTransport) continue;
    final approval = message.metadata?[kHermesApprovalMeta];
    if (approval is Map &&
        (approval['state'] == null ||
            approval['state'] == 'pending' ||
            approval['state'] == 'resolving') &&
        approval['runId'] is String &&
        (approval['runId'] as String).isNotEmpty &&
        approval['approvalId'] is String &&
        (approval['approvalId'] as String).isNotEmpty &&
        (message.metadata?['restoredDesktopDecision'] != true ||
            approval['storedSessionId']?.toString().isNotEmpty == true)) {
      return message;
    }
    final decision = message.metadata?[kHermesDecisionMeta];
    if (decision is! Map || decision['state'] != 'pending') continue;
    final expiresAt = DateTime.tryParse(
      decision['expiresAt']?.toString() ?? '',
    );
    final storedSessionId =
        _nonEmptyString(decision['storedSessionId']) ??
        _nonEmptyString(message.metadata?['hermesSessionId']);
    if (_nonEmptyString(decision['requestId']) != null &&
        _nonEmptyString(decision['runtimeId']) != null &&
        storedSessionId != null &&
        expiresAt != null &&
        expiresAt.isAfter(clock.now().toUtc())) {
      return message;
    }
  }
  return null;
}

/// Hermes-owned approval and interactive-decision presentation attached to
/// the active chat composer.
class HermesComposerPromptOverlay extends ConsumerStatefulWidget {
  const HermesComposerPromptOverlay({super.key, required this.message});

  final ChatMessage message;

  @override
  ConsumerState<HermesComposerPromptOverlay> createState() =>
      _HermesComposerPromptOverlayState();
}

class _HermesComposerPromptOverlayState
    extends ConsumerState<HermesComposerPromptOverlay> {
  Timer? _expiryTimer;

  @override
  Widget build(BuildContext context) {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final messages = ref.watch(chatMessagesProvider);
    for (final message in messages.reversed) {
      final card = _buildPromptCard(message);
      if (card != null) return card;
    }
    if (messages.any((message) => message.id == widget.message.id)) {
      return const SizedBox.shrink();
    }
    return _buildPromptCard(widget.message) ?? const SizedBox.shrink();
  }

  Widget? _buildPromptCard(ChatMessage message) =>
      message.metadata?['archivedVariant'] == true
      ? null
      : _buildApprovalCard(message) ?? _buildDecisionCard(message);

  Widget? _buildApprovalCard(ChatMessage message) {
    final approval = message.metadata?['hermesApproval'];
    if (approval is! Map) return null;
    if (approval['state'] != null &&
        approval['state'] != 'pending' &&
        approval['state'] != 'resolving') {
      return null;
    }

    final runId = approval['runId'] is String
        ? approval['runId'] as String
        : null;
    final approvalId = approval['approvalId'] is String
        ? approval['approvalId'] as String
        : null;
    final messageId = message.id;
    final activeConversation = ref.read(activeConversationProvider);
    final state = switch (approval['state']) {
      'resolving' => HermesApprovalState.resolving,
      'approved' => HermesApprovalState.approved,
      'denied' => HermesApprovalState.denied,
      _ => HermesApprovalState.pending,
    };
    final storedSessionId = approval['storedSessionId']?.toString();
    final choices = _approvalChoices(approval['choices']);
    if (message.metadata?['restoredDesktopDecision'] == true) {
      final service = ref.read(hermesApiServiceProvider);
      if (message.metadata?['transport'] != kHermesTransport ||
          service is! HermesDesktopApiService ||
          runId == null ||
          approvalId == null ||
          storedSessionId == null ||
          activeConversation == null ||
          !service.sessionIdsReferToSameBinding(
            activeConversation.metadata['hermesSessionId']?.toString() ?? '',
            storedSessionId,
          )) {
        return null;
      }
      final shown = hermesApprovalPresentation(
        approval['summary'] is String ? approval['summary'] as String : null,
        approval['cost'],
      );
      return HermesApprovalCard(
        state: state,
        summary: shown.summary,
        cost: shown.cost,
        choices: choices,
        onChoice: choices.isEmpty
            ? null
            : (choice) => _resolveRestoredDesktopApproval(
                service: service,
                ownerConversationId: activeConversation.id,
                storedSessionId: storedSessionId,
                messageId: messageId,
                approvalId: approvalId,
                choice: choice,
              ),
        onDecision: (approved) => _resolveRestoredDesktopApproval(
          service: service,
          ownerConversationId: activeConversation.id,
          storedSessionId: storedSessionId,
          messageId: messageId,
          approvalId: approvalId,
          choice: approved ? 'once' : 'deny',
        ),
      );
    }
    final runKey = activeConversation == null
        ? null
        : hermesRunKeyForConversation(
            ref,
            conversation: activeConversation,
            assistantMessageId: messageId,
          );
    final registry = ref.read(hermesRunRegistryProvider);
    final generationToken = runKey == null || runId == null
        ? null
        : registry.generationTokenFor(runKey, runId: runId);
    final cancelToken =
        runKey == null || runId == null || generationToken == null
        ? null
        : registry.cancelTokenForGeneration(
            runKey,
            generationToken: generationToken,
            runId: runId,
          );
    if (message.metadata?['transport'] != kHermesTransport ||
        runId == null ||
        approvalId == null ||
        runKey == null ||
        generationToken == null ||
        cancelToken == null) {
      return null;
    }
    final binding = (
      runKey: runKey,
      generationToken: generationToken,
      cancelToken: cancelToken,
      messageId: messageId,
      runId: runId,
      approvalId: approvalId,
      storedSessionId: storedSessionId,
      executionGeneration: approval['executionGeneration'] is int
          ? approval['executionGeneration'] as int
          : null,
      choices: choices,
    );

    final capabilities = ref.watch(hermesCapabilitiesProvider).asData?.value;
    if (capabilities != null && !capabilities.runApproval) {
      return null;
    }
    final shown = hermesApprovalPresentation(
      approval['summary'] is String ? approval['summary'] as String : null,
      approval['cost'],
    );
    return HermesApprovalCard(
      state: state,
      summary: shown.summary,
      cost: shown.cost,
      choices: choices,
      onChoice: choices.isEmpty
          ? null
          : (choice) =>
                _resolveApproval(choice != 'deny', binding, choice: choice),
      onDecision: (approved) => _resolveApproval(approved, binding),
    );
  }

  Widget? _buildDecisionCard(ChatMessage message) {
    if (message.metadata?['transport'] != kHermesTransport) {
      return null;
    }
    final decision = message.metadata?[kHermesDecisionMeta];
    if (decision is! Map || decision['state'] != 'pending') {
      return null;
    }
    final expiresAt = DateTime.tryParse(
      decision['expiresAt']?.toString() ?? '',
    );
    if (expiresAt == null || !expiresAt.isAfter(clock.now().toUtc())) {
      return null;
    }
    final requestId = _nonEmptyString(decision['requestId']);
    final runtimeId = _nonEmptyString(decision['runtimeId']);
    final kind = HermesDecisionKind.values.firstWhere(
      (value) => value.name == decision['kind'],
      orElse: () => HermesDecisionKind.clarification,
    );
    if (requestId == null || runtimeId == null) {
      return null;
    }
    final activeConversation = ref.read(activeConversationProvider);
    final ownerConversationId = activeConversation?.id;
    final storedSessionId =
        _nonEmptyString(decision['storedSessionId']) ??
        _nonEmptyString(message.metadata?['hermesSessionId']);
    if (ownerConversationId == null || storedSessionId == null) {
      return null;
    }
    _expiryTimer = Timer(expiresAt.difference(clock.now().toUtc()), () {
      if (mounted) setState(() {});
    });
    // A question with no text has nothing to show as a form; it keeps the
    // plain reply card.
    if (kind == HermesDecisionKind.clarification &&
        hermesClarifyQuestionsFromPayload(decision).isNotEmpty) {
      return _buildClarifyForm(
        message: message,
        decision: decision,
        requestId: requestId,
        runtimeId: runtimeId,
        storedSessionId: storedSessionId,
        ownerConversationId: ownerConversationId,
        expiresAt: expiresAt,
      );
    }
    return HermesDecisionCard(
      key: ValueKey('$runtimeId\u0000$requestId\u0000${kind.name}'),
      kind: kind,
      prompt: decision['prompt']?.toString(),
      mcpServer: decision['mcpServer']?.toString(),
      mcpAction: decision['mcpAction']?.toString(),
      choices: switch (decision['choices']) {
        final List values => values.whereType<String>().toList(growable: false),
        _ => const <String>[],
      },
      multiSelect: decision['multiSelect'] == true,
      onSubmit: (value) async {
        if (!expiresAt.isAfter(clock.now().toUtc())) return false;
        final service = ref.read(hermesApiServiceProvider);
        if (service is! HermesDesktopApiService) return false;
        final configController = ref.read(hermesConfigProvider.notifier);
        final admission = configController.captureSessionActionAdmission();
        if (admission == null ||
            !_ownsDesktopDecision(
              service: service,
              ownerConversationId: ownerConversationId,
              storedSessionId: storedSessionId,
            )) {
          return false;
        }
        try {
          await service.respondToDecision(
            runtimeId: runtimeId,
            storedSessionId: storedSessionId,
            requestId: requestId,
            kind: kind,
            value: value,
            mcpServer: decision['mcpServer']?.toString(),
            mcpAction: decision['mcpAction']?.toString(),
          );
          if (!configController.sessionActionAdmissionIsCurrent(admission) ||
              !_ownsDesktopDecision(
                service: service,
                ownerConversationId: ownerConversationId,
                storedSessionId: storedSessionId,
              )) {
            return false;
          }
          ref.read(chatMessagesProvider.notifier).updateMessageById(
            message.id,
            (message) {
              final metadata = Map<String, dynamic>.from(
                message.metadata ?? const {},
              );
              final current = metadata[kHermesDecisionMeta];
              if (current is Map && current['requestId'] == requestId) {
                metadata[kHermesDecisionMeta] = {
                  ...current.cast<String, dynamic>(),
                  'state': 'resolved',
                };
              }
              return message.copyWith(metadata: metadata);
            },
          );
          return true;
        } catch (_) {
          return false;
        }
      },
    );
  }

  /// A question Hermes asked, as one form: every question of a Desktop
  /// Gateway clarify request, or the one question of a REST run's or a
  /// session authority's `clarify.request`.
  Widget _buildClarifyForm({
    required ChatMessage message,
    required Map<dynamic, dynamic> decision,
    required String requestId,
    required String runtimeId,
    required String storedSessionId,
    required String ownerConversationId,
    required DateTime expiresAt,
  }) {
    final questions = hermesClarifyQuestionsFromPayload(decision);
    final generation = decision['executionGeneration'];
    return HermesClarifyFormCard(
      key: ValueKey('$runtimeId\u0000$requestId\u0000clarify'),
      questions: questions,
      onSubmit: (answers) async {
        if (!expiresAt.isAfter(clock.now().toUtc())) return false;
        final service = ref.read(hermesApiServiceProvider);
        final configController = ref.read(hermesConfigProvider.notifier);
        final admission = configController.captureSessionActionAdmission();
        bool owns() => switch (service) {
          final HermesDesktopApiService desktop => _ownsDesktopDecision(
            service: desktop,
            ownerConversationId: ownerConversationId,
            storedSessionId: storedSessionId,
          ),
          final HermesApiService rest => _ownsRestDecision(
            service: rest,
            ownerConversationId: ownerConversationId,
          ),
          _ => false,
        };
        if (admission == null || !owns()) return false;
        try {
          switch (service) {
            case final HermesDesktopApiService desktop:
              await desktop.respondToClarifyForm(
                runtimeId: runtimeId,
                storedSessionId: storedSessionId,
                requestId: requestId,
                answers: answers,
              );
            case final HermesApiService rest when generation is int:
              // A run's question takes one answer; empty skips it.
              await rest.answerClarify(
                runtimeId,
                promptId: requestId,
                executionGeneration: generation,
                answer: answers.values.firstOrNull ?? '',
              );
            default:
              return false;
          }
        } catch (_) {
          DebugLogger.warning(
            'clarify-answer-failed',
            scope: 'chat/hermes_clarify',
          );
          return false;
        }
        if (!configController.sessionActionAdmissionIsCurrent(admission) ||
            !owns()) {
          return false;
        }
        ref.read(chatMessagesProvider.notifier).updateMessageById(
          message.id,
          (message) {
            final metadata = Map<String, dynamic>.from(
              message.metadata ?? const {},
            );
            final current = metadata[kHermesDecisionMeta];
            if (current is Map && current['requestId'] == requestId) {
              metadata[kHermesDecisionMeta] = {
                ...current.cast<String, dynamic>(),
                'state': 'resolved',
              };
            }
            return message.copyWith(metadata: metadata);
          },
        );
        return true;
      },
    );
  }

  bool _ownsRestDecision({
    required HermesApiService service,
    required String ownerConversationId,
  }) =>
      mounted &&
      identical(ref.read(hermesApiServiceProvider), service) &&
      ref.read(activeConversationProvider)?.id == ownerConversationId;

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  bool _ownsDesktopDecision({
    required HermesDesktopApiService service,
    required String ownerConversationId,
    required String storedSessionId,
  }) {
    if (!mounted || !identical(ref.read(hermesApiServiceProvider), service)) {
      return false;
    }
    final active = ref.read(activeConversationProvider);
    final activeStoredId = active?.metadata['hermesSessionId']?.toString();
    return active?.id == ownerConversationId &&
        activeStoredId != null &&
        service.sessionIdsReferToSameBinding(activeStoredId, storedSessionId);
  }

  Future<void> _resolveRestoredDesktopApproval({
    required HermesDesktopApiService service,
    required String ownerConversationId,
    required String storedSessionId,
    required String messageId,
    required String approvalId,
    required String choice,
  }) async {
    final configController = ref.read(hermesConfigProvider.notifier);
    final admission = configController.captureSessionActionAdmission();
    if (admission == null ||
        !_ownsDesktopDecision(
          service: service,
          ownerConversationId: ownerConversationId,
          storedSessionId: storedSessionId,
        )) {
      return;
    }

    void update(String expected, String next) {
      ref.read(chatMessagesProvider.notifier).updateMessageById(messageId, (
        message,
      ) {
        final metadata = Map<String, dynamic>.from(
          message.metadata ?? const {},
        );
        final current = metadata[kHermesApprovalMeta];
        if (current is! Map ||
            current['approvalId'] != approvalId ||
            (current['state'] ?? 'pending') != expected) {
          return message;
        }
        metadata[kHermesApprovalMeta] = <String, dynamic>{
          ...current.cast<String, dynamic>(),
          'state': next,
        };
        return message.copyWith(metadata: metadata);
      });
    }

    update('pending', 'resolving');
    try {
      await service.resolveApprovalChoiceForSession(
        storedSessionId,
        approvalId: approvalId,
        choice: choice,
      );
    } catch (_) {
      if (_ownsDesktopDecision(
        service: service,
        ownerConversationId: ownerConversationId,
        storedSessionId: storedSessionId,
      )) {
        update('resolving', 'pending');
      }
      return;
    }
    if (!configController.sessionActionAdmissionIsCurrent(admission) ||
        !_ownsDesktopDecision(
          service: service,
          ownerConversationId: ownerConversationId,
          storedSessionId: storedSessionId,
        )) {
      return;
    }
    update('resolving', choice == 'deny' ? 'denied' : 'approved');
  }

  Future<void> _resolveApproval(
    bool approved,
    _HermesApprovalBinding binding, {
    String? choice,
  }) async {
    final approvalId = binding.approvalId;
    final runId = binding.runId;
    final messageId = binding.messageId;
    final activeConversation = ref.read(activeConversationProvider);
    final runKey = activeConversation == null
        ? null
        : hermesRunKeyForConversation(
            ref,
            conversation: activeConversation,
            assistantMessageId: messageId,
          );
    final registry = ref.read(hermesRunRegistryProvider);
    if (runKey == null) return;

    if (!registry.ownsGeneration(
      binding.runKey,
      generationToken: binding.generationToken,
      runId: runId,
    )) {
      if (runKey == binding.runKey ||
          !registry.ownsGeneration(
            runKey,
            generationToken: binding.generationToken,
            runId: runId,
          )) {
        return;
      }
    }

    final messagesNotifier = ref.read(chatMessagesProvider.notifier);
    final updateProjectionState = captureHermesApprovalProjectionStateUpdater(
      ref,
      cancelToken: binding.cancelToken,
      messageId: messageId,
      runId: runId,
      approvalId: approvalId,
    );

    bool setApprovalState(String next, {required String expectedState}) {
      final projectionUpdate = updateProjectionState(
        expectedState: expectedState,
        nextState: next,
      );
      if (projectionUpdate.found && !projectionUpdate.changed) return false;

      final currentConversation = mounted
          ? ref.read(activeConversationProvider)
          : null;
      final currentRunKey = currentConversation == null
          ? null
          : hermesRunKeyForConversation(
              ref,
              conversation: currentConversation,
              assistantMessageId: messageId,
            );
      final visibleOwnsGeneration =
          currentRunKey != null &&
          (projectionUpdate.found
              ? currentRunKey == projectionUpdate.key
              : registry.ownsGeneration(
                  currentRunKey,
                  generationToken: binding.generationToken,
                  runId: runId,
                ));
      var visibleChanged = false;
      if (visibleOwnsGeneration) {
        messagesNotifier.updateMessageById(messageId, (message) {
          if (message.metadata?['transport'] != kHermesTransport) {
            return message;
          }
          final metadata = Map<String, dynamic>.from(
            message.metadata ?? const {},
          );
          final current = metadata[kHermesApprovalMeta];
          if (current is! Map ||
              current['approvalId'] != approvalId ||
              current['runId'] != runId ||
              (current['state'] ?? 'pending') != expectedState) {
            return message;
          }
          metadata[kHermesApprovalMeta] = {
            ...current.cast<String, dynamic>(),
            'state': next,
          };
          visibleChanged = true;
          return message.copyWith(metadata: metadata);
        });
      }
      return projectionUpdate.found ? projectionUpdate.changed : visibleChanged;
    }

    final service = ref.read(hermesApiServiceProvider);
    if (service == null) {
      DebugLogger.warning('approval-no-service', scope: 'chat/hermes_approval');
      return;
    }
    if (!setApprovalState('resolving', expectedState: 'pending')) return;
    try {
      if (service is HermesDesktopApiService &&
          binding.storedSessionId != null) {
        await service.resolveApprovalChoiceForSession(
          binding.storedSessionId!,
          approvalId: approvalId,
          choice: choice ?? (approved ? 'once' : 'deny'),
        );
      } else if (choice != null && service is HermesDesktopApiService) {
        await service.resolveApprovalChoice(
          runId,
          approvalId: approvalId,
          choice: choice,
        );
      } else if (service is HermesApiService) {
        await service.resolveApproval(
          runId,
          approvalId: approvalId,
          approved: approved,
          executionGeneration: binding.executionGeneration,
          // The scope the user picked (`session`, `always`), when the
          // approval offered it; otherwise once or deny.
          choice: binding.choices.contains(choice) ? choice : null,
        );
      } else {
        await service.resolveApproval(
          runId,
          approvalId: approvalId,
          approved: approved,
        );
      }
    } catch (error) {
      DebugLogger.error(
        'approval-resolve-failed',
        scope: 'chat/hermes_approval',
      );
      // The prompt was answered elsewhere, timed out, or belongs to an older
      // execution: offering it again could only fail the same way.
      final settled =
          error is HermesApiException &&
          (error.code == HermesApiErrorCode.approvalNotPending ||
              error.code == HermesApiErrorCode.staleGeneration);
      setApprovalState(
        settled ? 'settled' : 'pending',
        expectedState: 'resolving',
      );
      return;
    }
    setApprovalState(
      approved ? 'approved' : 'denied',
      expectedState: 'resolving',
    );
  }
}

List<String> _approvalChoices(Object? value) => switch (value) {
  final List values =>
    values
        .whereType<String>()
        .where(const {'once', 'session', 'always', 'deny'}.contains)
        .take(4)
        .toList(growable: false),
  _ => const <String>[],
};
