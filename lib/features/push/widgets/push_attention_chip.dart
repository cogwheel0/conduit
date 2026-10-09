import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'push_target_actions.dart';
import 'push_target_detail_sheet.dart';

/// A small chip on an account or connection whose push setup needs the
/// user. Nothing while push is off, or while it works or is on its way.
/// Tapping it opens the target's push details.
class PushAttentionChip extends ConsumerWidget {
  const PushAttentionChip({super.key, required this.scope});

  /// `owui:<accountId>` or `hermes:<connectionId>`.
  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(
      pushStateIfUsedProvider.select(
        (push) => push != null && push.enabled ? push.targets[scope] : null,
      ),
    );
    if (target == null || !pushTargetNeedsAttention(target)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: Spacing.xs),
      child: AdaptiveChip.action(
        key: Key('push-attention-$scope'),
        label: Text(
          l10n.pushAttentionChip,
          style: theme.caption?.copyWith(color: theme.warning),
        ),
        semanticLabel:
            '${l10n.pushAttentionChip}: ${pushStatusText(l10n, target)}',
        onPressed: () => showPushTargetDetailSheet(context, scope),
      ),
    );
  }
}
