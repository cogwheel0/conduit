import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/composer_prompt_surface.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../models/hermes_run_event.dart';

final class HermesDecisionCard extends StatefulWidget {
  const HermesDecisionCard({
    super.key,
    required this.kind,
    required this.onSubmit,
    this.prompt,
    this.mcpServer,
    this.mcpAction,
    this.choices = const <String>[],
    this.multiSelect = false,
    this.questions = const <HermesClarifyQuestion>[],
    this.answers = const <String, String>{},
  });

  final HermesDecisionKind kind;
  final String? prompt;
  final String? mcpServer;
  final String? mcpAction;
  final List<String> choices;
  final bool multiSelect;

  /// Batch clarify questions. When non-empty the card renders one answer
  /// section per question instead of the single-question form; when empty it
  /// degrades to the original single-question card.
  final List<HermesClarifyQuestion> questions;

  /// Answers the gateway already locked, keyed by question id. Replayed after
  /// a reconnect so the card restores its per-question ✓ state.
  final Map<String, String> answers;

  /// Submits one answer. [questionId] is set only for a batch question, and
  /// the returned outcome carries the gateway's remaining-question count so
  /// the card can show progress and detect full resolution.
  final Future<HermesDecisionSubmitOutcome> Function(
    String value, {
    String? questionId,
  })
  onSubmit;

  @override
  State<HermesDecisionCard> createState() => _HermesDecisionCardState();
}

final class _HermesDecisionCardState extends State<HermesDecisionCard> {
  final _controller = TextEditingController();
  bool _submitting = false;
  bool _resolved = false;
  final Set<String> _selectedChoices = <String>{};

  /// Batch questions answered so far, seeded from the gateway's reconnect
  /// replay and advanced as each per-question submit succeeds.
  late final Set<String> _answeredQuestions = <String>{
    for (final question in widget.questions)
      if (widget.answers.containsKey(question.qid)) question.qid,
  };

  bool get _sensitive =>
      widget.kind == HermesDecisionKind.sudo ||
      widget.kind == HermesDecisionKind.secret;

  bool get _isBatch => widget.questions.isNotEmpty;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit([String? override]) async {
    final value = override ?? _controller.text;
    if (value.trim().isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final outcome = await widget.onSubmit(value);
    if (!mounted) return;
    if (outcome.resolved) _controller.clear();
    setState(() {
      _submitting = false;
      _resolved = outcome.resolved;
    });
  }

  Future<HermesDecisionSubmitOutcome> _submitQuestion(
    HermesClarifyQuestion question,
    String value,
  ) async {
    final outcome = await widget.onSubmit(value, questionId: question.qid);
    if (!mounted) return outcome;
    if (!outcome.failed) {
      setState(() {
        _answeredQuestions.add(question.qid);
        if (outcome.resolved) _resolved = true;
      });
    }
    return outcome;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final title = switch (widget.kind) {
      HermesDecisionKind.clarification => l10n.hermesClarificationTitle,
      HermesDecisionKind.sudo => l10n.hermesSudoTitle,
      HermesDecisionKind.secret => l10n.hermesSecretTitle,
      HermesDecisionKind.mcpSetup => l10n.hermesMcpSetupTitle,
    };
    return ComposerPromptSurface(
      semanticsLabel: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTypography.standard.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.textPrimary,
            ),
          ),
          if (widget.prompt?.trim().isNotEmpty == true) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              widget.prompt!,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: Spacing.sm),
          if (_resolved)
            Text(
              l10n.hermesResponseSent,
              style: TextStyle(color: theme.success),
            )
          else if (_isBatch)
            ..._buildBatch(l10n, theme)
          else
            ..._buildSingle(l10n, theme),
        ],
      ),
    );
  }

  List<Widget> _buildBatch(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
  ) {
    return [
      if (widget.questions.length > 1) ...[
        Text(
          l10n.hermesClarifyProgress(
            _answeredQuestions.length,
            widget.questions.length,
          ),
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.sm),
      ],
      for (final (index, question) in widget.questions.indexed) ...[
        if (index > 0) const SizedBox(height: Spacing.md),
        _HermesClarifyQuestionField(
          key: ValueKey(question.qid),
          question: question,
          initialAnswer: widget.answers[question.qid],
          answered: _answeredQuestions.contains(question.qid),
          onSubmit: (value) => _submitQuestion(question, value),
        ),
      ],
    ];
  }

  List<Widget> _buildSingle(AppLocalizations l10n, ConduitThemeExtension theme) {
    if (widget.kind == HermesDecisionKind.mcpSetup) {
      return [
        Text(
          '${widget.mcpAction ?? 'Set up'} ${widget.mcpServer ?? 'MCP server'}',
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          children: [
            ConduitButton(
              text: l10n.hermesNotNow,
              isCompact: true,
              onPressed: _submitting ? null : () => _submit('decline'),
            ),
            const SizedBox(width: Spacing.sm),
            ConduitButton(
              text: l10n.hermesSetUp,
              isCompact: true,
              isLoading: _submitting,
              onPressed: _submitting ? null : () => _submit('approve'),
            ),
          ],
        ),
      ];
    }
    return [
      if (widget.choices.isNotEmpty) ...[
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final choice in widget.choices)
              FilterChip(
                label: Text(choice),
                selected: _selectedChoices.contains(choice),
                onSelected: _submitting
                    ? null
                    : (selected) {
                        if (!widget.multiSelect && selected) {
                          _selectedChoices.clear();
                        }
                        setState(() {
                          selected
                              ? _selectedChoices.add(choice)
                              : _selectedChoices.remove(choice);
                        });
                      },
              ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
      ],
      TextField(
        controller: _controller,
        obscureText: _sensitive,
        enableSuggestions: !_sensitive,
        autocorrect: !_sensitive,
        enableIMEPersonalizedLearning: !_sensitive,
        decoration: InputDecoration(
          labelText: _sensitive
              ? l10n.hermesSensitiveResponse
              : l10n.hermesResponse,
        ),
        onSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: Spacing.sm),
      ConduitButton(
        text: l10n.hermesSendResponse,
        isCompact: true,
        isLoading: _submitting,
        onPressed: _submitting
            ? null
            : () => _submit(
                _selectedChoices.isEmpty
                    ? null
                    : widget.multiSelect
                    ? jsonEncode(_selectedChoices.toList())
                    : _selectedChoices.single,
              ),
      ),
    ];
  }
}

