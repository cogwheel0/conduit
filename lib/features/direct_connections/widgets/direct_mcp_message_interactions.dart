import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/models/chat_message.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/composer_prompt_surface.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../models/direct_completion.dart';
import '../providers/direct_connection_providers.dart';
import '../providers/direct_mcp_providers.dart';
import '../services/direct_chat_bridge.dart';

ChatMessage? findPendingDirectMcpComposerPrompt(
  List<ChatMessage> messages, {
  bool Function(String approvalId)? isLive,
}) {
  for (final message in messages.reversed) {
    if (message.metadata?['archivedVariant'] == true) continue;
    final approval = message.metadata?[kDirectMcpApprovalMetadataKey];
    final approvalId = approval is Map ? approval['id']?.toString() : null;
    if (approval is Map &&
        approval['state'] == 'pending' &&
        approvalId?.isNotEmpty == true &&
        approval['serverName']?.toString().isNotEmpty == true &&
        approval['toolName']?.toString().isNotEmpty == true &&
        (isLive == null || isLive(approvalId!))) {
      return message;
    }
  }
  return null;
}

final class DirectMcpComposerPromptOverlay extends ConsumerStatefulWidget {
  const DirectMcpComposerPromptOverlay({super.key, required this.message});

  final ChatMessage message;

  @override
  ConsumerState<DirectMcpComposerPromptOverlay> createState() =>
      _DirectMcpComposerPromptOverlayState();
}

final class _DirectMcpComposerPromptOverlayState
    extends ConsumerState<DirectMcpComposerPromptOverlay> {
  bool _busy = false;
  String? _error;
  String? _resolvedApprovalId;

  void _resolve(String id, DirectToolApprovalDecision decision) {
    if (!ref
        .read(directRunRegistryProvider)
        .resolveMcpApprovalById(id, decision)) {
      return;
    }
    setState(() => _resolvedApprovalId = id);
  }

  Future<void> _allowAlways({
    required String id,
    required String serverName,
    required String toolName,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.directMcpApprovalAlwaysTitle,
      message: l10n.directMcpApprovalAlwaysMessage(serverName, toolName),
      confirmText: l10n.directMcpApprovalAllowAlways,
      barrierDismissible: false,
    );
    if (!confirmed || !mounted) return;
    final registry = ref.read(directRunRegistryProvider);
    if (!registry.hasLiveMcpApproval(id)) return;
    final servers = ref.read(directMcpServersProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final resolved = await registry.resolveMcpApprovalAlwaysById(
        id,
        servers.rememberApproval,
        servers.revokeRememberedApproval,
      );
      if (resolved && mounted) {
        setState(() => _resolvedApprovalId = id);
      }
    } catch (_) {
      if (mounted) setState(() => _error = l10n.directMcpApprovalSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(directMcpApprovalRevisionProvider);
    final raw = widget.message.metadata?[kDirectMcpApprovalMetadataKey];
    if (raw is! Map) return const SizedBox.shrink();
    final approval = raw.map((key, value) => MapEntry(key.toString(), value));
    final id = approval['id']?.toString() ?? '';
    final serverName = approval['serverName']?.toString() ?? '';
    final toolName = approval['toolName']?.toString() ?? '';
    final arguments = approval['arguments']?.toString() ?? '{}';
    if (approval['state'] != 'pending' ||
        id.isEmpty ||
        serverName.isEmpty ||
        toolName.isEmpty ||
        _resolvedApprovalId == id) {
      return const SizedBox.shrink();
    }

    final registry = ref.read(directRunRegistryProvider);
    final live = registry.hasLiveMcpApproval(id);
    if (!live) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return ComposerPromptSurface(
      semanticsLabel: l10n.directMcpApprovalTitle,
      surfaceKey: const ValueKey('direct-mcp-approval-overlay'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 18,
                color: theme.buttonPrimary,
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                l10n.directMcpApprovalTitle,
                style: AppTypography.standard.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            '$serverName · $toolName',
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          SelectableText(
            arguments,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              ConduitButton(
                text: l10n.directMcpApprovalAllowOnce,
                isCompact: true,
                onPressed: _busy
                    ? null
                    : () => _resolve(id, DirectToolApprovalDecision.allowOnce),
              ),
              ConduitButton(
                text: l10n.directMcpApprovalAllowSession,
                isCompact: true,
                isSecondary: true,
                onPressed: _busy
                    ? null
                    : () =>
                          _resolve(id, DirectToolApprovalDecision.allowSession),
              ),
              ConduitButton(
                text: l10n.directMcpApprovalAllowAlways,
                isCompact: true,
                isSecondary: true,
                isLoading: _busy,
                onPressed: _busy
                    ? null
                    : () => _allowAlways(
                        id: id,
                        serverName: serverName,
                        toolName: toolName,
                      ),
              ),
              ConduitButton(
                text: l10n.directMcpApprovalDeny,
                isCompact: true,
                isSecondary: true,
                onPressed: _busy
                    ? null
                    : () => _resolve(id, DirectToolApprovalDecision.deny),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: Spacing.sm),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.error,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
