import 'package:flutter/widgets.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show kLibreChatPendingActionKey;
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart'
    show HermesDecisionKind;
import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/features/librechat/services/librechat_pause_controller.dart';
import 'package:conduit_core/models/chat_message.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/composer_prompt_surface.dart';
import '../../../shared/widgets/conduit_components.dart';
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
/// call, offering the decisions the server allows for it, or per question
/// to answer. The run's answer
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
  late final LibreChatPauseController _pause = LibreChatPauseController(
    widget.action,
    resolve: widget.onResolve,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final card = switch (_pause.current) {
      final LibreChatToolCard card => _approvalCard(card, l10n),
      final LibreChatQuestionCard card => _questionCard(card, l10n),
      null => null,
    };
    if (card == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A long question or tool call (a file's contents, say) scrolls
        // within half the screen rather than growing past its top.
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: SingleChildScrollView(child: card),
        ),
        if (_pause.failed)
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

  /// Takes an answer through the controller, showing it going out and what
  /// came of it.
  Future<LibreChatPauseStep> _take(Future<LibreChatPauseStep> step) async {
    setState(() {});
    final result = await step;
    if (mounted) setState(() {});
    return result;
  }

  Widget _approvalCard(LibreChatToolCard card, AppLocalizations l10n) {
    final request = card.request;
    final description = request.description?.trim();
    return _LibreChatApprovalCard(
      key: ValueKey('${widget.action.actionId}\u0000${card.id}'),
      card: card,
      question: l10n.libreChatApprovalRun(
        request.name.isEmpty ? l10n.tools : request.name,
      ),
      description: description == null || description.isEmpty
          ? null
          : description,
      sending: _pause.sending,
      onDecision: (decision) {
        if (_pause.sending) return;
        _take(_pause.decide(card.id, decision));
      },
    );
  }

  Widget _questionCard(LibreChatQuestionCard card, AppLocalizations l10n) {
    final text = card.question;
    final batch = card.count > 1;
    final progress = l10n.libreChatQuestionProgress(card.index + 1, card.count);
    return HermesDecisionCard(
      key: ValueKey('${widget.action.actionId}\u0000${card.id}'),
      kind: HermesDecisionKind.clarification,
      title: batch || text.isEmpty ? progress : text,
      prompt: [
        if (batch && text.isNotEmpty) text,
        ?card.description,
      ].join('\n\n'),
      choices: [for (final choice in card.choices) choice.label],
      multiSelect: card.multiSelect,
      onSubmit: (value) async {
        if (_pause.sending) return false;
        final step = await _take(
          _pause.answer(card.id, card.answerFor(value)),
        );
        return step == LibreChatPauseStep.next ||
            step == LibreChatPauseStep.sent;
      },
    );
  }
}

/// One paused tool call: the decisions LibreChat allows for it, in the
/// server's order. Approve and Deny answer at once; Edit asks for the
/// arguments to run with, and Respond for what the tool returns instead.
final class _LibreChatApprovalCard extends StatefulWidget {
  const _LibreChatApprovalCard({
    super.key,
    required this.card,
    required this.question,
    required this.description,
    required this.sending,
    required this.onDecision,
  });

  final LibreChatToolCard card;
  final String question;
  final String? description;
  final bool sending;
  final void Function(LibreChatToolDecisionInput decision) onDecision;

  @override
  State<_LibreChatApprovalCard> createState() => _LibreChatApprovalCardState();
}

final class _LibreChatApprovalCardState extends State<_LibreChatApprovalCard> {
  /// Edit or respond while its field is open, else null.
  LibreChatToolDecision? _composing;
  late final TextEditingController _edited = TextEditingController(
    text: widget.card.editableArguments,
  );
  final TextEditingController _response = TextEditingController();
  bool _editInvalid = false;

  @override
  void dispose() {
    _edited.dispose();
    _response.dispose();
    super.dispose();
  }

  void _choose(LibreChatToolDecision decision) {
    switch (decision) {
      case LibreChatToolDecision.approve:
      case LibreChatToolDecision.reject:
        widget.onDecision(LibreChatToolDecisionInput(decision));
      case LibreChatToolDecision.edit:
      case LibreChatToolDecision.respond:
        setState(() {
          _composing = decision;
          _editInvalid = false;
        });
    }
  }

  void _sendEdit() {
    final edited = LibreChatPauseController.editedArguments(_edited.text);
    if (edited == null) {
      setState(() => _editInvalid = true);
      return;
    }
    widget.onDecision(
      LibreChatToolDecisionInput(
        LibreChatToolDecision.edit,
        editedArguments: edited,
      ),
    );
  }

  void _sendResponse() {
    final text = _response.text.trim();
    if (text.isEmpty) return;
    widget.onDecision(
      LibreChatToolDecisionInput(
        LibreChatToolDecision.respond,
        responseText: text,
      ),
    );
  }

  String _label(AppLocalizations l10n, LibreChatToolDecision decision) =>
      switch (decision) {
        LibreChatToolDecision.approve => l10n.hermesApprovalApproveAction,
        LibreChatToolDecision.reject => l10n.hermesApprovalDenyAction,
        LibreChatToolDecision.edit => l10n.edit,
        LibreChatToolDecision.respond => l10n.libreChatApprovalRespond,
      };

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final sending = widget.sending;
    final composing = _composing;
    final arguments = composing == LibreChatToolDecision.edit
        ? null
        : widget.card.argumentsText;
    final allowed = widget.card.allowed.toSet();
    return ComposerPromptSurface(
      semanticsLabel: l10n.hermesApprovalRequired,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.hermesApprovalRequired,
            style: AppTypography.standard.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.textPrimary,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            [widget.question, ?widget.description, ?arguments].join('\n\n'),
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.md),
          if (composing == LibreChatToolDecision.edit) ...[
            ConduitInput(
              label: l10n.libreChatApprovalArguments,
              controller: _edited,
              enabled: !sending,
              minLines: 3,
              maxLines: 12,
              keyboardType: TextInputType.multiline,
              style: AppTypography.codeStyle,
              errorText: _editInvalid ? l10n.workspaceModelInvalidJson : null,
              onChanged: (_) {
                if (_editInvalid) setState(() => _editInvalid = false);
              },
            ),
            const SizedBox(height: Spacing.sm),
            _composeActions(l10n, send: l10n.send, onSend: _sendEdit),
          ] else if (composing == LibreChatToolDecision.respond) ...[
            ConduitInput(
              label: l10n.hermesResponse,
              controller: _response,
              enabled: !sending,
              minLines: 2,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Spacing.sm),
            _composeActions(
              l10n,
              send: l10n.hermesSendResponse,
              onSend: _response.text.trim().isEmpty ? null : _sendResponse,
            ),
          ] else
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final decision in allowed)
                  ConduitButton(
                    text: _label(l10n, decision),
                    isCompact: true,
                    isSecondary: decision != LibreChatToolDecision.approve,
                    isLoading: sending,
                    onPressed: sending ? null : () => _choose(decision),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _composeActions(
    AppLocalizations l10n, {
    required String send,
    required VoidCallback? onSend,
  }) => Wrap(
    spacing: Spacing.sm,
    runSpacing: Spacing.sm,
    children: [
      ConduitButton(
        text: send,
        isCompact: true,
        isLoading: widget.sending,
        onPressed: widget.sending ? null : onSend,
      ),
      ConduitButton(
        text: l10n.cancel,
        isCompact: true,
        isSecondary: true,
        onPressed: widget.sending
            ? null
            : () => setState(() {
                _composing = null;
                _editInvalid = false;
              }),
      ),
    ],
  );
}
