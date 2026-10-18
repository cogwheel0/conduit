import 'dart:convert';

import 'package:flutter/widgets.dart';

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
        // A long question or tool call (a file's contents, say) scrolls
        // within half the screen rather than growing past its top.
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: SingleChildScrollView(child: card),
        ),
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
    final description = request.description?.trim();
    return _LibreChatApprovalCard(
      key: ValueKey('${action.actionId}\u0000${request.toolCallId}'),
      request: request,
      question: l10n.libreChatApprovalRun(
        request.name.isEmpty ? l10n.tools : request.name,
      ),
      description: description == null || description.isEmpty
          ? null
          : description,
      sending: _sending,
      onDecision: (decision) {
        if (_sending) return;
        _decisions[request.toolCallId] = decision;
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
    final choices = _choices(question['options']);
    return HermesDecisionCard(
      key: ValueKey('${action.actionId}\u0000$id'),
      kind: HermesDecisionKind.clarification,
      title: batch || text.isEmpty ? progress : text,
      prompt: [
        if (batch && text.isNotEmpty) text,
        if (description != null && description.isNotEmpty) description,
      ].join('\n\n'),
      choices: [for (final choice in choices) choice.label],
      multiSelect: multiSelect,
      onSubmit: (value) async {
        if (_sending) return false;
        _answers[id] = _answerText(
          value,
          multiSelect: multiSelect,
          choices: choices,
        );
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

/// One paused tool call: the decisions LibreChat allows for it, in the
/// server's order. Approve and Deny answer at once; Edit asks for the
/// arguments to run with, and Respond for what the tool returns instead.
final class _LibreChatApprovalCard extends StatefulWidget {
  const _LibreChatApprovalCard({
    super.key,
    required this.request,
    required this.question,
    required this.description,
    required this.sending,
    required this.onDecision,
  });

  final LibreChatToolRequest request;
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
    text: _editableArguments(widget.request.arguments),
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
    Object? parsed;
    try {
      parsed = jsonDecode(_edited.text);
    } on FormatException {
      parsed = null;
    }
    // LibreChat runs the tool with a JSON object only.
    if (parsed is! Map) {
      setState(() => _editInvalid = true);
      return;
    }
    widget.onDecision(
      LibreChatToolDecisionInput(
        LibreChatToolDecision.edit,
        editedArguments: Map<String, dynamic>.from(parsed),
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
        : _argumentsText(widget.request.arguments);
    final allowed = widget.request.allowed.toSet();
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

/// The arguments to edit, as JSON: the tool call's own, or an empty object.
String _editableArguments(Object? arguments) {
  var value = arguments;
  if (arguments is String) {
    try {
      value = jsonDecode(arguments);
    } on FormatException {
      return arguments;
    }
  }
  if (value == null) return '{}';
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return '{}';
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
/// A question's choices: each is shown by its label and answered with its
/// value, as LibreChat's own client answers.
List<({String label, String value})> _choices(Object? options) => [
  if (options is List)
    for (final option in options)
      if (option is String && option.isNotEmpty)
        (label: option, value: option)
      else if (option is Map && option['label'] is String)
        (
          label: option['label'] as String,
          value: option['value'] is String
              ? option['value'] as String
              : option['label'] as String,
        ),
];

/// The answer to send for what the card picked: each chosen label becomes
/// its choice's value. The card hands several choices over as a JSON list;
/// LibreChat takes one answer per question, the values joined with ", ".
/// Typed text goes as it is.
String _answerText(
  String value, {
  required bool multiSelect,
  required List<({String label, String value})> choices,
}) {
  String valueOf(String label) =>
      choices.where((choice) => choice.label == label).firstOrNull?.value ??
      label;
  if (!multiSelect) return valueOf(value);
  try {
    final decoded = jsonDecode(value);
    if (decoded is List) {
      return decoded.map((label) => valueOf('$label')).join(', ');
    }
  } catch (_) {
    // Typed text, not a list of choices.
  }
  return value;
}
