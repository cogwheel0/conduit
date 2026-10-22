import 'package:material_ui/material_ui.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';

import 'package:conduit_core/features/hermes/services/hermes_approval_text.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

enum HermesApprovalState { pending, resolving, approved, denied }

/// Approval sheet content. The owning chat performs and confirms the response.
class HermesApprovalCard extends StatelessWidget {
  const HermesApprovalCard({
    super.key,
    required this.state,
    required this.onDecision,
    this.summary,
    this.choices = const <String>[],
    this.onChoice,
    this.onDismiss,
    this.failed = false,
    this.compactActions = false,
  });

  final HermesApprovalState state;
  final String? summary;
  final void Function(bool approved) onDecision;
  final List<String> choices;
  final void Function(String choice)? onChoice;
  final VoidCallback? onDismiss;
  final bool failed;
  final bool compactActions;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final resolved =
        state == HermesApprovalState.approved ||
        state == HermesApprovalState.denied;
    final available = choices.isNotEmpty && onChoice != null
        ? choices.toSet()
        : const {'once', 'deny'};
    final ordered = [
      'once',
      'deny',
      'always',
      'session',
    ].where(available.contains).toList();
    return Material(
      color: theme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  size: 20,
                  color: theme.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.hermesApprovalRequired,
                    style: AppTypography.standard.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (onDismiss != null)
                  IconButton(
                    tooltip: l10n.hermesDismiss,
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (summary?.isNotEmpty == true)
              HermesApprovalCommandPreview(command: summary!)
            else
              Text(
                l10n.hermesApprovalFallback,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            const SizedBox(height: 12),
            if (failed) ...[
              Text(
                l10n.hermesResponseFailed,
                style: TextStyle(color: theme.error),
              ),
              const SizedBox(height: 12),
            ],
            if (summary?.endsWith(kHermesApprovalTextTruncated) == true) ...[
              Text(
                l10n.hermesCommandTruncated,
                style: TextStyle(color: theme.error),
              ),
              const SizedBox(height: 12),
            ],
            if (resolved)
              Text(
                state == HermesApprovalState.approved
                    ? l10n.hermesApprovalApproved
                    : l10n.hermesApprovalDenied,
                style: TextStyle(
                  color: state == HermesApprovalState.approved
                      ? theme.success
                      : theme.error,
                ),
              )
            else ...[
              if (state == HermesApprovalState.resolving) ...[
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(l10n.hermesSendingResponse)),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (compactActions)
                Row(
                  children: [
                    if (available.contains('deny'))
                      Expanded(child: _choice(context, 'deny')),
                    const SizedBox(width: 8),
                    if (available.contains('once'))
                      Expanded(child: _choice(context, 'once')),
                    if (ordered.any((c) => c == 'session' || c == 'always'))
                      CompactPopupMenu<String>(
                        tooltip: 'Allow options',
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        choices: [
                          if (available.contains('session'))
                            CompactMenuChoice(
                              'session',
                              l10n.hermesApprovalAllowSession,
                            ),
                          if (available.contains('always'))
                            CompactMenuChoice(
                              'always',
                              l10n.hermesApprovalAlwaysAllow,
                            ),
                        ],
                        onSelected:
                            state == HermesApprovalState.pending &&
                                summary?.endsWith(
                                      kHermesApprovalTextTruncated,
                                    ) !=
                                    true
                            ? (choice) => onChoice?.call(choice)
                            : (_) {},
                      ),
                  ],
                )
              else
                for (var i = 0; i < ordered.length; i += 2) ...[
                  if (i > 0) const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _choice(context, ordered[i])),
                      const SizedBox(width: 8),
                      Expanded(
                        child: i + 1 < ordered.length
                            ? _choice(context, ordered[i + 1])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _choice(BuildContext context, String choice) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final scheme = Theme.of(context).colorScheme;
    final (color, foreground) = switch (choice) {
      'once' => (theme.buttonPrimary, theme.buttonPrimaryText),
      'session' ||
      'always' => (theme.selectionBackground, theme.selectionForeground),
      _ => (scheme.error, scheme.onError),
    };
    return FilledButton(
      key: ValueKey('hermes-approval-$choice'),
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: foreground,
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed:
          state != HermesApprovalState.pending ||
              (choice != 'deny' &&
                  summary?.endsWith(kHermesApprovalTextTruncated) == true)
          ? null
          : () {
              if (onChoice != null && choices.isNotEmpty) {
                onChoice!(choice);
              } else {
                onDecision(choice != 'deny');
              }
            },
      child: Text(switch (choice) {
        'once' => l10n.hermesApprovalAllowOnce,
        'session' => l10n.hermesApprovalAllowSession,
        'always' => l10n.hermesApprovalAlwaysAllow,
        _ => l10n.hermesApprovalDenyAction,
      }, textAlign: TextAlign.center),
    );
  }
}

class HermesApprovalCommandPreview extends StatelessWidget {
  const HermesApprovalCommandPreview({super.key, required this.command});
  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: theme.inputBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('hermes-command-preview'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _HermesCommandDetails(command: command),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                command,
                key: const ValueKey('hermes-command-preview-text'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodySmallStyle.copyWith(
                  fontFamily: 'monospace',
                  color: theme.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.hermesViewFullCommand,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HermesCommandDetails extends StatelessWidget {
  const _HermesCommandDetails({required this.command});
  final String command;
  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: theme.surfaceBackground,
      appBar: AppBar(title: Text(l10n.hermesViewFullCommand)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (command.endsWith(kHermesApprovalTextTruncated)) ...[
                Text(
                  l10n.hermesCommandTruncated,
                  style: TextStyle(color: theme.error),
                ),
                const SizedBox(height: 12),
              ],
              SelectableText(
                command,
                style: AppTypography.bodySmallStyle.copyWith(
                  fontFamily: 'monospace',
                  color: theme.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
