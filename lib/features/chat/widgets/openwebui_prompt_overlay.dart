import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/models/openwebui_chat_prompt.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';

class OpenWebUiPromptOverlay extends StatefulWidget {
  const OpenWebUiPromptOverlay({
    super.key,
    required this.prompt,
    this.onAnswer,
    this.onDecision,
  });

  final OpenWebUiComposerPrompt prompt;
  final FutureOr<void> Function(Map<String, dynamic> answers)? onAnswer;
  final FutureOr<void> Function(bool approved)? onDecision;

  @override
  State<OpenWebUiPromptOverlay> createState() => _OpenWebUiPromptOverlayState();
}

class _OpenWebUiPromptOverlayState extends State<OpenWebUiPromptOverlay> {
  final Map<String, Map<String, dynamic>> _answers = {};
  final Map<String, TextEditingController> _otherControllers = {};
  var _questionIndex = 0;
  var _busy = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _syncOtherControllers();
  }

  @override
  void didUpdateWidget(covariant OpenWebUiPromptOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prompt.identity == widget.prompt.identity) return;
    for (final controller in _otherControllers.values) {
      controller.dispose();
    }
    _otherControllers.clear();
    _answers.clear();
    _questionIndex = 0;
    _busy = false;
    _failed = false;
    _syncOtherControllers();
  }

  @override
  void dispose() {
    for (final controller in _otherControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _syncOtherControllers() {
    for (final question in widget.prompt.questions) {
      _otherControllers[question.id] = TextEditingController();
    }
  }

  bool get _complete =>
      widget.prompt.questions.isNotEmpty &&
      widget.prompt.questions.every((question) {
        final answer = _answers[question.id];
        return answer?['type'] == 'option' ||
            (answer?['type'] == 'other' &&
                (answer?['text']?.toString().trim().isNotEmpty ?? false));
      });

  Future<void> _run(FutureOr<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  void _selectOption(
    OpenWebUiPromptQuestion question,
    OpenWebUiPromptOption option,
    int index,
  ) {
    setState(() {
      _answers[question.id] = <String, dynamic>{
        'type': 'option',
        'option_index': index,
        'label': option.label,
        'description': option.description,
      };
    });
  }

  void _selectOther(OpenWebUiPromptQuestion question) {
    setState(() {
      _answers[question.id] = <String, dynamic>{
        'type': 'other',
        'text': _otherControllers[question.id]?.text.trim() ?? '',
      };
    });
  }

  void _updateOther(OpenWebUiPromptQuestion question, String value) {
    setState(() {
      _answers[question.id] = <String, dynamic>{'type': 'other', 'text': value};
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final semanticsLabel =
        widget.prompt.kind == OpenWebUiComposerPromptKind.askUser
        ? widget.prompt.questions[_questionIndex].header
        : l10n.hermesApprovalRequired;
    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticsLabel,
      child: Container(
        key: const ValueKey('openwebui-prompt-overlay'),
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: theme.surfaceBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.card),
          border: Border.all(color: theme.cardBorder),
          boxShadow: ConduitShadows.card(context),
        ),
        child: switch (widget.prompt.kind) {
          OpenWebUiComposerPromptKind.askUser => _buildQuestions(context),
          OpenWebUiComposerPromptKind.toolApproval => _buildDecision(
            context,
            approval: true,
          ),
          OpenWebUiComposerPromptKind.confirmation => _buildDecision(
            context,
            approval: false,
          ),
        },
      ),
    );
  }

  Widget _buildQuestions(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final question = widget.prompt.questions[_questionIndex];
    final answer = _answers[question.id];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                question.header,
                style: AppTypography.standard.copyWith(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (widget.prompt.questions.length > 1)
              Text(
                '${_questionIndex + 1}/${widget.prompt.questions.length}',
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          question.question,
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.min(320, MediaQuery.sizeOf(context).height * 0.36),
          ),
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (var index = 0; index < question.options.length; index++)
                  _buildOption(
                    context,
                    question,
                    question.options[index],
                    index,
                    answer?['type'] == 'option' &&
                        answer?['option_index'] == index,
                  ),
                if (question.allowOther) ...[
                  const SizedBox(height: Spacing.xs),
                  TextField(
                    key: ValueKey('openwebui-other-${question.id}'),
                    controller: _otherControllers[question.id],
                    enabled: !_busy,
                    maxLength: 500,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: l10n.openWebUiPromptOther,
                      hintText: l10n.openWebUiPromptAnswerHint,
                      counterText: '',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onTap: () => _selectOther(question),
                    onChanged: (value) => _updateOther(question, value),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_failed) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            l10n.errorMessage,
            key: const ValueKey('openwebui-prompt-error'),
            style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
          ),
        ],
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xs,
          alignment: WrapAlignment.end,
          children: [
            ConduitButton(
              text: l10n.cancel,
              isCompact: true,
              isSecondary: true,
              onPressed: _busy || widget.onDecision == null
                  ? null
                  : () => _run(() => widget.onDecision!(false)),
            ),
            if (_questionIndex > 0)
              ConduitButton(
                text: l10n.previousLabel,
                isCompact: true,
                isSecondary: true,
                onPressed: _busy
                    ? null
                    : () => setState(() => _questionIndex--),
              ),
            if (_questionIndex < widget.prompt.questions.length - 1)
              ConduitButton(
                text: l10n.nextLabel,
                isCompact: true,
                isSecondary: true,
                onPressed: _busy || answer == null
                    ? null
                    : () => setState(() => _questionIndex++),
              ),
            ConduitButton(
              text: l10n.openWebUiPromptSubmit,
              isCompact: true,
              isLoading: _busy,
              onPressed: _busy || !_complete || widget.onAnswer == null
                  ? null
                  : () => _run(
                      () => widget.onAnswer!(<String, dynamic>{
                        for (final entry in _answers.entries)
                          entry.key: Map<String, dynamic>.from(entry.value)
                            ..update(
                              'text',
                              (value) => value.toString().trim(),
                              ifAbsent: () => '',
                            )
                            ..removeWhere(
                              (key, _) =>
                                  key == 'text' &&
                                  entry.value['type'] != 'other',
                            ),
                      }),
                    ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOption(
    BuildContext context,
    OpenWebUiPromptQuestion question,
    OpenWebUiPromptOption option,
    int index,
    bool selected,
  ) {
    final theme = context.conduitTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '${option.label}. ${option.description}',
      child: InkWell(
        key: ValueKey('openwebui-option-${question.id}-$index'),
        onTap: _busy ? null : () => _selectOption(question, option, index),
        borderRadius: BorderRadius.circular(AppBorderRadius.input),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: IconSize.medium,
                color: selected ? theme.buttonPrimary : theme.textSecondary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      option.description,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDecision(BuildContext context, {required bool approval}) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final title = widget.prompt.title.isEmpty
        ? approval
              ? l10n.hermesApprovalRequired
              : l10n.confirm
        : widget.prompt.title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTypography.standard.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (widget.prompt.message.isNotEmpty) ...[
          const SizedBox(height: Spacing.xs),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.min(240, MediaQuery.sizeOf(context).height * 0.3),
            ),
            child: SingleChildScrollView(
              child: Text(
                widget.prompt.message,
                key: const ValueKey('openwebui-prompt-message'),
                style: approval
                    ? AppTypography.codeStyle.copyWith(
                        color: theme.textSecondary,
                      )
                    : AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                      ),
              ),
            ),
          ),
        ],
        if (_failed) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            l10n.errorMessage,
            key: const ValueKey('openwebui-prompt-error'),
            style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
          ),
        ],
        const SizedBox(height: Spacing.md),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xs,
          children: [
            ConduitButton(
              text: approval ? l10n.hermesApprovalDenyAction : l10n.cancel,
              isCompact: true,
              isSecondary: true,
              onPressed: _busy || widget.onDecision == null
                  ? null
                  : () => _run(() => widget.onDecision!(false)),
            ),
            ConduitButton(
              text: approval ? l10n.hermesApprovalApproveAction : l10n.confirm,
              isCompact: true,
              isLoading: _busy,
              onPressed: _busy || widget.onDecision == null
                  ? null
                  : () => _run(() => widget.onDecision!(true)),
            ),
          ],
        ),
      ],
    );
  }
}
