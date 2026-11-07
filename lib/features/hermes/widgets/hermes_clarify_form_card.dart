import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_clarify_form.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/composer_prompt_surface.dart';
import '../../../shared/widgets/conduit_components.dart';

/// The share of the screen a long form may take before it scrolls.
const double _kMaxFormHeightFraction = 0.45;

/// Every question Hermes asked in one clarify call, answered with one
/// Submit: pick a choice (or several), type an answer, or skip a question.
/// Questions answered on another surface show their answer, read-only.
class HermesClarifyFormCard extends StatefulWidget {
  const HermesClarifyFormCard({
    super.key,
    required this.questions,
    required this.onSubmit,
  });

  final List<HermesClarifyQuestion> questions;

  /// Sends the answers of the questions still open, by id (null skips
  /// one). Resolves to whether Hermes took them.
  final Future<bool> Function(Map<String, String?> answers) onSubmit;

  @override
  State<HermesClarifyFormCard> createState() => _HermesClarifyFormCardState();
}

class _HermesClarifyFormCardState extends State<HermesClarifyFormCard> {
  final Map<String, HermesClarifyDraft> _drafts = {};
  final Map<String, TextEditingController> _text = {};
  bool _submitting = false;
  bool _sent = false;
  bool _failed = false;

  List<HermesClarifyQuestion> get _open =>
      widget.questions.where((question) => !question.locked).toList();

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  HermesClarifyDraft _draft(HermesClarifyQuestion question) =>
      _drafts[question.id] ?? const HermesClarifyDraft();

  TextEditingController _controller(HermesClarifyQuestion question) =>
      _text.putIfAbsent(question.id, TextEditingController.new);

  void _update(HermesClarifyQuestion question, HermesClarifyDraft draft) {
    setState(() {
      _drafts[question.id] = draft;
      _failed = false;
    });
  }

  void _toggleChoice(HermesClarifyQuestion question, String choice) {
    final draft = _draft(question);
    if (question.multiSelect) {
      final choices = [...draft.choices];
      choices.contains(choice) ? choices.remove(choice) : choices.add(choice);
      _update(question, HermesClarifyDraft(choices: choices, text: draft.text));
      return;
    }
    // One choice or typed words, never both.
    _controller(question).clear();
    final picked = draft.choices.contains(choice);
    _update(
      question,
      HermesClarifyDraft(choices: picked ? const [] : [choice]),
    );
  }

  void _typed(HermesClarifyQuestion question, String value) {
    final draft = _draft(question);
    _update(
      question,
      HermesClarifyDraft(
        choices: question.multiSelect || value.trim().isEmpty
            ? draft.choices
            : const [],
        text: value,
      ),
    );
  }

  void _toggleSkip(HermesClarifyQuestion question) {
    final draft = _draft(question);
    _update(
      question,
      HermesClarifyDraft(
        choices: draft.choices,
        text: draft.text,
        skipped: !draft.skipped,
      ),
    );
  }

  bool get _ready =>
      _open.isNotEmpty &&
      _open.every((question) => _draft(question).settles(question));

