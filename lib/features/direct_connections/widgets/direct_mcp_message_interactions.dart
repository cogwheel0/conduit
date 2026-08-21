import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../models/direct_completion.dart';
import '../providers/direct_connection_providers.dart';
import '../providers/direct_mcp_providers.dart';
import '../services/direct_chat_bridge.dart';

final class DirectMcpMessageInteractions extends ConsumerStatefulWidget {
  const DirectMcpMessageInteractions({super.key, required this.message});

  final ChatMessage message;

  @override
  ConsumerState<DirectMcpMessageInteractions> createState() =>
      _DirectMcpMessageInteractionsState();
}

final class _DirectMcpMessageInteractionsState
    extends ConsumerState<DirectMcpMessageInteractions> {
  bool _busy = false;
  String? _error;

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
    final servers = ref.read(directMcpServersProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await registry.resolveMcpApprovalAlwaysById(id, servers.rememberApproval);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.directMcpApprovalSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.message.metadata?[kDirectMcpApprovalMetadataKey];
    if (raw is! Map) return const SizedBox.shrink();
    final approval = raw.map((key, value) => MapEntry(key.toString(), value));
    final id = approval['id']?.toString() ?? '';
    final serverName = approval['serverName']?.toString() ?? '';
    final toolName = approval['toolName']?.toString() ?? '';
    final arguments = approval['arguments']?.toString() ?? '{}';
    final state = approval['state']?.toString() ?? 'denied';
    if (id.isEmpty || serverName.isEmpty || toolName.isEmpty) {
      return const SizedBox.shrink();
    }

    final registry = ref.read(directRunRegistryProvider);
    final live = state == 'pending' && registry.hasLiveMcpApproval(id);
    final l10n = AppLocalizations.of(context)!;
    final status = switch (state) {
      'allowed' || 'allowed_once' => l10n.directMcpApprovalAllowed,
      'allowed_session' => l10n.directMcpApprovalAllowedSession,
      'allowed_always' => l10n.directMcpApprovalAllowedAlways,
      'denied' => l10n.directMcpApprovalDenied,
      _ when !live => l10n.directMcpApprovalExpired,
      _ => null,
    };

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        container: true,
        label: l10n.directMcpApprovalTitle,
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.directMcpApprovalTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text('$serverName · $toolName'),
                const SizedBox(height: 8),
                SelectableText(
                  arguments,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
                if (live) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => registry.resolveMcpApprovalById(
                                id,
                                DirectToolApprovalDecision.allowOnce,
                              ),
                        child: Text(l10n.directMcpApprovalAllowOnce),
                      ),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => registry.resolveMcpApprovalById(
                                id,
                                DirectToolApprovalDecision.allowSession,
                              ),
                        child: Text(l10n.directMcpApprovalAllowSession),
                      ),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _allowAlways(
                                id: id,
                                serverName: serverName,
                                toolName: toolName,
                              ),
                        child: Text(l10n.directMcpApprovalAllowAlways),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => registry.resolveMcpApprovalById(
                                id,
                                DirectToolApprovalDecision.deny,
                              ),
                        child: Text(l10n.directMcpApprovalDeny),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Semantics(liveRegion: true, child: Text(_error!)),
                  ],
                ] else if (status != null) ...[
                  const SizedBox(height: 8),
                  Text(status),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
