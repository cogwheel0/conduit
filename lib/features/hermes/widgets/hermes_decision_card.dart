import 'dart:convert';

import '../providers/hermes_decision_drafts.dart';

import 'package:material_ui/material_ui.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';

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
    this.draft,
    this.compact = false,
  });

  final HermesDecisionKind kind;
  final String? prompt;
  final String? mcpServer;
  final String? mcpAction;
  final List<String> choices;
  final bool multiSelect;
  final HermesDecisionDraft? draft;
  final bool compact;
  final Future<bool> Function(String value) onSubmit;

  @override
  State<HermesDecisionCard> createState() => _HermesDecisionCardState();
}

final class _HermesDecisionCardState extends State<HermesDecisionCard>
    with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  bool _submitting = false;
  bool _resolved = false;
  bool _dismissed = false;
  bool _failed = false;
  bool _custom = false;
  final Set<String> _selectedChoices = {};

  @override
  bool get wantKeepAlive => !_resolved;

  bool get _sensitive =>
      widget.kind == HermesDecisionKind.sudo ||
      widget.kind == HermesDecisionKind.secret;
  bool get _written => widget.choices.isEmpty || _custom || _sensitive;
  String get _answer => _written
      ? _controller.text
      : widget.multiSelect
      ? jsonEncode(widget.choices.where(_selectedChoices.contains).toList())
      : _selectedChoices.firstOrNull ?? '';
  bool get _valid => _written
      ? _controller.text.trim().isNotEmpty
      : _selectedChoices.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final draft = _draft;
    if (draft != null && draft.valid) {
      _controller.text = draft.text;
      _selectedChoices.addAll(draft.choices.where(widget.choices.contains));
      _custom = draft.custom;
      _dismissed = draft.dismissed;
    }
    _controller.addListener(_textChanged);
  }

  HermesDecisionDraft? get _draft => _sensitive ? null : widget.draft;

  void _saveDraft() {
    final draft = _draft;
    if (draft == null || !draft.valid) return;
    draft.text = _controller.text;
    draft.choices = Set.of(_selectedChoices);
    draft.custom = _custom;
    draft.dismissed = _dismissed;
  }

  void _changeDraft(VoidCallback change) {
    setState(change);
    _saveDraft();
  }

  void _textChanged() {
    _saveDraft();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit([String? override]) async {
    if (_submitting || (override == null && !_valid)) return;
    final value = override ?? _answer;
    setState(() {
      _submitting = true;
      _failed = false;
    });
    var resolved = false;
    try {
      resolved = await widget.onSubmit(value);
    } catch (_) {
      /* Keep the answer available for retry. */
    }
    if (resolved) _draft?.clear();
    if (!mounted) return;
    if (resolved) {
      _controller.clear();
      FocusScope.of(context).unfocus();
    }
    setState(() {
      _submitting = false;
      _resolved = resolved;
      _failed = !resolved;
    });
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final clarification = widget.kind == HermesDecisionKind.clarification;
    final title = switch (widget.kind) {
      HermesDecisionKind.clarification =>
        widget.prompt?.trim().isNotEmpty == true
            ? widget.prompt!
            : l10n.hermesClarificationTitle,
      HermesDecisionKind.sudo => l10n.hermesSudoTitle,
      HermesDecisionKind.secret => l10n.hermesSecretTitle,
      HermesDecisionKind.mcpSetup => l10n.hermesMcpSetupTitle,
    };
    if (_dismissed) {
      return TextButton.icon(
        onPressed: () => _changeDraft(() => _dismissed = false),
        icon: const Icon(Icons.help_outline),
        label: Text(l10n.hermesWaitingForResponse),
      );
    }
    return Semantics(
      container: true,
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_resolved && (!widget.compact || _submitting)) ...[
            const SizedBox(height: 8),
            Text(
              _submitting
                  ? l10n.hermesSendingResponse
                  : l10n.hermesWaitingForResponse,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Material(
            color: theme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: theme.cardBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _sensitive ? Icons.lock_outline : Icons.help_outline,
                        size: 20,
                        color: theme.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          style: AppTypography.standard.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (!clarification &&
                      widget.prompt?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.prompt!,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (_resolved)
                    Text(
                      l10n.hermesResponseSent,
                      style: TextStyle(color: theme.success),
                    )
                  else if (widget.kind == HermesDecisionKind.mcpSetup) ...[
                    Text(
                      '${widget.mcpAction ?? 'Set up'} ${widget.mcpServer ?? 'MCP server'}',
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ConduitButton(
                          text: l10n.hermesNotNow,
                          isCompact: true,
                          onPressed: _submitting
                              ? null
                              : () => _submit('decline'),
                        ),
                        ConduitButton(
                          text: l10n.hermesSetUp,
                          isCompact: true,
                          isLoading: _submitting,
                          onPressed: _submitting
                              ? null
                              : () => _submit('approve'),
                        ),
                      ],
                    ),
                  ] else ...[
                    if (!_written) ...[
                      for (final choice in widget.choices) ...[
                        Material(
                          color: theme.inputBackground,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: _selectedChoices.contains(choice)
                                  ? theme.textPrimary
                                  : theme.cardBorder,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: CheckboxListTile(
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            title: Text(choice),
                            value: _selectedChoices.contains(choice),
                            onChanged: _submitting
                                ? null
                                : (selected) => _changeDraft(() {
                                    if (!widget.multiSelect) {
                                      _selectedChoices.clear();
                                    }
                                    if (selected == true) {
                                      _selectedChoices.add(choice);
                                    } else {
                                      _selectedChoices.remove(choice);
                                    }
                                  }),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      TextButton.icon(
                        onPressed: _submitting
                            ? null
                            : () => _changeDraft(() => _custom = true),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: Text(l10n.hermesWriteAnswer),
                      ),
                    ] else ...[
                      TextField(
                        key: const ValueKey('hermes-written-answer'),
                        controller: _controller,
                        enabled: !_submitting,
                        obscureText: _sensitive,
                        enableSuggestions: !_sensitive,
                        autocorrect: !_sensitive,
                        enableIMEPersonalizedLearning: !_sensitive,
                        minLines: _sensitive ? 1 : 2,
                        maxLines: _sensitive ? 1 : 5,
                        decoration: const InputDecoration(),
                        onSubmitted: (_) => _submit(),
                      ),
                      if (widget.choices.isNotEmpty && !_sensitive)
                        TextButton(
                          onPressed: _submitting
                              ? null
                              : () => _changeDraft(() => _custom = false),
                          child: Text(l10n.hermesUseChoices),
                        ),
                      const SizedBox(height: 12),
                    ],
                    if (_failed) ...[
                      Text(
                        l10n.hermesResponseFailed,
                        style: TextStyle(color: theme.error),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ConduitButton(
                            text: l10n.hermesDismiss,
                            isCompact: true,
                            isSecondary: true,
                            onPressed: _submitting
                                ? null
                                : () {
                                    FocusScope.of(context).unfocus();
                                    _changeDraft(() => _dismissed = true);
                                  },
                          ),
                          ConduitButton(
                            text: l10n.send,
                            isCompact: true,
                            isLoading: _submitting,
                            onPressed: _submitting || !_valid
                                ? null
                                : () => _submit(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
