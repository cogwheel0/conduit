import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../l10n/app_localizations.dart';
import '../models/direct_completion.dart';
import '../providers/direct_connection_providers.dart';
import '../services/direct_chat_bridge.dart';

final class DirectMcpMessageInteractions extends ConsumerWidget {
  const DirectMcpMessageInteractions({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raw = message.metadata?[kDirectMcpApprovalMetadataKey];
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
      'allowed' => l10n.directMcpApprovalAllowed,
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
                    children: [
                      FilledButton(
                        onPressed: () => registry.resolveMcpApprovalById(
                          id,
                          DirectToolApprovalDecision.allowOnce,
                        ),
                        child: Text(l10n.directMcpApprovalAllowOnce),
                      ),
                      TextButton(
                        onPressed: () => registry.resolveMcpApprovalById(
                          id,
                          DirectToolApprovalDecision.deny,
                        ),
                        child: Text(l10n.directMcpApprovalDeny),
                      ),
                    ],
                  ),
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