/// One question row of a batch clarify card. Each field owns its own answer
/// controls and submits independently, so answering one question never blocks
/// or clears another.
final class _HermesClarifyQuestionField extends StatefulWidget {
  const _HermesClarifyQuestionField({
    super.key,
    required this.question,
    required this.initialAnswer,
    required this.answered,
    required this.onSubmit,
  });

  final HermesClarifyQuestion question;
  final String? initialAnswer;
  final bool answered;
  final Future<HermesDecisionSubmitOutcome> Function(String value) onSubmit;

  @override
  State<_HermesClarifyQuestionField> createState() =>
      _HermesClarifyQuestionFieldState();
}

final class _HermesClarifyQuestionFieldState
    extends State<_HermesClarifyQuestionField> {
  final _controller = TextEditingController();
  final Set<String> _selectedChoices = <String>{};
  bool _submitting = false;

  bool get _multiSelect => widget.question.multiSelect;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialAnswer;
    if (initial == null || initial.isEmpty) return;
    if (_multiSelect) {
      final decoded = _decodeMultiAnswer(initial);
      if (decoded != null) {
        _selectedChoices.addAll(decoded);
        return;
      }
    }
    _controller.text = initial;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Multi-select answers travel as a JSON array; anything else is free text.
  static List<String>? _decodeMultiAnswer(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } catch (_) {
      // A locked answer that is not JSON was free text; fall back to it.
    }
    return null;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final value = _selectedChoices.isEmpty
        ? _controller.text
        : _multiSelect
        ? jsonEncode(_selectedChoices.toList())
        : _selectedChoices.single;
    if (value.trim().isEmpty) return;
    setState(() => _submitting = true);
    // The card owns the answered/progress state; a failed submit simply leaves
    // this answer editable for a retry.
    await widget.onSubmit(value);
    if (!mounted) return;
    setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                widget.question.question,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textPrimary,
                ),
              ),
            ),
            if (widget.answered) ...[
              const SizedBox(width: Spacing.xs),
              Icon(
                Icons.check_circle,
                size: 16,
                color: theme.success,
                semanticLabel: l10n.hermesResponseSent,
              ),
            ],
          ],
        ),
        if (widget.question.choices.isNotEmpty) ...[
          const SizedBox(height: Spacing.xs),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              for (final choice in widget.question.choices)
                FilterChip(
                  label: Text(choice),
                  selected: _selectedChoices.contains(choice),
                  onSelected: _submitting
                      ? null
                      : (selected) {
                          if (!_multiSelect && selected) {
                            _selectedChoices.clear();
                          }
                          setState(() {
                            selected
                                ? _selectedChoices.add(choice)
                                : _selectedChoices.remove(choice);
                          });
                        },
                ),
            ],
          ),
        ],
        const SizedBox(height: Spacing.xs),
        TextField(
          controller: _controller,
          decoration: InputDecoration(labelText: l10n.hermesResponse),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: Spacing.xs),
        ConduitButton(
          text: l10n.hermesSendResponse,
          isCompact: true,
          isLoading: _submitting,
          onPressed: _submitting ? null : _submit,
        ),
      ],
    );
  }
}
