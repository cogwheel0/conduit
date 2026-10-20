import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';

import '../workspace_navigation.dart';
import 'workspace_status_pill.dart';
import 'workspace_tiles.dart';

final class WorkspaceResourcePresentation {
  const WorkspaceResourcePresentation({
    this.statusLabel,
    this.statusTone = WorkspaceStatusTone.neutral,
    this.readOnly = false,
  });

  final String? statusLabel;
  final WorkspaceStatusTone statusTone;
  final bool readOnly;
}

WorkspaceResourcePresentation presentWorkspaceModel(
  AppLocalizations l10n,
  WorkspaceModelSummary item,
) => WorkspaceResourcePresentation(
  statusLabel: item.isActive ? l10n.activeStatus : l10n.inactiveStatus,
  statusTone: item.isActive
      ? WorkspaceStatusTone.success
      : WorkspaceStatusTone.neutral,
  readOnly: !item.writeAccess,
);

WorkspaceResourcePresentation presentWorkspaceKnowledge(
  AppLocalizations l10n,
  WorkspaceKnowledgeSummary item,
) => WorkspaceResourcePresentation(
  statusLabel: item.isExternal
      ? l10n.workspaceKnowledgeExternalBadge
      : l10n.workspaceKnowledgeSourceLocal,
  statusTone: item.isExternal
      ? WorkspaceStatusTone.info
      : WorkspaceStatusTone.neutral,
  readOnly: !item.writeAccess,
);

WorkspaceResourcePresentation presentWorkspacePrompt(
  AppLocalizations l10n,
  WorkspacePromptSummary item,
) => WorkspaceResourcePresentation(
  statusLabel: item.isActive ? l10n.activeStatus : l10n.inactiveStatus,
  statusTone: item.isActive
      ? WorkspaceStatusTone.success
      : WorkspaceStatusTone.neutral,
  readOnly: !item.writeAccess,
);

WorkspaceResourcePresentation presentWorkspaceTool(
  AppLocalizations l10n,
  WorkspaceToolSummary item,
) => WorkspaceResourcePresentation(
  statusLabel: l10n.workspaceToolFunctionCount(item.specs.length),
  readOnly: !item.writeAccess,
);

WorkspaceResourcePresentation presentWorkspaceSkill(
  AppLocalizations l10n,
  WorkspaceSkillSummary item,
) => WorkspaceResourcePresentation(
  statusLabel: item.isActive ? l10n.activeStatus : l10n.inactiveStatus,
  statusTone: item.isActive
      ? WorkspaceStatusTone.success
      : WorkspaceStatusTone.neutral,
  readOnly: !item.writeAccess,
);

/// Shared collection row presentation for both box and sliver renderers.
class WorkspaceCollectionResourceTile extends StatelessWidget {
  const WorkspaceCollectionResourceTile({
    super.key,
    required this.section,
    required this.resourceId,
    required this.icon,
    required this.title,
    required this.presentation,
    this.subtitle,
    this.trailing,
    this.selected = false,
    this.groupedIndex,
    this.groupedLast = false,
  });

  final WorkspaceSection section;
  final String resourceId;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final WorkspaceResourcePresentation presentation;
  final bool selected;
  final int? groupedIndex;
  final bool groupedLast;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final resolvedSubtitle = [
      if (subtitle != null && subtitle!.isNotEmpty) subtitle!,
      if (presentation.readOnly) l10n.workspaceReadOnlyBadge,
    ].join(' · ');
    final status = presentation.statusLabel == null
        ? null
        : WorkspaceStatusPill(
            label: presentation.statusLabel!,
            tone: presentation.statusTone,
          );
    final tile = WorkspaceResourceTile(
      key: Key('workspace-resource-${section.name}-$resourceId'),
      icon: icon,
      title: title,
      subtitle: resolvedSubtitle.isEmpty ? null : resolvedSubtitle,
      trailing: trailing ?? status,
      selected: selected,
      grouped: groupedIndex != null,
      onTap: () =>
          context.pushWorkspace(section.routes.detailLocation(resourceId)),
    );
    final index = groupedIndex;
    if (index == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.pagePadding,
          0,
          Spacing.pagePadding,
          Spacing.md,
        ),
        child: tile,
      );
    }
    // Rows join into one grouped card like InsetGroupedList: the palette's
    // grouped surface with inset hairlines between rows. A per-side border
    // with mixed colors cannot be painted with rounded corners, which left
    // the first row of a multi-row list blank.
    final theme = context.conduitTheme;
    final radius = Radius.circular(
      context.usesCupertinoChrome ? AppBorderRadius.md : AppBorderRadius.card,
    );
    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: index == 0 ? radius : Radius.zero,
        bottom: groupedLast ? radius : Radius.zero,
      ),
      child: ColoredBox(
        color: theme.groupedSurface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            tile,
            if (!groupedLast)
              Divider(
                height: BorderWidth.thin,
                thickness: BorderWidth.thin,
                indent: Spacing.md,
                color: theme.dividerColor,
              ),
          ],
        ),
      ),
    );
  }
}
