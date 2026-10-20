import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';

import 'package:conduit_core/models/channel_message.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';

/// Reaction chips under a channel message. The signed-in user's own reactions
/// are highlighted, and tapping a chip toggles that reaction.
class ChannelMessageReactions extends StatelessWidget {
  const ChannelMessageReactions({
    super.key,
    required this.reactions,
    required this.currentUserId,
    required this.onReactionTap,
  });

  final List<MessageReaction> reactions;
  final String? currentUserId;
  final ValueChanged<String> onReactionTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Wrap(
        spacing: Spacing.xs,
        runSpacing: Spacing.xs,
        children: reactions.map((reaction) {
          final isActive = reaction.users.any(
            (u) => u['user_id'] == currentUserId || u['id'] == currentUserId,
          );
          return AdaptiveChip.action(
            label: Text(
              '${reaction.name} ${reaction.count}',
              style: AppTypography.labelMediumStyle,
            ),
            backgroundColor: isActive
                ? primaryColor.withValues(alpha: 0.15)
                : theme.surfaceContainer,
            side: BorderSide(
              color: isActive
                  ? primaryColor.withValues(alpha: 0.4)
                  : theme.dividerColor,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppBorderRadius.chip),
            ),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onPressed: () {
              ConduitHaptics.selectionClick();
              onReactionTap(reaction.name);
            },
          );
        }).toList(),
      ),
    );
  }
}
