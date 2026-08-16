import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';
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
  });

  final HermesDecisionKind kind;
  final String? prompt;
  final String? mcpServer;
  final String? mcpAction;
  final List<String> choices;
  final bool multiSelect;
  final Future<bool> Function(String value) onSubmit;

  @override
  State<HermesDecisionCard> createState() => _HermesDecisionCardState();
}

final class _HermesDecisionCardState extends State<HermesDecisionCard> {
  final _controller = TextEditingController();
  bool _submitting = false;
  bool _resolved = false;
  final Set<String> _selectedChoices = <String>{};

  bool get _sensitive =>
      widget.kind == HermesDecisionKind.sudo ||
      widget.kind == HermesDecisionKind.secret;

  String get _title => switch (widget.kind) {
    HermesDecisionKind.clarification => 'Hermes needs clarification',
    HermesDecisionKind.sudo => 'Hermes needs sudo access',
    HermesDecisionKind.secret => 'Hermes needs a secret',
    HermesDecisionKind.mcpSetup => 'Hermes needs MCP setup',
  };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit([String? override]) async {
    final value = override ?? _controller.text;
    if (value.trim().isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final resolved = await widget.onSubmit(value);
    if (!mounted) return;
    if (resolved) _controller.clear();
    setState(() {
      _submitting = false;
      _resolved = resolved;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.only(top: Spacing.sm),
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: theme.surfaceBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.card),
          border: Border.all(color: theme.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _title,
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
              Text('Response sent', style: TextStyle(color: theme.success))
            else ...[
              if (widget.kind == HermesDecisionKind.mcpSetup) ...[
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
                      text: 'Not now',
                      isCompact: true,
                      onPressed: _submitting ? null : () => _submit('decline'),
                    ),
                    const SizedBox(width: Spacing.sm),
                    ConduitButton(
                      text: 'Set up',
                      isCompact: true,
                      isLoading: _submitting,
                      onPressed: _submitting ? null : () => _submit('approve'),
                    ),
                  ],
                ),
              ] else ...[
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
                  decoration: InputDecoration(
                    labelText: _sensitive ? 'Sensitive response' : 'Response',
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: Spacing.sm),
                ConduitButton(
                  text: 'Send response',
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
              ],
            ],
          ],
        ),
      ),
    );
  }
}
