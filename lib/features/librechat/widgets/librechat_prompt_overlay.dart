import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show kLibreChatPendingActionKey;
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart'
    show HermesDecisionKind;
import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../hermes/widgets/hermes_approval_card.dart';
import '../../hermes/widgets/hermes_decision_card.dart';

/// The newest LibreChat reply whose run paused for the user: tools awaiting
/// approval, or questions the agent asked.
ChatMessage? findPendingLibreChatComposerPrompt(List<ChatMessage> messages) {
  for (final message in messages.reversed) {
    final metadata = message.metadata;
    if (metadata == null || metadata['archivedVariant'] == true) continue;
    if (metadata['transport'] != kLibreChatTransport) continue;
    if (metadata[kLibreChatPendingActionKey] is Map) return message;
  }
  return null;
}

/// Sends the answer to a paused run: [decisions] for tool calls, or
/// [answers] for questions.
typedef LibreChatPendingActionResolver =
    Future<void> Function({
      Map<String, LibreChatToolDecisionInput>? decisions,
      Map<String, String>? answers,
    });

/// Answers a paused LibreChat run above the composer: one card per tool
/// call to approve or reject, or per question to answer. The run's answer
/// goes out through [onResolve] once every call or question has one; the
/// reply then carries on on the stream it was following.
///
/// The chat shows it only while the run is live in this app, including one
/// followed again after a restart, which restores the pause.
final class LibreChatComposerPromptOverlay extends StatefulWidget {
  const LibreChatComposerPromptOverlay({
    super.key,
    required this.action,
    required this.onResolve,
  });

  final LibreChatPendingAction action;
  final LibreChatPendingActionResolver onResolve;

  @override
  State<LibreChatComposerPromptOverlay> createState() =>
      _LibreChatComposerPromptOverlayState();
}

final class _LibreChatComposerPromptOverlayState
    extends State<LibreChatComposerPromptOverlay> {
  final Map<String, LibreChatToolDecisionInput> _decisions = {};
  final Map<String, String> _answers = {};
  bool _sending = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final l10n = AppLocalizations.of(context)!;
    final card = action.isToolApproval
        ? _approvalCard(action, l10n)
        : action.isQuestion
        ? _questionCard(action, l10n)
        : null;
    if (card == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card,
        if (_failed)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Text(
              l10n.libreChatAnswerFailed,
              style: AppTypography.bodySmallStyle.copyWith(
                color: context.conduitTheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget? _approvalCard(LibreChatPendingAction action, AppLocalizations l10n) {
    final requests = action.toolRequests;
    final request =
        requests
            .where((request) => !_decisions.containsKey(request.toolCallId))
            .firstOrNull ??
        requests.lastOrNull;
    if (request == null) return null;
    final arguments = _argumentsText(request.arguments);
    final description = request.description?.trim();
    return HermesApprovalCard(
      key: ValueKey('${action.actionId}\u0000${request.toolCallId}'),
      state: _sending
          ? HermesApprovalState.resolving
          : HermesApprovalState.pending,
      summary: [
        l10n.libreChatApprovalRun(
          request.name.isEmpty ? l10n.tools : request.name,
        ),
        if (description != null && description.isNotEmpty) description,
        ?arguments,
      ].join('\n\n'),
      onDecision: (approved) {
        if (_sending) return;
        _decisions[request.toolCallId] = LibreChatToolDecisionInput(
          approved ? LibreChatToolDecision.approve : LibreChatToolDecision.reject,
        );
        if (_decisions.length < requests.length) {
          setState(() => _failed = false);
          return;
        }
        _send(
          lastKey: request.toolCallId,
          decisions: Map.of(_decisions),
        );
      },
    );
  }

  Widget? _questionCard(LibreChatPendingAction action, AppLocalizations l10n) {
    final questions = action.questions;
    if (questions.isEmpty) return null;
    final ids = [
      for (var index = 0; index < questions.length; index++)
        questions[index]['id']?.toString() ?? 'question_$index',
    ];
    final open = ids.indexWhere((id) => !_answers.containsKey(id));
    final index = open < 0 ? ids.length - 1 : open;
    final question = questions[index];
    final id = ids[index];
    final text = question['question']?.toString().trim() ?? '';
    final description = question['description']?.toString().trim();
    final batch = questions.length > 1;
    final progress = l10n.libreChatQuestionProgress(index + 1, ids.length);
    final multiSelect = question['multiSelect'] == true;
    return HermesDecisionCard(
      key: ValueKey('${action.actionId}\u0000$id'),
      kind: HermesDecisionKind.clarification,
      title: batch || text.isEmpty ? progress : text,
      prompt: [
        if (batch && text.isNotEmpty) text,
        if (description != null && description.isNotEmpty) description,
      ].join('\n\n'),
      choices: _choiceLabels(question['options']),
      multiSelect: multiSelect,
      onSubmit: (value) async {
        if (_sending) return false;
        _answers[id] = _answerText(value, multiSelect: multiSelect);
        if (_answers.length < ids.length) {
          setState(() => _failed = false);
          return true;
        }
        return _send(lastKey: id, answers: Map.of(_answers));
      },
    );
  }

  /// Sends the run's answer. On failure the last card comes back, its
  /// answer cleared, so it can be sent again.
  Future<bool> _send({
    required String lastKey,
    Map<String, LibreChatToolDecisionInput>? decisions,
    Map<String, String>? answers,
  }) async {
    setState(() {
      _sending = true;
      _failed = false;
    });
    try {
      await widget.onResolve(decisions: decisions, answers: answers);
      return true;
    } catch (error) {
      DebugLogger.warning(
        'pending-action-answer-failed',
        scope: 'librechat/composer',
        data: {'error': error.runtimeType.toString()},
      );
      if (mounted) {
        setState(() {
          _decisions.remove(lastKey);
          _answers.remove(lastKey);
          _failed = true;
        });
      }
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

/// A tool call's arguments as the user reads them; null when there are none.
String? _argumentsText(Object? arguments) {
  if (arguments == null) return null;
  if (arguments is String) {
    final text = arguments.trim();
    return text.isEmpty || text == '{}' ? null : text;
  }
  if (arguments is Map && arguments.isEmpty) return null;
  try {
    return const JsonEncoder.withIndent('  ').convert(arguments);
  } catch (_) {
    return arguments.toString();
  }
}

/// A question's options, which LibreChat sends as labels or as
/// `{label, description}`.
List<String> _choiceLabels(Object? options) => [
  if (options is List)
    for (final option in options)
      if (option is String && option.isNotEmpty)
        option
      else if (option is Map && option['label'] is String)
        option['label'] as String,
];

/// The card hands several choices over as a JSON list; LibreChat takes one
/// answer per question, so they are joined.
String _answerText(String value, {required bool multiSelect}) {
  if (!multiSelect) return value;
  try {
    final decoded = jsonDecode(value);
    if (decoded is List) return decoded.join(', ');
  } catch (_) {
    // Typed text, not a list of choices.
  }
  return value;
}
