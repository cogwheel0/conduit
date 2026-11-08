import 'dart:io' show Platform;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'conversation_tile.dart';

/// Space above the first section header, below the sidebar toolbar.
const double kSidebarFirstSectionTopSpacing = Spacing.md;

/// Space above every later section header, between it and the rows of the
/// section before.
const double kSidebarSectionTopSpacing = 20;

/// Space between a section header and its first row.
const double kSidebarSectionHeaderBottomSpacing = Spacing.xs;

/// Section header of a sidebar list, as UIKit plain lists label sections:
/// the title starts where row text starts, and a collapsible section ends in
/// a disclosure chevron that turns down while the section is open.
class SidebarSectionHeader extends StatelessWidget {
  const SidebarSectionHeader({
    super.key,
    required this.title,
    this.isFirst = false,
    this.isExpanded,
    this.onToggle,
    this.trailing,
    this.chevronKey,
  }) : assert(
         (isExpanded == null) == (onToggle == null),
         'A collapsible header needs both isExpanded and onToggle.',
       );

  final String title;

  /// Whether this header opens the list, right below the toolbar.
  final bool isFirst;

  /// Whether the section's rows show; null for a section that cannot
  /// collapse.
  final bool? isExpanded;

  /// Opens or closes the section.
  final VoidCallback? onToggle;

  /// A compact control before the chevron, such as New Folder.
  final Widget? trailing;

  final Key? chevronKey;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final expanded = isExpanded;
    final collapsible = expanded != null;
    // Material's pair reads "Expanded" for an open section and "Collapsed"
    // for a closed one, in every language Flutter ships.
    final localizations = MaterialLocalizations.of(context);
    final titleText = Semantics(
      header: true,
      button: collapsible,
      expanded: expanded,
      label: title,
      value: expanded == null
          ? null
          : expanded
          ? localizations.collapsedHint
          : localizations.expandedHint,
      onTap: collapsible ? _toggle : null,
      excludeSemantics: true,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sidebarSectionHeaderStyle(theme),
      ),
    );

    final row = Padding(
      padding: EdgeInsetsDirectional.only(
        start: kSidebarRowContentInset,
        end: kSidebarRowContentInset,
        top: isFirst
            ? kSidebarFirstSectionTopSpacing
            : kSidebarSectionTopSpacing,
        bottom: kSidebarSectionHeaderBottomSpacing,
      ),
      child: Row(
        children: [
          Expanded(child: titleText),
          if (trailing case final trailing?) ...[
            const SizedBox(width: Spacing.sm),
            trailing,
          ],
          if (expanded != null) ...[
            const SizedBox(width: Spacing.sm),
            ExcludeSemantics(
              child: _SectionChevron(key: chevronKey, expanded: expanded),
            ),
          ],
        ],
      ),
    );

    if (!collapsible) return row;
    // The whole header toggles, not just its title; a trailing control
    // keeps its own taps.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      excludeFromSemantics: true,
      child: row,
    );
  }

  void _toggle() {
    ConduitHaptics.selectionClick();
    onToggle?.call();
  }
}

/// Footnote-weight label for sidebar section headers: semibold secondary
/// text, quieter than the 17pt rows it introduces.
TextStyle sidebarSectionHeaderStyle(ConduitThemeExtension theme) =>
    AppTypography.titleMediumStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.none,
    );

class _SectionChevron extends StatelessWidget {
  const _SectionChevron({super.key, required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return AnimatedRotation(
      turns: expanded ? 0.25 : 0,
      duration: context.motionDuration(AnimationDuration.fast),
      curve: Curves.easeOutCubic,
      child: Icon(
        Platform.isIOS
            ? CupertinoIcons.chevron_right
            : Icons.chevron_right_rounded,
        size: IconSize.sm,
        color: theme.iconSecondary,
      ),
    );
  }
}

/// Scroll offset past which the list's large title has gone under the
/// toolbar and the toolbar shows it small instead.
const double kSidebarLargeTitleCollapseOffset = 36;

/// The list's large title, as iOS opens a top-level list: it scrolls away
/// with the rows and starts on their leading edge.
class SidebarLargeTitle extends StatelessWidget {
  const SidebarLargeTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: kSidebarRowContentInset,
        end: kSidebarRowContentInset,
        top: Spacing.xxs,
      ),
      child: Semantics(
        header: true,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.displayLargeStyle.copyWith(
            color: theme.textPrimary,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}