  Future<void> _submit() async {
    if (!_ready || _submitting) return;
    setState(() {
      _submitting = true;
      _failed = false;
    });
    final sent = await widget.onSubmit(
      hermesClarifyAnswers(widget.questions, _drafts),
    );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _sent = sent;
      _failed = !sent;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final questions = widget.questions;
    final settled = questions
        .where(
          (question) =>
              question.locked || _draft(question).settles(question),
        )
        .length;
    final maxHeight = math.max(
      160.0,
      MediaQuery.sizeOf(context).height * _kMaxFormHeightFraction,
    );
    return ComposerPromptSurface(
      semanticsLabel: l10n.hermesClarificationTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.help_outline_rounded,
                size: 18,
                color: theme.buttonPrimary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  l10n.hermesClarificationTitle,
                  style: AppTypography.standard.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.textPrimary,
                  ),
                ),
              ),
              if (questions.length > 1 && !_sent)
                Text(
                  l10n.hermesClarifyProgress(settled, questions.length),
                  style: AppTypography.labelSmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (_sent)
            Text(
              l10n.hermesResponseSent,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.success,
              ),
            )
          else ...[
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, question) in questions.indexed) ...[
                      if (index > 0) const SizedBox(height: Spacing.md),
                      _QuestionBlock(
                        key: ValueKey('hermes-clarify-${question.id}'),
                        question: question,
                        number: questions.length > 1 ? index + 1 : null,
                        draft: _draft(question),
                        controller: _controller(question),
                        enabled: !_submitting,
                        onChoice: (choice) => _toggleChoice(question, choice),
                        onTyped: (value) => _typed(question, value),
                        onSkip: () => _toggleSkip(question),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            if (_failed) ...[
              Text(
                l10n.hermesClarifySendFailed,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.error,
                ),
              ),
              const SizedBox(height: Spacing.xs),
            ],
            Row(
              children: [
                Expanded(
                  child: _ready
                      ? const SizedBox.shrink()
                      : Text(
                          l10n.hermesClarifyAnswerOrSkip,
                          style: AppTypography.labelSmallStyle.copyWith(
                            color: theme.textTertiary,
                          ),
                        ),
                ),
                const SizedBox(width: Spacing.sm),
                ConduitButton(
                  key: const ValueKey('hermes-clarify-submit'),
                  text: l10n.hermesSendResponse,
                  isCompact: true,
                  isLoading: _submitting,
                  onPressed: _ready && !_submitting ? _submit : null,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _QuestionBlock extends StatelessWidget {
  const _QuestionBlock({
    super.key,
    required this.question,
    required this.number,
    required this.draft,
    required this.controller,
    required this.enabled,
    required this.onChoice,
    required this.onTyped,
    required this.onSkip,
  });

  final HermesClarifyQuestion question;
  final int? number;
  final HermesClarifyDraft draft;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChoice;
  final ValueChanged<String> onTyped;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final active = enabled && !draft.skipped && !question.locked;
    final heading = number == null
        ? question.text
        : '$number. ${question.text}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          heading,
          style: AppTypography.bodySmallStyle.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.textPrimary,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        if (question.locked)
          _LockedAnswer(answer: question.lockedAnswer)
        else ...[
          Opacity(
            opacity: draft.skipped ? 0.45 : 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final choice in question.choices)
                  _ChoiceRow(
                    key: ValueKey('hermes-clarify-${question.id}-$choice'),
                    label: hermesClarifyBareChoice(choice),
                    recommended: hermesClarifyChoiceIsRecommended(choice),
                    multiSelect: question.multiSelect,
                    selected: draft.choices.contains(choice),
                    onTap: active ? () => onChoice(choice) : null,
                  ),
                if (question.choices.isNotEmpty)
                  const SizedBox(height: Spacing.xs),
                AdaptiveTextField(
                  key: ValueKey('hermes-clarify-${question.id}-text'),
                  controller: controller,
                  enabled: active,
                  placeholder: question.choices.isEmpty
                      ? l10n.hermesResponse
                      : l10n.hermesClarifyOtherAnswer,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: kMaxHermesClarifyAnswerCharacters,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(
                      kMaxHermesClarifyAnswerCharacters,
                    ),
                  ],
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textPrimary,
                  ),
                  onChanged: onTyped,
                ),
              ],
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: AdaptiveChip.filter(
              key: ValueKey('hermes-clarify-${question.id}-skip'),
              label: Text(l10n.hermesClarifySkip),
              selected: draft.skipped,
              onSelected: enabled ? (_) => onSkip() : null,
            ),
          ),
        ],
      ],
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.label,
    required this.recommended,
    required this.multiSelect,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool recommended;
  final bool multiSelect;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final icon = multiSelect
        ? (selected
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded)
        : (selected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_unchecked_rounded);
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? theme.buttonPrimary : theme.iconSecondary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: label,
                    children: [
                      if (recommended)
                        TextSpan(
                          text: '  ${l10n.hermesClarifyRecommended}',
                          style: AppTypography.labelSmallStyle.copyWith(
                            color: theme.buttonPrimary,
                          ),
                        ),
                    ],
                  ),
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A locked multi-select answer is a JSON array string; show its items.
String? _readable(String? answer) {
  if (answer == null || !answer.startsWith('[')) return answer;
  try {
    final decoded = jsonDecode(answer);
    if (decoded is List && decoded.every((item) => item is String)) {
      return decoded.cast<String>().join(', ');
    }
  } on FormatException {
    // Typed words that merely start with a bracket.
  }
  return answer;
}

class _LockedAnswer extends StatelessWidget {
  const _LockedAnswer({required this.answer});

  final String? answer;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.check_rounded, size: 18, color: theme.success),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            _readable(answer) ?? l10n.hermesClarifySkipped,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
